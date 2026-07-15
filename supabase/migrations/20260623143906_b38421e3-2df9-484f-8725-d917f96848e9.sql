
CREATE TABLE public.seller_lead_form_config (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL UNIQUE,
  fields jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.seller_lead_form_config TO authenticated;
GRANT ALL ON public.seller_lead_form_config TO service_role;

ALTER TABLE public.seller_lead_form_config ENABLE ROW LEVEL SECURITY;

-- Read: any authenticated user in the same org
CREATE POLICY "members read seller form config"
ON public.seller_lead_form_config FOR SELECT
TO authenticated
USING (
  organization_id = (SELECT organization_id FROM public.profiles WHERE id = auth.uid())
  OR public.has_role(auth.uid(), 'super_admin')
);

-- Write: only admins or super_admins of the org
CREATE POLICY "admins manage seller form config"
ON public.seller_lead_form_config FOR ALL
TO authenticated
USING (
  (organization_id = (SELECT organization_id FROM public.profiles WHERE id = auth.uid())
    AND public.has_role(auth.uid(), 'admin'))
  OR public.has_role(auth.uid(), 'super_admin')
)
WITH CHECK (
  (organization_id = (SELECT organization_id FROM public.profiles WHERE id = auth.uid())
    AND public.has_role(auth.uid(), 'admin'))
  OR public.has_role(auth.uid(), 'super_admin')
);

CREATE TRIGGER update_seller_lead_form_config_updated_at
BEFORE UPDATE ON public.seller_lead_form_config
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
