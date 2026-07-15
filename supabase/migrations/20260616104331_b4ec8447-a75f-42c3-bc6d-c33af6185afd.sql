ALTER TABLE public.product_agents
  ADD COLUMN IF NOT EXISTS followup_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS followup_max_attempts integer NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS followup_intervals_minutes integer[] NOT NULL DEFAULT ARRAY[15, 120, 1440]::integer[],
  ADD COLUMN IF NOT EXISTS followup_tone text NOT NULL DEFAULT 'warm',
  ADD COLUMN IF NOT EXISTS followup_extra_instructions text,
  ADD COLUMN IF NOT EXISTS followup_respect_business_hours boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS followup_stop_on_human boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS followup_stop_on_booking boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS followup_channels text[] NOT NULL DEFAULT ARRAY['whatsapp','instagram']::text[],
  ADD COLUMN IF NOT EXISTS followup_attempt_hints jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.ai_outreach_queue
  ADD COLUMN IF NOT EXISTS followup_intervals_minutes integer[],
  ADD COLUMN IF NOT EXISTS followup_kind text DEFAULT 'manual',
  ADD COLUMN IF NOT EXISTS followup_attempt_hints jsonb;

CREATE INDEX IF NOT EXISTS idx_outreach_queue_lead_agent_status
  ON public.ai_outreach_queue (lead_id, agent_id, status);