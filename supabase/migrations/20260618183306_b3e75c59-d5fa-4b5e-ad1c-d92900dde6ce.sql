ALTER TABLE public.ai_outreach_queue DROP CONSTRAINT IF EXISTS ai_outreach_queue_status_check;
ALTER TABLE public.ai_outreach_queue ADD CONSTRAINT ai_outreach_queue_status_check
  CHECK (status = ANY (ARRAY['pending','scheduled','sent','processing','replied','completed','failed']));