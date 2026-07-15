ALTER TABLE public.voice_calls
  ADD COLUMN IF NOT EXISTS voice_provider text,
  ADD COLUMN IF NOT EXISTS openai_voice_id text;

ALTER TABLE public.voice_calls
  DROP CONSTRAINT IF EXISTS voice_calls_voice_provider_check;

ALTER TABLE public.voice_calls
  ADD CONSTRAINT voice_calls_voice_provider_check
  CHECK (voice_provider IS NULL OR voice_provider IN ('grok', 'openai', 'auto'));

UPDATE public.voice_calls vc
SET
  voice_provider = COALESCE(vc.voice_provider, pa.voice_provider),
  openai_voice_id = COALESCE(vc.openai_voice_id, pa.openai_voice_id)
FROM public.product_agents pa
WHERE vc.product_agent_id = pa.id
  AND (vc.voice_provider IS NULL OR vc.openai_voice_id IS NULL);