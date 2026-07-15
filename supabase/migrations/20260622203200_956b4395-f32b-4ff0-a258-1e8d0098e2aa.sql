
ALTER TABLE public.webchat_conversations
  ADD COLUMN IF NOT EXISTS bot_loop_detected_at timestamptz,
  ADD COLUMN IF NOT EXISTS bot_loop_reason text,
  ADD COLUMN IF NOT EXISTS bot_loop_strike_count smallint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS bot_loop_last_strike_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_webchat_conv_bot_loop
  ON public.webchat_conversations(organization_id, bot_loop_detected_at)
  WHERE bot_loop_detected_at IS NOT NULL;

CREATE OR REPLACE FUNCTION public.reset_bot_loop(_conversation_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org uuid;
BEGIN
  SELECT organization_id INTO v_org
  FROM public.webchat_conversations
  WHERE id = _conversation_id;

  IF v_org IS NULL THEN
    RETURN false;
  END IF;

  -- Permite: super_admin, admin da org, ou membro do setor da conversa
  IF NOT (
    public.has_role(auth.uid(), 'super_admin')
    OR EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid()
        AND p.organization_id = v_org
        AND (public.has_role(auth.uid(), 'admin') OR public.has_role(auth.uid(), 'manager'))
    )
    OR EXISTS (
      SELECT 1
      FROM public.webchat_conversations c
      JOIN public.sector_members sm ON sm.sector_id = c.sector_id
      WHERE c.id = _conversation_id AND sm.user_id = auth.uid()
    )
  ) THEN
    RAISE EXCEPTION 'not authorized to reset bot loop on this conversation';
  END IF;

  UPDATE public.webchat_conversations
  SET bot_loop_detected_at = NULL,
      bot_loop_reason = NULL,
      bot_loop_strike_count = 0,
      bot_loop_last_strike_at = NULL
  WHERE id = _conversation_id;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.reset_bot_loop(uuid) TO authenticated;
