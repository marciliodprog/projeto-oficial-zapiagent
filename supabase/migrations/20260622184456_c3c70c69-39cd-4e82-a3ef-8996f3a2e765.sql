CREATE INDEX IF NOT EXISTS idx_webchat_messages_meta_n
  ON public.webchat_messages ((metadata->>'n'));

CREATE INDEX IF NOT EXISTS idx_webchat_messages_meta_external_id
  ON public.webchat_messages ((metadata->>'external_id'));
