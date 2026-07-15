-- 1) Extend voice_agents (aditivo)
ALTER TABLE public.voice_agents
  ADD COLUMN IF NOT EXISTS product_agent_id uuid REFERENCES public.product_agents(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS grok_voice_id text,
  ADD COLUMN IF NOT EXISTS voice_settings jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS context_override text;

-- Torna colunas antigas nullable (fallback legado)
ALTER TABLE public.voice_agents ALTER COLUMN system_prompt DROP NOT NULL;

CREATE INDEX IF NOT EXISTS idx_voice_agents_product_agent ON public.voice_agents(product_agent_id);

-- 2) voice_clones
CREATE TABLE IF NOT EXISTS public.voice_clones (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  grok_voice_id text,
  sample_urls jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'processing' CHECK (status IN ('processing','ready','failed')),
  status_reason text,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.voice_clones TO authenticated;
GRANT ALL ON public.voice_clones TO service_role;

ALTER TABLE public.voice_clones ENABLE ROW LEVEL SECURITY;

CREATE POLICY "voice_clones_select_org" ON public.voice_clones
  FOR SELECT TO authenticated
  USING (
    organization_id IN (SELECT organization_id FROM public.profiles WHERE id = auth.uid())
    OR public.has_role(auth.uid(), 'super_admin'::app_role)
  );

CREATE POLICY "voice_clones_insert_admin" ON public.voice_clones
  FOR INSERT TO authenticated
  WITH CHECK (
    organization_id IN (SELECT organization_id FROM public.profiles WHERE id = auth.uid())
    AND (public.has_role(auth.uid(), 'admin'::app_role) OR public.has_role(auth.uid(), 'super_admin'::app_role))
  );

CREATE POLICY "voice_clones_update_admin" ON public.voice_clones
  FOR UPDATE TO authenticated
  USING (
    organization_id IN (SELECT organization_id FROM public.profiles WHERE id = auth.uid())
    AND (public.has_role(auth.uid(), 'admin'::app_role) OR public.has_role(auth.uid(), 'super_admin'::app_role))
  );

CREATE POLICY "voice_clones_delete_admin" ON public.voice_clones
  FOR DELETE TO authenticated
  USING (
    organization_id IN (SELECT organization_id FROM public.profiles WHERE id = auth.uid())
    AND (public.has_role(auth.uid(), 'admin'::app_role) OR public.has_role(auth.uid(), 'super_admin'::app_role))
  );

CREATE TRIGGER trg_voice_clones_updated_at
  BEFORE UPDATE ON public.voice_clones
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE INDEX IF NOT EXISTS idx_voice_clones_org ON public.voice_clones(organization_id);
CREATE INDEX IF NOT EXISTS idx_voice_clones_status ON public.voice_clones(status);