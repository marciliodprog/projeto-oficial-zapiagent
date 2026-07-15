
ALTER TABLE public.webchat_conversations
  ADD COLUMN IF NOT EXISTS released_to_queue_at timestamptz;

CREATE OR REPLACE FUNCTION public.enforce_waiting_human_lock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  allow_revival boolean := false;
BEGIN
  BEGIN
    allow_revival := current_setting('app.allow_ai_revival', true) = 'true';
  EXCEPTION WHEN OTHERS THEN
    allow_revival := false;
  END;

  IF NEW.status::text = 'waiting_human' THEN
    NEW.current_agent_id := NULL;
    NEW.assigned_user_id := NULL;
    NEW.needs_human := true;
    IF TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status THEN
      NEW.released_to_queue_at := now();
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.status::text = 'waiting_human'
     AND NEW.status::text IN ('bot_active', 'ai_processing')
     AND NOT allow_revival THEN
    RAISE EXCEPTION 'AI revival blocked: conversation % is in queue. Use revive_ai_for_conversation() to reactivate.', OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_waiting_human_lock ON public.webchat_conversations;
CREATE TRIGGER trg_enforce_waiting_human_lock
  BEFORE INSERT OR UPDATE ON public.webchat_conversations
  FOR EACH ROW EXECUTE FUNCTION public.enforce_waiting_human_lock();

CREATE OR REPLACE FUNCTION public.revive_ai_for_conversation(
  p_conversation_id uuid,
  p_agent_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_org uuid;
  v_is_admin boolean := false;
  v_can_revive boolean := false;
BEGIN
  SELECT organization_id INTO v_org
  FROM public.webchat_conversations
  WHERE id = p_conversation_id;

  IF v_org IS NULL THEN
    RAISE EXCEPTION 'Conversation % not found', p_conversation_id;
  END IF;

  IF v_caller IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = v_caller AND role::text IN ('admin', 'super_admin')
    ) INTO v_is_admin;

    IF NOT v_is_admin THEN
      SELECT COALESCE(can_revive_ai, false) INTO v_can_revive
      FROM public.user_permissions
      WHERE user_id = v_caller AND organization_id = v_org
      LIMIT 1;
    END IF;

    IF NOT (v_is_admin OR v_can_revive) THEN
      RAISE EXCEPTION 'Not authorized to revive AI on this conversation';
    END IF;
  END IF;

  PERFORM set_config('app.allow_ai_revival', 'true', true);

  UPDATE public.webchat_conversations
  SET status = 'bot_active',
      current_agent_id = p_agent_id,
      assigned_user_id = NULL,
      needs_human = false,
      updated_at = now()
  WHERE id = p_conversation_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.revive_ai_for_conversation(uuid, uuid) TO authenticated;

ALTER TABLE public.user_permissions
  ADD COLUMN IF NOT EXISTS can_revive_ai boolean NOT NULL DEFAULT false;

UPDATE public.webchat_conversations
SET current_agent_id = NULL,
    assigned_user_id = NULL,
    needs_human = true,
    released_to_queue_at = COALESCE(released_to_queue_at, updated_at, now())
WHERE status::text = 'waiting_human'
  AND (current_agent_id IS NOT NULL OR assigned_user_id IS NOT NULL);
