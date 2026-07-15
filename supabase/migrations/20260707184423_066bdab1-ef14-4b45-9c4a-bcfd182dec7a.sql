ALTER TABLE public.product_agents
  ADD COLUMN IF NOT EXISTS voice_specific_rules text,
  ADD COLUMN IF NOT EXISTS voice_provider text NOT NULL DEFAULT 'grok',
  ADD COLUMN IF NOT EXISTS openai_voice_id text;

ALTER TABLE public.product_agents
  DROP CONSTRAINT IF EXISTS product_agents_voice_provider_check;
ALTER TABLE public.product_agents
  ADD CONSTRAINT product_agents_voice_provider_check
  CHECK (voice_provider IN ('grok', 'openai', 'auto'));

ALTER TABLE public.org_ai_credentials
  ADD COLUMN IF NOT EXISTS openai_realtime_key_encrypted text;