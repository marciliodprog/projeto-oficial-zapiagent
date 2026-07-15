-- Journey Engine — Phase 3

-- Novos tipos de evento
DO $$ BEGIN
  ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'meta_ctwa_received';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'meta_click_received';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'campaign_identified';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 1) Credenciais Meta por empresa
CREATE TABLE IF NOT EXISTS public.org_marketing_credentials (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  provider TEXT NOT NULL CHECK (provider IN ('meta','google','tiktok','linkedin')),
  access_token_encrypted TEXT,
  refresh_token_encrypted TEXT,
  expires_at TIMESTAMPTZ,
  business_id TEXT,
  ad_account_id TEXT,
  account_name TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  last_sync_at TIMESTAMPTZ,
  last_sync_status TEXT,
  last_sync_error TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, provider, ad_account_id)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.org_marketing_credentials TO authenticated;
GRANT ALL ON public.org_marketing_credentials TO service_role;
ALTER TABLE public.org_marketing_credentials ENABLE ROW LEVEL SECURITY;

CREATE POLICY "org marketing creds admin visibility"
  ON public.org_marketing_credentials FOR SELECT
  USING (
    public.is_super_admin(auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.user_organizations uo
      WHERE uo.user_id = auth.uid()
        AND uo.organization_id = org_marketing_credentials.organization_id
        AND uo.role = 'admin'
    )
  );

CREATE POLICY "org marketing creds admin manage"
  ON public.org_marketing_credentials FOR ALL
  USING (
    public.is_super_admin(auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.user_organizations uo
      WHERE uo.user_id = auth.uid()
        AND uo.organization_id = org_marketing_credentials.organization_id
        AND uo.role = 'admin'
    )
  )
  WITH CHECK (
    public.is_super_admin(auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.user_organizations uo
      WHERE uo.user_id = auth.uid()
        AND uo.organization_id = org_marketing_credentials.organization_id
        AND uo.role = 'admin'
    )
  );

-- 2) Catálogo
CREATE TABLE IF NOT EXISTS public.marketing_campaigns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  external_id TEXT NOT NULL,
  ad_account_id TEXT,
  name TEXT, objective TEXT, status TEXT,
  daily_budget NUMERIC(12,2), lifetime_budget NUMERIC(12,2),
  start_time TIMESTAMPTZ, stop_time TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  synced_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, provider, external_id)
);

CREATE TABLE IF NOT EXISTS public.marketing_adsets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  campaign_id UUID REFERENCES public.marketing_campaigns(id) ON DELETE CASCADE,
  provider TEXT NOT NULL, external_id TEXT NOT NULL,
  campaign_external_id TEXT, name TEXT, status TEXT,
  targeting JSONB NOT NULL DEFAULT '{}'::jsonb,
  daily_budget NUMERIC(12,2), lifetime_budget NUMERIC(12,2),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  synced_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, provider, external_id)
);

CREATE TABLE IF NOT EXISTS public.marketing_creatives (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  provider TEXT NOT NULL, external_id TEXT NOT NULL,
  name TEXT, headline TEXT, body TEXT, cta_type TEXT,
  thumbnail_url TEXT, media_url TEXT, content_hash TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  synced_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, provider, external_id)
);

CREATE TABLE IF NOT EXISTS public.marketing_ads (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  adset_id UUID REFERENCES public.marketing_adsets(id) ON DELETE CASCADE,
  campaign_id UUID REFERENCES public.marketing_campaigns(id) ON DELETE CASCADE,
  creative_id UUID REFERENCES public.marketing_creatives(id) ON DELETE SET NULL,
  provider TEXT NOT NULL, external_id TEXT NOT NULL,
  adset_external_id TEXT, campaign_external_id TEXT, creative_external_id TEXT,
  name TEXT, status TEXT, preview_url TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  synced_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, provider, external_id)
);

CREATE TABLE IF NOT EXISTS public.marketing_insights_daily (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  entity_type TEXT NOT NULL CHECK (entity_type IN ('campaign','adset','ad')),
  entity_external_id TEXT NOT NULL,
  date DATE NOT NULL,
  spend NUMERIC(14,2) NOT NULL DEFAULT 0,
  impressions INTEGER NOT NULL DEFAULT 0,
  clicks INTEGER NOT NULL DEFAULT 0,
  ctr NUMERIC(8,4), cpc NUMERIC(12,4), cpm NUMERIC(12,4),
  reach INTEGER, frequency NUMERIC(8,4),
  ctwa_clicks INTEGER NOT NULL DEFAULT 0,
  purchases INTEGER NOT NULL DEFAULT 0,
  revenue NUMERIC(14,2) NOT NULL DEFAULT 0,
  raw JSONB NOT NULL DEFAULT '{}'::jsonb,
  synced_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, provider, entity_type, entity_external_id, date)
);

CREATE INDEX IF NOT EXISTS idx_mkt_campaigns_org ON public.marketing_campaigns (organization_id, provider);
CREATE INDEX IF NOT EXISTS idx_mkt_adsets_org ON public.marketing_adsets (organization_id, provider);
CREATE INDEX IF NOT EXISTS idx_mkt_ads_org ON public.marketing_ads (organization_id, provider);
CREATE INDEX IF NOT EXISTS idx_mkt_ads_metadata_gin ON public.marketing_ads USING GIN (metadata);
CREATE INDEX IF NOT EXISTS idx_mkt_insights_org_date ON public.marketing_insights_daily (organization_id, provider, entity_type, date DESC);
CREATE INDEX IF NOT EXISTS idx_mkt_insights_entity ON public.marketing_insights_daily (organization_id, entity_type, entity_external_id, date DESC);

GRANT SELECT ON public.marketing_campaigns TO authenticated;
GRANT SELECT ON public.marketing_adsets TO authenticated;
GRANT SELECT ON public.marketing_ads TO authenticated;
GRANT SELECT ON public.marketing_creatives TO authenticated;
GRANT SELECT ON public.marketing_insights_daily TO authenticated;
GRANT ALL ON public.marketing_campaigns TO service_role;
GRANT ALL ON public.marketing_adsets TO service_role;
GRANT ALL ON public.marketing_ads TO service_role;
GRANT ALL ON public.marketing_creatives TO service_role;
GRANT ALL ON public.marketing_insights_daily TO service_role;

ALTER TABLE public.marketing_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketing_adsets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketing_ads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketing_creatives ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketing_insights_daily ENABLE ROW LEVEL SECURITY;

CREATE POLICY "mkt_campaigns org read" ON public.marketing_campaigns FOR SELECT
  USING (public.is_super_admin(auth.uid()) OR EXISTS (
    SELECT 1 FROM public.user_organizations uo
    WHERE uo.user_id = auth.uid() AND uo.organization_id = marketing_campaigns.organization_id AND uo.role = 'admin'));
CREATE POLICY "mkt_adsets org read" ON public.marketing_adsets FOR SELECT
  USING (public.is_super_admin(auth.uid()) OR EXISTS (
    SELECT 1 FROM public.user_organizations uo
    WHERE uo.user_id = auth.uid() AND uo.organization_id = marketing_adsets.organization_id AND uo.role = 'admin'));
CREATE POLICY "mkt_ads org read" ON public.marketing_ads FOR SELECT
  USING (public.is_super_admin(auth.uid()) OR EXISTS (
    SELECT 1 FROM public.user_organizations uo
    WHERE uo.user_id = auth.uid() AND uo.organization_id = marketing_ads.organization_id AND uo.role = 'admin'));
CREATE POLICY "mkt_creatives org read" ON public.marketing_creatives FOR SELECT
  USING (public.is_super_admin(auth.uid()) OR EXISTS (
    SELECT 1 FROM public.user_organizations uo
    WHERE uo.user_id = auth.uid() AND uo.organization_id = marketing_creatives.organization_id AND uo.role = 'admin'));
CREATE POLICY "mkt_insights org read" ON public.marketing_insights_daily FOR SELECT
  USING (public.is_super_admin(auth.uid()) OR EXISTS (
    SELECT 1 FROM public.user_organizations uo
    WHERE uo.user_id = auth.uid() AND uo.organization_id = marketing_insights_daily.organization_id AND uo.role = 'admin'));

-- updated_at triggers
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'update_updated_at_column' AND pronamespace = 'public'::regnamespace) THEN
    EXECUTE 'DROP TRIGGER IF EXISTS trg_mkt_campaigns_upd ON public.marketing_campaigns';
    EXECUTE 'CREATE TRIGGER trg_mkt_campaigns_upd BEFORE UPDATE ON public.marketing_campaigns FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column()';
    EXECUTE 'DROP TRIGGER IF EXISTS trg_mkt_adsets_upd ON public.marketing_adsets';
    EXECUTE 'CREATE TRIGGER trg_mkt_adsets_upd BEFORE UPDATE ON public.marketing_adsets FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column()';
    EXECUTE 'DROP TRIGGER IF EXISTS trg_mkt_ads_upd ON public.marketing_ads';
    EXECUTE 'CREATE TRIGGER trg_mkt_ads_upd BEFORE UPDATE ON public.marketing_ads FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column()';
    EXECUTE 'DROP TRIGGER IF EXISTS trg_mkt_creatives_upd ON public.marketing_creatives';
    EXECUTE 'CREATE TRIGGER trg_mkt_creatives_upd BEFORE UPDATE ON public.marketing_creatives FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column()';
    EXECUTE 'DROP TRIGGER IF EXISTS trg_mkt_insights_upd ON public.marketing_insights_daily';
    EXECUTE 'CREATE TRIGGER trg_mkt_insights_upd BEFORE UPDATE ON public.marketing_insights_daily FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column()';
    EXECUTE 'DROP TRIGGER IF EXISTS trg_mkt_creds_upd ON public.org_marketing_credentials';
    EXECUTE 'CREATE TRIGGER trg_mkt_creds_upd BEFORE UPDATE ON public.org_marketing_credentials FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column()';
  END IF;
END $$;

-- 3) resolve_click_attribution
CREATE OR REPLACE FUNCTION public.resolve_click_attribution(p_lead_id UUID)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_lead RECORD;
  v_ad RECORD;
  v_evt UUID;
BEGIN
  SELECT id, organization_id, ctwa_clid, fbclid, gclid, ttclid, li_fat_id
    INTO v_lead FROM public.leads WHERE id = p_lead_id;
  IF v_lead.id IS NULL THEN RETURN NULL; END IF;
  IF COALESCE(v_lead.ctwa_clid, v_lead.fbclid, v_lead.gclid, v_lead.ttclid, v_lead.li_fat_id) IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT a.id, a.external_id, a.name, a.campaign_id, a.adset_id, a.creative_id,
         a.campaign_external_id, a.adset_external_id, a.creative_external_id, a.provider
    INTO v_ad
    FROM public.marketing_ads a
   WHERE a.organization_id = v_lead.organization_id
     AND (
       (v_lead.ctwa_clid IS NOT NULL AND a.metadata ? 'ctwa_clids' AND a.metadata->'ctwa_clids' ? v_lead.ctwa_clid)
       OR (v_lead.fbclid IS NOT NULL AND a.metadata->>'fbclid' = v_lead.fbclid)
     )
   ORDER BY a.updated_at DESC
   LIMIT 1;

  IF v_ad.id IS NULL THEN
    v_evt := public.emit_journey_event(
      p_organization_id := v_lead.organization_id,
      p_subject_type := 'lead', p_subject_id := v_lead.id,
      p_event_type := 'meta_click_received'::public.journey_event_type,
      p_event_category := 'origin'::public.journey_event_category,
      p_source_module := 'attribution',
      p_channel := 'facebook', p_source := 'meta_ctwa',
      p_title := 'Clique de anúncio (aguardando catálogo)',
      p_payload := jsonb_build_object(
        'ctwa_clid', v_lead.ctwa_clid, 'fbclid', v_lead.fbclid,
        'pending_resolution', true
      ),
      p_lead_id := v_lead.id,
      p_dedupe_key := 'ctwa-pending:' || v_lead.id::text
    );
    RETURN v_evt;
  END IF;

  v_evt := public.emit_journey_event(
    p_organization_id := v_lead.organization_id,
    p_subject_type := 'lead', p_subject_id := v_lead.id,
    p_event_type := 'campaign_identified'::public.journey_event_type,
    p_event_category := 'origin'::public.journey_event_category,
    p_source_module := 'attribution',
    p_channel := 'facebook', p_source := v_ad.provider,
    p_title := 'Anúncio identificado: ' || COALESCE(v_ad.name, v_ad.external_id),
    p_payload := jsonb_build_object(
      'ad_id', v_ad.id, 'ad_external_id', v_ad.external_id,
      'adset_id', v_ad.adset_id, 'adset_external_id', v_ad.adset_external_id,
      'campaign_id', v_ad.campaign_id, 'campaign_external_id', v_ad.campaign_external_id,
      'creative_id', v_ad.creative_id, 'creative_external_id', v_ad.creative_external_id,
      'ctwa_clid', v_lead.ctwa_clid, 'fbclid', v_lead.fbclid
    ),
    p_lead_id := v_lead.id,
    p_dedupe_key := 'attr:' || v_lead.id::text || ':' || v_ad.id::text
  );

  UPDATE public.lead_sources
     SET first_touch_campaign_id = COALESCE(first_touch_campaign_id, v_ad.campaign_id),
         last_touch_campaign_id = v_ad.campaign_id,
         updated_at = now()
   WHERE lead_id = v_lead.id;

  RETURN v_evt;
END;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_click_attribution(UUID) TO authenticated, service_role;