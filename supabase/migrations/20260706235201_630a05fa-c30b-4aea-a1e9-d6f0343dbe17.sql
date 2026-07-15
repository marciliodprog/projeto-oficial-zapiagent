-- Fase 9: Ligação = Agente de IA direto (fim dos "Perfis de Voz")

-- 1. product_agents: defaults de voz
ALTER TABLE public.product_agents
  ADD COLUMN IF NOT EXISTS voice_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS default_grok_voice_id text,
  ADD COLUMN IF NOT EXISTS voice_settings jsonb NOT NULL DEFAULT '{}'::jsonb;

-- 2. voice_calls: agente + voz direto
ALTER TABLE public.voice_calls
  ADD COLUMN IF NOT EXISTS product_agent_id uuid REFERENCES public.product_agents(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS grok_voice_id text,
  ADD COLUMN IF NOT EXISTS voice_settings jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS language text NOT NULL DEFAULT 'pt-BR';

CREATE INDEX IF NOT EXISTS idx_voice_calls_product_agent ON public.voice_calls(product_agent_id);

-- 3. voice_campaigns: mesmo padrão
ALTER TABLE public.voice_campaigns
  ADD COLUMN IF NOT EXISTS product_agent_id uuid REFERENCES public.product_agents(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS grok_voice_id text,
  ADD COLUMN IF NOT EXISTS voice_settings jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS language text NOT NULL DEFAULT 'pt-BR';

CREATE INDEX IF NOT EXISTS idx_voice_campaigns_product_agent ON public.voice_campaigns(product_agent_id);

-- 4. call_logs: rastreabilidade
ALTER TABLE public.call_logs
  ADD COLUMN IF NOT EXISTS product_agent_id uuid REFERENCES public.product_agents(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS grok_voice_id text;

CREATE INDEX IF NOT EXISTS idx_call_logs_product_agent ON public.call_logs(product_agent_id);

-- 5. Backfill idempotente a partir de voice_agents legados
UPDATE public.voice_calls vc
SET
  product_agent_id = COALESCE(vc.product_agent_id, va.product_agent_id),
  grok_voice_id    = COALESCE(vc.grok_voice_id, va.grok_voice_id, va.voice_option),
  voice_settings   = CASE WHEN vc.voice_settings = '{}'::jsonb THEN COALESCE(va.voice_settings, '{}'::jsonb) ELSE vc.voice_settings END,
  language         = COALESCE(NULLIF(vc.language, ''), va.language, 'pt-BR')
FROM public.voice_agents va
WHERE vc.voice_agent_id = va.id
  AND (vc.product_agent_id IS NULL OR vc.grok_voice_id IS NULL);

UPDATE public.voice_campaigns vcp
SET
  product_agent_id = COALESCE(vcp.product_agent_id, va.product_agent_id),
  grok_voice_id    = COALESCE(vcp.grok_voice_id, va.grok_voice_id, va.voice_option),
  voice_settings   = CASE WHEN vcp.voice_settings = '{}'::jsonb THEN COALESCE(va.voice_settings, '{}'::jsonb) ELSE vcp.voice_settings END,
  language         = COALESCE(NULLIF(vcp.language, ''), va.language, 'pt-BR')
FROM public.voice_agents va
WHERE vcp.voice_agent_id = va.id
  AND (vcp.product_agent_id IS NULL OR vcp.grok_voice_id IS NULL);

UPDATE public.call_logs cl
SET
  product_agent_id = COALESCE(cl.product_agent_id, va.product_agent_id),
  grok_voice_id    = COALESCE(cl.grok_voice_id, va.grok_voice_id, va.voice_option)
FROM public.voice_agents va
WHERE cl.voice_agent_id = va.id
  AND (cl.product_agent_id IS NULL OR cl.grok_voice_id IS NULL);

-- 6. Defaults de voz nos product_agents a partir dos voice_agents que já apontam para eles
UPDATE public.product_agents pa
SET
  default_grok_voice_id = COALESCE(pa.default_grok_voice_id, sub.grok_voice_id),
  voice_settings        = CASE WHEN pa.voice_settings = '{}'::jsonb THEN COALESCE(sub.voice_settings, '{}'::jsonb) ELSE pa.voice_settings END
FROM (
  SELECT DISTINCT ON (product_agent_id)
    product_agent_id,
    COALESCE(grok_voice_id, voice_option) AS grok_voice_id,
    voice_settings
  FROM public.voice_agents
  WHERE product_agent_id IS NOT NULL
  ORDER BY product_agent_id, updated_at DESC NULLS LAST
) sub
WHERE pa.id = sub.product_agent_id
  AND pa.default_grok_voice_id IS NULL;
