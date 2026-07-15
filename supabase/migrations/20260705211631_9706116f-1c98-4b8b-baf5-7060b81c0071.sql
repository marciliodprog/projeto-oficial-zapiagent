-- =========================================================
-- Voice Campaigns v2 — funnel expansion (additive)
-- =========================================================

-- 1. Expand voice_campaigns
ALTER TABLE public.voice_campaigns
  ADD COLUMN IF NOT EXISTS product_id uuid REFERENCES public.products(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS audience_filters jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS exclusion_filters jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS context_id uuid REFERENCES public.voice_contexts(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS dial_numbers jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS dial_strategy text NOT NULL DEFAULT 'round_robin',
  ADD COLUMN IF NOT EXISTS business_hours_only boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS timezone text NOT NULL DEFAULT 'America/Sao_Paulo',
  ADD COLUMN IF NOT EXISTS scheduled_at timestamptz,
  ADD COLUMN IF NOT EXISTS post_call_actions jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS source_webhook_id uuid,
  ADD COLUMN IF NOT EXISTS totals jsonb NOT NULL DEFAULT '{}'::jsonb;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'voice_campaigns_dial_strategy_check') THEN
    ALTER TABLE public.voice_campaigns
      ADD CONSTRAINT voice_campaigns_dial_strategy_check
      CHECK (dial_strategy IN ('round_robin','random','weighted'));
  END IF;
END $$;

-- 2. voice_campaign_journeys
CREATE TABLE IF NOT EXISTS public.voice_campaign_journeys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  campaign_id uuid REFERENCES public.voice_campaigns(id) ON DELETE CASCADE,
  lead_id uuid REFERENCES public.leads(id) ON DELETE CASCADE,
  target_id uuid REFERENCES public.voice_campaign_targets(id) ON DELETE SET NULL,
  call_log_id uuid REFERENCES public.call_logs(id) ON DELETE SET NULL,
  stage text NOT NULL,
  chosen_channel text,
  chosen_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  utm jsonb NOT NULL DEFAULT '{}'::jsonb,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.voice_campaign_journeys TO authenticated;
GRANT ALL ON public.voice_campaign_journeys TO service_role;

ALTER TABLE public.voice_campaign_journeys ENABLE ROW LEVEL SECURITY;

CREATE POLICY "org members read voice journeys"
  ON public.voice_campaign_journeys FOR SELECT
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid()
    )
    OR public.has_role(auth.uid(), 'super_admin'::app_role)
  );

CREATE POLICY "org managers write voice journeys"
  ON public.voice_campaign_journeys FOR ALL
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid()
    )
    OR public.has_role(auth.uid(), 'super_admin'::app_role)
  )
  WITH CHECK (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid()
    )
    OR public.has_role(auth.uid(), 'super_admin'::app_role)
  );

CREATE INDEX IF NOT EXISTS idx_voice_journeys_campaign_stage
  ON public.voice_campaign_journeys (campaign_id, stage);
CREATE INDEX IF NOT EXISTS idx_voice_journeys_lead
  ON public.voice_campaign_journeys (lead_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_voice_journeys_org_created
  ON public.voice_campaign_journeys (organization_id, created_at DESC);

-- 3. voice_inbound_webhooks
CREATE TABLE IF NOT EXISTS public.voice_inbound_webhooks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name text NOT NULL,
  token text NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(24), 'hex'),
  campaign_id uuid REFERENCES public.voice_campaigns(id) ON DELETE SET NULL,
  mode text NOT NULL DEFAULT 'enroll_campaign',
  default_agent_id uuid REFERENCES public.voice_agents(id) ON DELETE SET NULL,
  schedule_offset_minutes integer NOT NULL DEFAULT 0,
  field_mapping jsonb NOT NULL DEFAULT '{}'::jsonb,
  default_tags text[] NOT NULL DEFAULT ARRAY[]::text[],
  default_source text,
  active boolean NOT NULL DEFAULT true,
  last_triggered_at timestamptz,
  trigger_count integer NOT NULL DEFAULT 0,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT voice_inbound_webhooks_mode_check
    CHECK (mode IN ('enroll_campaign','call_immediate','call_scheduled'))
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.voice_inbound_webhooks TO authenticated;
GRANT ALL ON public.voice_inbound_webhooks TO service_role;

ALTER TABLE public.voice_inbound_webhooks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "org members read voice webhooks"
  ON public.voice_inbound_webhooks FOR SELECT
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid()
    )
    OR public.has_role(auth.uid(), 'super_admin'::app_role)
  );

CREATE POLICY "org admins manage voice webhooks"
  ON public.voice_inbound_webhooks FOR ALL
  TO authenticated
  USING (
    (
      organization_id IN (
        SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid()
      )
      AND (
        public.has_role(auth.uid(), 'admin'::app_role)
        OR public.has_role(auth.uid(), 'manager'::app_role)
      )
    )
    OR public.has_role(auth.uid(), 'super_admin'::app_role)
  )
  WITH CHECK (
    (
      organization_id IN (
        SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid()
      )
      AND (
        public.has_role(auth.uid(), 'admin'::app_role)
        OR public.has_role(auth.uid(), 'manager'::app_role)
      )
    )
    OR public.has_role(auth.uid(), 'super_admin'::app_role)
  );

CREATE INDEX IF NOT EXISTS idx_voice_webhooks_token
  ON public.voice_inbound_webhooks (token) WHERE active = true;
CREATE INDEX IF NOT EXISTS idx_voice_webhooks_org
  ON public.voice_inbound_webhooks (organization_id, created_at DESC);

CREATE TRIGGER update_voice_inbound_webhooks_updated_at
  BEFORE UPDATE ON public.voice_inbound_webhooks
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 4. journey_id on targets (optional link)
ALTER TABLE public.voice_campaign_targets
  ADD COLUMN IF NOT EXISTS journey_id uuid REFERENCES public.voice_campaign_journeys(id) ON DELETE SET NULL;

-- 5. audience count RPC
CREATE OR REPLACE FUNCTION public.count_voice_campaign_audience(
  p_org uuid,
  p_filters jsonb,
  p_exclusions jsonb
) RETURNS TABLE (audience integer, excluded integer, will_receive integer)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_audience int := 0;
  v_excluded int := 0;
  v_tag_ids uuid[];
  v_source_ids uuid[];
  v_stage_ids uuid[];
  v_excl_tag_ids uuid[];
BEGIN
  IF NOT (
    p_org IN (SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid())
    OR public.has_role(auth.uid(), 'super_admin'::app_role)
  ) THEN
    RETURN QUERY SELECT 0, 0, 0;
    RETURN;
  END IF;

  v_tag_ids := ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_filters->'tag_ids','[]'::jsonb))::uuid);
  v_source_ids := ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_filters->'source_ids','[]'::jsonb))::uuid);
  v_stage_ids := ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_filters->'stage_ids','[]'::jsonb))::uuid);
  v_excl_tag_ids := ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_exclusions->'tag_ids','[]'::jsonb))::uuid);

  WITH base AS (
    SELECT l.id, l.phone
    FROM public.leads l
    WHERE l.organization_id = p_org
      AND l.phone IS NOT NULL AND length(l.phone) >= 8
      AND (cardinality(v_source_ids) = 0 OR l.lead_source_id = ANY(v_source_ids))
      AND (cardinality(v_stage_ids) = 0 OR l.pipeline_stage_id = ANY(v_stage_ids))
      AND (
        cardinality(v_tag_ids) = 0
        OR EXISTS (
          SELECT 1 FROM public.lead_tag_assignments a
          WHERE a.lead_id = l.id AND a.tag_id = ANY(v_tag_ids)
        )
      )
  ), excluded_set AS (
    SELECT b.id FROM base b
    WHERE (
      cardinality(v_excl_tag_ids) > 0 AND EXISTS (
        SELECT 1 FROM public.lead_tag_assignments a
        WHERE a.lead_id = b.id AND a.tag_id = ANY(v_excl_tag_ids)
      )
    )
  )
  SELECT
    (SELECT count(*) FROM base),
    (SELECT count(*) FROM excluded_set)
  INTO v_audience, v_excluded;

  RETURN QUERY SELECT v_audience, v_excluded, GREATEST(v_audience - v_excluded, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.count_voice_campaign_audience(uuid, jsonb, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.count_voice_campaign_audience(uuid, jsonb, jsonb) TO service_role;

-- 6. helper: resolve tracked url (used by tool-dispatch)
CREATE OR REPLACE FUNCTION public.append_utm_to_url(p_url text, p_utm jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_sep text;
  v_qs text := '';
  v_key text;
  v_val text;
BEGIN
  IF p_url IS NULL OR p_url = '' THEN RETURN p_url; END IF;
  v_sep := CASE WHEN position('?' in p_url) > 0 THEN '&' ELSE '?' END;
  FOR v_key, v_val IN SELECT * FROM jsonb_each_text(COALESCE(p_utm,'{}'::jsonb)) LOOP
    IF v_val IS NOT NULL AND v_val <> '' THEN
      v_qs := v_qs || CASE WHEN v_qs = '' THEN '' ELSE '&' END
              || v_key || '=' || replace(replace(v_val,' ','%20'),'&','%26');
    END IF;
  END LOOP;
  IF v_qs = '' THEN RETURN p_url; END IF;
  RETURN p_url || v_sep || v_qs;
END;
$$;

GRANT EXECUTE ON FUNCTION public.append_utm_to_url(text, jsonb) TO authenticated, service_role;