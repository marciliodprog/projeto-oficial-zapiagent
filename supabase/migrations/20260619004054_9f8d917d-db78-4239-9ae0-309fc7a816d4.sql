CREATE OR REPLACE FUNCTION public.get_or_create_first_access_onboarding()
RETURNS TABLE(submission_id uuid, organization_id uuid, payload jsonb, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  _org uuid;
  _row public.onboarding_submissions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'auth_required'; END IF;
  IF NOT public.has_role(auth.uid(), 'admin')
     AND NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT p.organization_id INTO _org FROM public.profiles p WHERE p.id = auth.uid();
  IF _org IS NULL THEN RAISE EXCEPTION 'no_org'; END IF;

  SELECT os.* INTO _row
    FROM public.onboarding_submissions os
   WHERE os.organization_id = _org
     AND os.status IN ('draft','submitted')
   ORDER BY os.created_at DESC LIMIT 1;

  IF _row.id IS NULL THEN
    INSERT INTO public.onboarding_submissions(organization_id, mode, status, created_by)
    VALUES (_org, 'first_access', 'draft', auth.uid())
    RETURNING * INTO _row;
  END IF;

  RETURN QUERY SELECT _row.id, _row.organization_id, _row.payload, _row.status;
END $$;