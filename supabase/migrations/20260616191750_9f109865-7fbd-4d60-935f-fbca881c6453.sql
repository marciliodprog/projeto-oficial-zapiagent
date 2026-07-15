ALTER TABLE public.scheduled_messages
  ADD COLUMN IF NOT EXISTS media_kind text,
  ADD COLUMN IF NOT EXISTS media_url text,
  ADD COLUMN IF NOT EXISTS media_mime text,
  ADD COLUMN IF NOT EXISTS media_filename text,
  ADD COLUMN IF NOT EXISTS media_duration_ms integer;

ALTER TABLE public.scheduled_messages ALTER COLUMN content DROP NOT NULL;

ALTER TABLE public.scheduled_messages
  ADD CONSTRAINT scheduled_messages_content_or_media_chk
  CHECK (
    (content IS NOT NULL AND length(btrim(content)) > 0)
    OR (media_url IS NOT NULL AND media_kind IS NOT NULL)
  );