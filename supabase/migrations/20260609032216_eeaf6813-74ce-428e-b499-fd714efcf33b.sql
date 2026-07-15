ALTER TABLE public.webchat_conversations
  ADD COLUMN IF NOT EXISTS instagram_connection_id uuid NULL REFERENCES public.instagram_connections(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS ig_sender_id text NULL;

CREATE INDEX IF NOT EXISTS idx_webchat_conversations_ig_lookup
  ON public.webchat_conversations(instagram_connection_id, ig_sender_id)
  WHERE instagram_connection_id IS NOT NULL;

ALTER TABLE public.webchat_messages
  ADD COLUMN IF NOT EXISTS ig_message_id text NULL,
  ADD COLUMN IF NOT EXISTS message_type text NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_webchat_messages_ig_message_id
  ON public.webchat_messages(ig_message_id)
  WHERE ig_message_id IS NOT NULL;