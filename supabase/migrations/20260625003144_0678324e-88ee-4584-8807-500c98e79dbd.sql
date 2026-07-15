ALTER TABLE public.campaigns DROP CONSTRAINT IF EXISTS campaigns_status_chk;
ALTER TABLE public.campaigns ADD CONSTRAINT campaigns_status_chk
  CHECK (status = ANY (ARRAY['draft','preparing','active','paused','completed','cancelled']::text[]));
