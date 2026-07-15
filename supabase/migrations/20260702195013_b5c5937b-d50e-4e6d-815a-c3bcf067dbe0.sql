
-- ============================================================
-- JOURNEY ENGINE — Fase 0 (Fundação)
-- ============================================================

-- 1) Novos valores no enum de tipo de evento
DO $$ BEGIN ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'campaign_identified'; EXCEPTION WHEN others THEN NULL; END $$;
DO $$ BEGIN ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'meta_ctwa_received'; EXCEPTION WHEN others THEN NULL; END $$;
DO $$ BEGIN ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'meta_click_received'; EXCEPTION WHEN others THEN NULL; END $$;
DO $$ BEGIN ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'ad_click_received'; EXCEPTION WHEN others THEN NULL; END $$;
DO $$ BEGIN ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'session_started'; EXCEPTION WHEN others THEN NULL; END $$;
DO $$ BEGIN ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'session_ended'; EXCEPTION WHEN others THEN NULL; END $$;
DO $$ BEGIN ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'owner_changed'; EXCEPTION WHEN others THEN NULL; END $$;
DO $$ BEGIN ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'cadence_enrolled'; EXCEPTION WHEN others THEN NULL; END $$;
DO $$ BEGIN ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'cadence_step_sent'; EXCEPTION WHEN others THEN NULL; END $$;
DO $$ BEGIN ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'cadence_completed'; EXCEPTION WHEN others THEN NULL; END $$;
DO $$ BEGIN ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'wa_template_sent'; EXCEPTION WHEN others THEN NULL; END $$;
DO $$ BEGIN ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'wa_window_expired'; EXCEPTION WHEN others THEN NULL; END $$;

-- 2) Rename da tabela núcleo para nome genérico
ALTER TABLE IF EXISTS public.lead_journey_events RENAME TO journey_events;

-- 3) Colunas novas
ALTER TABLE public.journey_events
  ADD COLUMN IF NOT EXISTS subject_type TEXT NOT NULL DEFAULT 'lead',
  ADD COLUMN IF NOT EXISTS subject_id UUID,
  ADD COLUMN IF NOT EXISTS source_module TEXT,
  ADD COLUMN IF NOT EXISTS actor_type TEXT,
  ADD COLUMN IF NOT EXISTS actor_id UUID,
  ADD COLUMN IF NOT EXISTS ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS session_id UUID,
  ADD COLUMN IF NOT EXISTS correlation_id UUID,
  ADD COLUMN IF NOT EXISTS dedupe_key TEXT;

-- Backfill de subject_id para dados existentes
UPDATE public.journey_events
  SET subject_id = lead_id
  WHERE subject_id IS NULL AND lead_id IS NOT NULL;

-- Índices novos
CREATE INDEX IF NOT EXISTS idx_journey_events_subject
  ON public.journey_events (organization_id, subject_type, subject_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_journey_events_session
  ON public.journey_events (organization_id, session_id) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_journey_events_correlation
  ON public.journey_events (organization_id, correlation_id) WHERE correlation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_journey_events_source_module
  ON public.journey_events (organization_id, source_module, occurred_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_journey_events_dedupe
  ON public.journey_events (organization_id, source_module, dedupe_key)
  WHERE dedupe_key IS NOT NULL;

-- 4) View de compatibilidade (leitura)
DROP VIEW IF EXISTS public.lead_journey_events;
CREATE VIEW public.lead_journey_events AS
  SELECT * FROM public.journey_events WHERE subject_type = 'lead';

GRANT SELECT ON public.lead_journey_events TO authenticated;
GRANT ALL ON public.lead_journey_events TO service_role;

-- 5) Nova tabela: Touchpoints
CREATE TABLE IF NOT EXISTS public.journey_touchpoints (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  lead_id UUID REFERENCES public.leads(id) ON DELETE CASCADE,
  touchpoint_type TEXT NOT NULL,
  channel TEXT,
  source TEXT,
  campaign_ref TEXT,
  event_id UUID REFERENCES public.journey_events(id) ON DELETE SET NULL,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_touchpoints_org_lead
  ON public.journey_touchpoints (organization_id, lead_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_touchpoints_channel
  ON public.journey_touchpoints (organization_id, channel, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_touchpoints_type
  ON public.journey_touchpoints (organization_id, touchpoint_type, occurred_at DESC);

GRANT SELECT ON public.journey_touchpoints TO authenticated;
GRANT ALL ON public.journey_touchpoints TO service_role;
ALTER TABLE public.journey_touchpoints ENABLE ROW LEVEL SECURITY;

CREATE POLICY "org members read touchpoints"
  ON public.journey_touchpoints FOR SELECT TO authenticated
  USING (organization_id IN (
    SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid()
  ) OR public.has_role(auth.uid(), 'super_admin'::public.app_role));

CREATE POLICY "service manages touchpoints"
  ON public.journey_touchpoints FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- 6) Nova tabela: lead_sources (snapshot atribuição)
CREATE TABLE IF NOT EXISTS public.lead_sources (
  lead_id UUID NOT NULL PRIMARY KEY REFERENCES public.leads(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  first_touch_channel TEXT,
  first_touch_source TEXT,
  first_touch_campaign_id TEXT,
  first_touch_at TIMESTAMPTZ,
  last_touch_channel TEXT,
  last_touch_source TEXT,
  last_touch_campaign_id TEXT,
  last_touch_at TIMESTAMPTZ,
  touch_count INTEGER NOT NULL DEFAULT 0,
  channels_used TEXT[] NOT NULL DEFAULT '{}',
  attribution_model_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_lead_sources_org ON public.lead_sources (organization_id);

GRANT SELECT ON public.lead_sources TO authenticated;
GRANT ALL ON public.lead_sources TO service_role;
ALTER TABLE public.lead_sources ENABLE ROW LEVEL SECURITY;

CREATE POLICY "org members read lead_sources"
  ON public.lead_sources FOR SELECT TO authenticated
  USING (organization_id IN (
    SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid()
  ) OR public.has_role(auth.uid(), 'super_admin'::public.app_role));

CREATE POLICY "service manages lead_sources"
  ON public.lead_sources FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- 7) Nova tabela: lead_sessions
CREATE TABLE IF NOT EXISTS public.lead_sessions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  lead_id UUID REFERENCES public.leads(id) ON DELETE CASCADE,
  channel TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at TIMESTAMPTZ,
  entry_event_id UUID REFERENCES public.journey_events(id) ON DELETE SET NULL,
  exit_event_id UUID REFERENCES public.journey_events(id) ON DELETE SET NULL,
  event_count INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_lead_sessions_org_lead
  ON public.lead_sessions (organization_id, lead_id, started_at DESC);

GRANT SELECT ON public.lead_sessions TO authenticated;
GRANT ALL ON public.lead_sessions TO service_role;
ALTER TABLE public.lead_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "org members read lead_sessions"
  ON public.lead_sessions FOR SELECT TO authenticated
  USING (organization_id IN (
    SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid()
  ) OR public.has_role(auth.uid(), 'super_admin'::public.app_role));

CREATE POLICY "service manages lead_sessions"
  ON public.lead_sessions FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- 8) Colunas de click IDs em leads
ALTER TABLE public.leads
  ADD COLUMN IF NOT EXISTS ctwa_clid TEXT,
  ADD COLUMN IF NOT EXISTS fbclid TEXT,
  ADD COLUMN IF NOT EXISTS gclid TEXT,
  ADD COLUMN IF NOT EXISTS ttclid TEXT,
  ADD COLUMN IF NOT EXISTS li_fat_id TEXT;

CREATE INDEX IF NOT EXISTS idx_leads_ctwa_clid ON public.leads (ctwa_clid) WHERE ctwa_clid IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_leads_fbclid ON public.leads (fbclid) WHERE fbclid IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_leads_gclid ON public.leads (gclid) WHERE gclid IS NOT NULL;

-- 9) Função emit_journey_event — bus interno (chamável de triggers/RPCs)
CREATE OR REPLACE FUNCTION public.emit_journey_event(
  p_organization_id UUID,
  p_subject_type TEXT,
  p_subject_id UUID,
  p_event_type public.journey_event_type,
  p_event_category public.journey_event_category DEFAULT 'system',
  p_source_module TEXT DEFAULT NULL,
  p_channel TEXT DEFAULT NULL,
  p_source TEXT DEFAULT NULL,
  p_title TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_payload JSONB DEFAULT '{}'::jsonb,
  p_actor_type TEXT DEFAULT 'system',
  p_actor_id UUID DEFAULT NULL,
  p_lead_id UUID DEFAULT NULL,
  p_conversation_id UUID DEFAULT NULL,
  p_deal_id UUID DEFAULT NULL,
  p_product_id UUID DEFAULT NULL,
  p_pipeline_stage_id UUID DEFAULT NULL,
  p_user_id UUID DEFAULT NULL,
  p_agent_id UUID DEFAULT NULL,
  p_occurred_at TIMESTAMPTZ DEFAULT now(),
  p_correlation_id UUID DEFAULT NULL,
  p_session_id UUID DEFAULT NULL,
  p_dedupe_key TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
  v_effective_lead UUID;
BEGIN
  v_effective_lead := COALESCE(p_lead_id, CASE WHEN p_subject_type = 'lead' THEN p_subject_id END);

  INSERT INTO public.journey_events (
    organization_id, subject_type, subject_id,
    event_type, event_category, source_module,
    channel, source, title, description, payload,
    actor_type, actor_id,
    lead_id, conversation_id, deal_id, product_id, pipeline_stage_id, user_id, agent_id,
    occurred_at, correlation_id, session_id, dedupe_key
  ) VALUES (
    p_organization_id, p_subject_type, p_subject_id,
    p_event_type, p_event_category, p_source_module,
    p_channel, p_source, p_title, p_description, COALESCE(p_payload, '{}'::jsonb),
    p_actor_type, p_actor_id,
    v_effective_lead, p_conversation_id, p_deal_id, p_product_id, p_pipeline_stage_id, p_user_id, p_agent_id,
    p_occurred_at, p_correlation_id, p_session_id, p_dedupe_key
  )
  ON CONFLICT (organization_id, source_module, dedupe_key) DO NOTHING
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.emit_journey_event(UUID,TEXT,UUID,public.journey_event_type,public.journey_event_category,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,UUID,UUID,UUID,UUID,UUID,UUID,UUID,UUID,TIMESTAMPTZ,UUID,UUID,TEXT) TO authenticated, service_role;

-- 10) Trigger de derivação: gera touchpoint + atualiza lead_sources
CREATE OR REPLACE FUNCTION public.journey_derive_touchpoint()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_touch_type TEXT;
  v_campaign TEXT;
BEGIN
  IF NEW.lead_id IS NULL OR NEW.channel IS NULL THEN
    RETURN NEW;
  END IF;

  -- Só geramos touchpoint para eventos considerados "contato externo"
  IF NEW.event_category NOT IN ('origin','contact','attendance','meeting','sale') THEN
    RETURN NEW;
  END IF;

  v_touch_type := COALESCE(NEW.payload->>'touchpoint_type', NEW.channel);
  v_campaign := COALESCE(NEW.payload->>'campaign_id', NEW.payload->>'utm_campaign');

  INSERT INTO public.journey_touchpoints (
    organization_id, lead_id, touchpoint_type, channel, source, campaign_ref, event_id, occurred_at, payload
  ) VALUES (
    NEW.organization_id, NEW.lead_id, v_touch_type, NEW.channel, NEW.source, v_campaign, NEW.id, NEW.occurred_at, NEW.payload
  );

  -- Upsert lead_sources
  INSERT INTO public.lead_sources (
    lead_id, organization_id,
    first_touch_channel, first_touch_source, first_touch_campaign_id, first_touch_at,
    last_touch_channel, last_touch_source, last_touch_campaign_id, last_touch_at,
    touch_count, channels_used, updated_at
  ) VALUES (
    NEW.lead_id, NEW.organization_id,
    NEW.channel, NEW.source, v_campaign, NEW.occurred_at,
    NEW.channel, NEW.source, v_campaign, NEW.occurred_at,
    1, ARRAY[NEW.channel], now()
  )
  ON CONFLICT (lead_id) DO UPDATE SET
    last_touch_channel = EXCLUDED.last_touch_channel,
    last_touch_source = EXCLUDED.last_touch_source,
    last_touch_campaign_id = EXCLUDED.last_touch_campaign_id,
    last_touch_at = EXCLUDED.last_touch_at,
    touch_count = public.lead_sources.touch_count + 1,
    channels_used = (
      SELECT ARRAY(SELECT DISTINCT unnest(public.lead_sources.channels_used || ARRAY[EXCLUDED.last_touch_channel]))
    ),
    updated_at = now();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journey_derive_touchpoint ON public.journey_events;
CREATE TRIGGER trg_journey_derive_touchpoint
  AFTER INSERT ON public.journey_events
  FOR EACH ROW
  EXECUTE FUNCTION public.journey_derive_touchpoint();
