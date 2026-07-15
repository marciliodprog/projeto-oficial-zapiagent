ALTER TABLE public.forms ADD COLUMN IF NOT EXISTS use_for_manual_lead boolean NOT NULL DEFAULT false;

CREATE UNIQUE INDEX IF NOT EXISTS forms_manual_lead_unique_per_org
  ON public.forms (organization_id)
  WHERE use_for_manual_lead = true;

CREATE OR REPLACE FUNCTION public.set_manual_lead_form(_form_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _org uuid;
BEGIN
  SELECT organization_id INTO _org FROM public.forms WHERE id = _form_id;
  IF _org IS NULL THEN
    RAISE EXCEPTION 'Form not found';
  END IF;
  IF NOT (
    public.has_role(auth.uid(), 'super_admin')
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.organization_id = _org)
  ) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  UPDATE public.forms SET use_for_manual_lead = false
   WHERE organization_id = _org AND id <> _form_id AND use_for_manual_lead = true;
  UPDATE public.forms SET use_for_manual_lead = true, status = 'active'
   WHERE id = _form_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.unset_manual_lead_form(_form_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _org uuid;
BEGIN
  SELECT organization_id INTO _org FROM public.forms WHERE id = _form_id;
  IF _org IS NULL THEN RETURN; END IF;
  IF NOT (
    public.has_role(auth.uid(), 'super_admin')
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.organization_id = _org)
  ) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  UPDATE public.forms SET use_for_manual_lead = false WHERE id = _form_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_manual_lead_form(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unset_manual_lead_form(uuid) TO authenticated;