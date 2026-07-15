
ALTER TABLE public.webchat_conversations
  ADD COLUMN IF NOT EXISTS human_response_pending_since timestamptz,
  ADD COLUMN IF NOT EXISTS human_response_alert_sent_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_wc_conversations_pending_human
  ON public.webchat_conversations (organization_id, human_response_pending_since)
  WHERE human_response_pending_since IS NOT NULL;

CREATE OR REPLACE FUNCTION public.tg_wc_track_human_response_sla()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conv record;
BEGIN
  SELECT id, status, human_response_pending_since
    INTO v_conv
    FROM public.webchat_conversations
   WHERE id = NEW.conversation_id;

  IF v_conv.id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.sender_type = 'visitor' AND v_conv.status = 'human_active'
     AND v_conv.human_response_pending_since IS NULL THEN
    UPDATE public.webchat_conversations
       SET human_response_pending_since = COALESCE(NEW.created_at, now()),
           human_response_alert_sent_at = NULL
     WHERE id = NEW.conversation_id;
  END IF;

  IF NEW.sender_type IN ('agent', 'human') AND v_conv.human_response_pending_since IS NOT NULL THEN
    UPDATE public.webchat_conversations
       SET human_response_pending_since = NULL,
           human_response_alert_sent_at = NULL
     WHERE id = NEW.conversation_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_wc_track_human_response_sla ON public.webchat_messages;
CREATE TRIGGER trg_wc_track_human_response_sla
AFTER INSERT ON public.webchat_messages
FOR EACH ROW EXECUTE FUNCTION public.tg_wc_track_human_response_sla();

CREATE OR REPLACE FUNCTION public.tg_wc_clear_human_sla_on_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM 'human_active' AND OLD.human_response_pending_since IS NOT NULL THEN
    NEW.human_response_pending_since := NULL;
    NEW.human_response_alert_sent_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_wc_clear_human_sla_on_status ON public.webchat_conversations;
CREATE TRIGGER trg_wc_clear_human_sla_on_status
BEFORE UPDATE OF status ON public.webchat_conversations
FOR EACH ROW EXECUTE FUNCTION public.tg_wc_clear_human_sla_on_status();

-- Backfill: para conversas atualmente em human_active onde a última mensagem é
-- do visitante e não há resposta humana posterior, marca o pending desde então.
UPDATE public.webchat_conversations c
   SET human_response_pending_since = sub.last_visitor_at
  FROM (
    SELECT m.conversation_id, MAX(m.created_at) AS last_visitor_at
      FROM public.webchat_messages m
     WHERE m.sender_type = 'visitor'
     GROUP BY m.conversation_id
  ) sub
 WHERE c.id = sub.conversation_id
   AND c.status = 'human_active'
   AND c.human_response_pending_since IS NULL
   AND NOT EXISTS (
     SELECT 1 FROM public.webchat_messages m2
      WHERE m2.conversation_id = c.id
        AND m2.sender_type IN ('agent','human')
        AND m2.created_at > sub.last_visitor_at
   );
