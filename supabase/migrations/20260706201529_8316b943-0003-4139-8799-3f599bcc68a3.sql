
-- =============== voice_calls (campanhas de Ligação Web como canal de captação) ===============
CREATE TABLE IF NOT EXISTS public.voice_calls (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  product_id UUID REFERENCES public.products(id) ON DELETE SET NULL,
  voice_agent_id UUID REFERENCES public.voice_agents(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  slug TEXT NOT NULL,
  context TEXT DEFAULT '',
  status TEXT NOT NULL DEFAULT 'draft', -- draft | active | paused | archived
  appearance JSONB NOT NULL DEFAULT '{}'::jsonb,
  capture_fields JSONB NOT NULL DEFAULT '[]'::jsonb, -- [{ key, label, type, required }]
  ctas JSONB NOT NULL DEFAULT '[]'::jsonb,           -- [{ id, kind, label, ... }]
  tracking JSONB NOT NULL DEFAULT '{}'::jsonb,       -- { meta_pixel_id, meta_access_token, ga4_id, webhook_url }
  stats JSONB NOT NULL DEFAULT '{}'::jsonb,          -- { views, calls, conversions }
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS voice_calls_slug_lower_uidx ON public.voice_calls (lower(slug));
CREATE INDEX IF NOT EXISTS voice_calls_org_idx ON public.voice_calls (organization_id);
CREATE INDEX IF NOT EXISTS voice_calls_product_idx ON public.voice_calls (product_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.voice_calls TO authenticated;
GRANT SELECT ON public.voice_calls TO anon; -- leitura pública controlada por policy (apenas status=active)
GRANT ALL ON public.voice_calls TO service_role;

ALTER TABLE public.voice_calls ENABLE ROW LEVEL SECURITY;

CREATE POLICY "voice_calls_public_read_active"
  ON public.voice_calls FOR SELECT
  TO anon, authenticated
  USING (status = 'active');

CREATE POLICY "voice_calls_org_members_all"
  ON public.voice_calls FOR ALL
  TO authenticated
  USING (
    organization_id IN (SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid())
    OR public.has_role(auth.uid(), 'super_admin')
  )
  WITH CHECK (
    organization_id IN (SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid())
    OR public.has_role(auth.uid(), 'super_admin')
  );

CREATE TRIGGER update_voice_calls_updated_at
  BEFORE UPDATE ON public.voice_calls
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- =============== voice_call_sessions (respostas / ligações realizadas) ===============
CREATE TABLE IF NOT EXISTS public.voice_call_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  voice_call_id UUID NOT NULL REFERENCES public.voice_calls(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  lead_id UUID REFERENCES public.leads(id) ON DELETE SET NULL,
  utms JSONB NOT NULL DEFAULT '{}'::jsonb,
  captured_data JSONB NOT NULL DEFAULT '{}'::jsonb, -- { nome, whatsapp, email, ... }
  transcript JSONB NOT NULL DEFAULT '[]'::jsonb,    -- [{ role, text, at }]
  summary JSONB NOT NULL DEFAULT '{}'::jsonb,       -- { objetivo, dores, objecoes, interesse, proximo_passo }
  ctas_clicked JSONB NOT NULL DEFAULT '[]'::jsonb,
  tags_applied JSONB NOT NULL DEFAULT '[]'::jsonb,
  duration_sec INTEGER DEFAULT 0,
  outcome TEXT,
  visitor_id TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS voice_call_sessions_call_idx ON public.voice_call_sessions (voice_call_id);
CREATE INDEX IF NOT EXISTS voice_call_sessions_org_idx ON public.voice_call_sessions (organization_id);
CREATE INDEX IF NOT EXISTS voice_call_sessions_lead_idx ON public.voice_call_sessions (lead_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.voice_call_sessions TO authenticated;
GRANT ALL ON public.voice_call_sessions TO service_role;

ALTER TABLE public.voice_call_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "voice_call_sessions_org_members_all"
  ON public.voice_call_sessions FOR ALL
  TO authenticated
  USING (
    organization_id IN (SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid())
    OR public.has_role(auth.uid(), 'super_admin')
  )
  WITH CHECK (
    organization_id IN (SELECT organization_id FROM public.user_organizations WHERE user_id = auth.uid())
    OR public.has_role(auth.uid(), 'super_admin')
  );

CREATE TRIGGER update_voice_call_sessions_updated_at
  BEFORE UPDATE ON public.voice_call_sessions
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
