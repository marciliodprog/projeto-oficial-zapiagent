ALTER TABLE public.scheduled_messages
  ADD COLUMN IF NOT EXISTS last_error text,
  ADD COLUMN IF NOT EXISTS last_attempt_at timestamp with time zone,
  ADD COLUMN IF NOT EXISTS attempt_count integer NOT NULL DEFAULT 0;