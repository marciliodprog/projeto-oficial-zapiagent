
-- =====================================================================
-- 1) TABELA: voice_call_views
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.voice_call_views (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  voice_call_id UUID NOT NULL REFERENCES public.voice_calls(id) ON DELETE CASCADE,
  visitor_id TEXT,
  session_id UUID REFERENCES public.voice_call_sessions(id) ON DELETE SET NULL,
  utm_source TEXT, utm_medium TEXT, utm_campaign TEXT, utm_term TEXT, utm_content TEXT,
  referrer TEXT,
  user_agent TEXT,
  ip_hash TEXT,
  country TEXT,
  city TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_vc_views_call_created ON public.voice_call_views(voice_call_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_vc_views_org_created ON public.voice_call_views(organization_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_vc_views_visitor ON public.voice_call_views(voice_call_id, visitor_id, created_at);

GRANT SELECT ON public.voice_call_views TO authenticated;
GRANT ALL ON public.voice_call_views TO service_role;

ALTER TABLE public.voice_call_views ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "org can read own views" ON public.voice_call_views;
CREATE POLICY "org can read own views"
  ON public.voice_call_views FOR SELECT
  TO authenticated
  USING (
    organization_id IN (SELECT organization_id FROM public.profiles WHERE id = auth.uid())
    OR public.has_role(auth.uid(), 'super_admin')
  );

-- =====================================================================
-- 2) TABELA: voice_pricing
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.voice_pricing (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  voice_id TEXT,
  unit TEXT NOT NULL,
  usd_per_unit NUMERIC(14,8) NOT NULL,
  effective_from TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_active BOOLEAN NOT NULL DEFAULT true,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_voice_pricing_active
  ON public.voice_pricing(provider, model, unit, is_active, effective_from DESC);

GRANT SELECT ON public.voice_pricing TO authenticated;
GRANT ALL ON public.voice_pricing TO service_role;

ALTER TABLE public.voice_pricing ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "everyone auth reads pricing" ON public.voice_pricing;
CREATE POLICY "everyone auth reads pricing"
  ON public.voice_pricing FOR SELECT
  TO authenticated USING (true);

DROP POLICY IF EXISTS "super_admin manages pricing" ON public.voice_pricing;
CREATE POLICY "super_admin manages pricing"
  ON public.voice_pricing FOR ALL
  TO authenticated
  USING (public.has_role(auth.uid(), 'super_admin'))
  WITH CHECK (public.has_role(auth.uid(), 'super_admin'));

CREATE OR REPLACE FUNCTION public.tg_voice_pricing_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS trg_voice_pricing_updated_at ON public.voice_pricing;
CREATE TRIGGER trg_voice_pricing_updated_at
  BEFORE UPDATE ON public.voice_pricing
  FOR EACH ROW EXECUTE FUNCTION public.tg_voice_pricing_updated_at();

INSERT INTO public.voice_pricing (provider, model, voice_id, unit, usd_per_unit, notes)
SELECT * FROM (VALUES
  ('openai','gpt-4o-realtime-preview',NULL::text,'audio_second_in', 0.001::numeric,   'OpenAI Realtime — áudio in $0.06/min'),
  ('openai','gpt-4o-realtime-preview',NULL::text,'audio_second_out', 0.004::numeric,  'OpenAI Realtime — áudio out $0.24/min'),
  ('openai','gpt-4o-mini-realtime-preview',NULL::text,'audio_second_in', 0.00017::numeric, 'Mini realtime — áudio in $0.01/min'),
  ('openai','gpt-4o-mini-realtime-preview',NULL::text,'audio_second_out', 0.00067::numeric, 'Mini realtime — áudio out $0.04/min'),
  ('grok','grok-voice-v1',NULL::text,'minute', 0.10::numeric, 'Grok voice — fallback por minuto de conversa')
) AS v(provider,model,voice_id,unit,usd_per_unit,notes)
WHERE NOT EXISTS (SELECT 1 FROM public.voice_pricing);

-- =====================================================================
-- 3) COLUNAS EM voice_call_sessions
-- =====================================================================
ALTER TABLE public.voice_call_sessions
  ADD COLUMN IF NOT EXISTS provider TEXT,
  ADD COLUMN IF NOT EXISTS voice_id TEXT,
  ADD COLUMN IF NOT EXISTS model TEXT,
  ADD COLUMN IF NOT EXISTS audio_seconds_in NUMERIC(10,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS audio_seconds_out NUMERIC(10,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS tokens_in INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS tokens_out INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cost_usd_estimated NUMERIC(12,6) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cost_usd_reported NUMERIC(12,6),
  ADD COLUMN IF NOT EXISTS pricing_snapshot JSONB DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS idx_vcs_org_started ON public.voice_call_sessions(organization_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_vcs_voice_call_started ON public.voice_call_sessions(voice_call_id, started_at DESC);

-- =====================================================================
-- 4) RPC: voice_call_kpis
-- =====================================================================
CREATE OR REPLACE FUNCTION public.voice_call_kpis(
  p_org UUID, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ
)
RETURNS TABLE (
  views_unique BIGINT, views_total BIGINT,
  calls_started BIGINT, calls_completed BIGINT,
  total_seconds BIGINT, avg_seconds NUMERIC, cost_usd NUMERIC,
  schedules BIGINT, link_clicks BIGINT, whatsapp_clicks BIGINT, interest_clicks BIGINT,
  leads_captured BIGINT, leads_new BIGINT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH sess AS (
    SELECT * FROM public.voice_call_sessions
    WHERE organization_id = p_org AND started_at >= p_from AND started_at < p_to
  ),
  vw AS (
    SELECT * FROM public.voice_call_views
    WHERE organization_id = p_org AND created_at >= p_from AND created_at < p_to
  ),
  cta AS (
    SELECT c->>'kind' AS kind, COUNT(*) AS cnt
    FROM sess s, jsonb_array_elements(COALESCE(s.ctas_clicked,'[]'::jsonb)) c
    GROUP BY 1
  )
  SELECT
    (SELECT COUNT(DISTINCT COALESCE(visitor_id, id::text))::BIGINT FROM vw),
    (SELECT COUNT(*)::BIGINT FROM vw),
    (SELECT COUNT(*)::BIGINT FROM sess),
    (SELECT COUNT(*)::BIGINT FROM sess WHERE ended_at IS NOT NULL),
    COALESCE((SELECT SUM(duration_sec) FROM sess), 0)::BIGINT,
    COALESCE((SELECT AVG(duration_sec) FROM sess WHERE duration_sec > 0), 0)::NUMERIC,
    COALESCE((SELECT SUM(cost_usd_estimated) FROM sess), 0)::NUMERIC,
    COALESCE((SELECT cnt FROM cta WHERE kind='schedule'), 0)::BIGINT,
    COALESCE((SELECT cnt FROM cta WHERE kind='link'), 0)::BIGINT,
    COALESCE((SELECT cnt FROM cta WHERE kind='whatsapp'), 0)::BIGINT,
    COALESCE((SELECT cnt FROM cta WHERE kind='interest'), 0)::BIGINT,
    (SELECT COUNT(DISTINCT lead_id)::BIGINT FROM sess WHERE lead_id IS NOT NULL),
    (SELECT COUNT(DISTINCT s.lead_id)::BIGINT
       FROM sess s JOIN public.leads l ON l.id = s.lead_id
       WHERE s.lead_id IS NOT NULL
         AND ABS(EXTRACT(EPOCH FROM (l.created_at - s.started_at))) < 300)
$$;
GRANT EXECUTE ON FUNCTION public.voice_call_kpis(UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;

-- =====================================================================
-- 5) RPC: voice_call_trend
-- =====================================================================
CREATE OR REPLACE FUNCTION public.voice_call_trend(
  p_org UUID, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ
)
RETURNS TABLE (day DATE, views BIGINT, calls BIGINT, minutes NUMERIC, schedules BIGINT, cost_usd NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH days AS (
    SELECT generate_series(date_trunc('day', p_from), date_trunc('day', p_to), interval '1 day')::date AS d
  ),
  v AS (
    SELECT date_trunc('day', created_at)::date d, COUNT(DISTINCT COALESCE(visitor_id, id::text)) c
    FROM public.voice_call_views
    WHERE organization_id = p_org AND created_at >= p_from AND created_at < p_to
    GROUP BY 1
  ),
  s AS (
    SELECT date_trunc('day', started_at)::date d,
           COUNT(*) c,
           COALESCE(SUM(duration_sec),0)/60.0 m,
           COALESCE(SUM(cost_usd_estimated),0) cost,
           COUNT(*) FILTER (WHERE ctas_clicked @> '[{"kind":"schedule"}]'::jsonb) sched
    FROM public.voice_call_sessions
    WHERE organization_id = p_org AND started_at >= p_from AND started_at < p_to
    GROUP BY 1
  )
  SELECT d.d, COALESCE(v.c,0)::BIGINT, COALESCE(s.c,0)::BIGINT,
         ROUND(COALESCE(s.m,0)::numeric,1),
         COALESCE(s.sched,0)::BIGINT,
         ROUND(COALESCE(s.cost,0)::numeric,4)
  FROM days d LEFT JOIN v ON v.d = d.d LEFT JOIN s ON s.d = d.d
  ORDER BY d.d
$$;
GRANT EXECUTE ON FUNCTION public.voice_call_trend(UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;

-- =====================================================================
-- 6) RPC: voice_call_usage_by_month
-- =====================================================================
CREATE OR REPLACE FUNCTION public.voice_call_usage_by_month(p_org UUID)
RETURNS TABLE (
  month TEXT, calls BIGINT, minutes NUMERIC,
  audio_sec_in NUMERIC, audio_sec_out NUMERIC,
  tokens_in BIGINT, tokens_out BIGINT,
  cost_grok NUMERIC, cost_openai NUMERIC, cost_total NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    to_char(date_trunc('month', started_at), 'YYYY-MM'),
    COUNT(*)::BIGINT,
    ROUND((COALESCE(SUM(duration_sec),0)/60.0)::numeric, 1),
    ROUND(COALESCE(SUM(audio_seconds_in),0)::numeric, 1),
    ROUND(COALESCE(SUM(audio_seconds_out),0)::numeric, 1),
    COALESCE(SUM(tokens_in),0)::BIGINT,
    COALESCE(SUM(tokens_out),0)::BIGINT,
    ROUND(COALESCE(SUM(cost_usd_estimated) FILTER (WHERE provider='grok'),0)::numeric, 4),
    ROUND(COALESCE(SUM(cost_usd_estimated) FILTER (WHERE provider='openai'),0)::numeric, 4),
    ROUND(COALESCE(SUM(cost_usd_estimated),0)::numeric, 4)
  FROM public.voice_call_sessions
  WHERE organization_id = p_org
  GROUP BY 1
  ORDER BY 1 DESC
  LIMIT 24
$$;
GRANT EXECUTE ON FUNCTION public.voice_call_usage_by_month(UUID) TO authenticated;

-- =====================================================================
-- 7) RPC: voice_call_usage_by_dim
-- =====================================================================
CREATE OR REPLACE FUNCTION public.voice_call_usage_by_dim(
  p_org UUID, p_dim TEXT, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ
)
RETURNS TABLE (
  key TEXT, label TEXT, calls BIGINT, minutes NUMERIC,
  cost_grok NUMERIC, cost_openai NUMERIC, cost_total NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    CASE p_dim
      WHEN 'voice_call' THEN s.voice_call_id::text
      WHEN 'agent' THEN COALESCE(vc.product_agent_id::text, 'none')
      WHEN 'provider' THEN COALESCE(s.provider || COALESCE(' · '||s.model,''), 'unknown')
      ELSE 'all'
    END,
    CASE p_dim
      WHEN 'voice_call' THEN COALESCE(vc.name, '—')
      WHEN 'agent' THEN COALESCE(pa.name, 'Sem agente')
      WHEN 'provider' THEN COALESCE(s.provider || COALESCE(' · '||s.model,''), 'Desconhecido')
      ELSE 'Total'
    END,
    COUNT(*)::BIGINT,
    ROUND((COALESCE(SUM(s.duration_sec),0)/60.0)::numeric, 1),
    ROUND(COALESCE(SUM(s.cost_usd_estimated) FILTER (WHERE s.provider='grok'),0)::numeric, 4),
    ROUND(COALESCE(SUM(s.cost_usd_estimated) FILTER (WHERE s.provider='openai'),0)::numeric, 4),
    ROUND(COALESCE(SUM(s.cost_usd_estimated),0)::numeric, 4)
  FROM public.voice_call_sessions s
  LEFT JOIN public.voice_calls vc ON vc.id = s.voice_call_id
  LEFT JOIN public.product_agents pa ON pa.id = vc.product_agent_id
  WHERE s.organization_id = p_org
    AND s.started_at >= p_from AND s.started_at < p_to
  GROUP BY 1, 2
  ORDER BY 7 DESC
$$;
GRANT EXECUTE ON FUNCTION public.voice_call_usage_by_dim(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
