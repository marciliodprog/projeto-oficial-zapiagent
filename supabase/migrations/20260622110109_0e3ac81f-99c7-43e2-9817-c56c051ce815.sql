CREATE OR REPLACE FUNCTION public.create_onboarding_link(_organization_id uuid, _ttl_days integer DEFAULT 7)
 RETURNS TABLE(submission_id uuid, token text, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  _token text;
  _hash text;
  _exp timestamptz;
  _sid uuid;
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF _ttl_days IS NULL OR _ttl_days < 1 OR _ttl_days > 30 THEN
    _ttl_days := 7;
  END IF;

  _token := encode(extensions.gen_random_bytes(32), 'base64');
  _token := replace(replace(replace(_token, '+', '-'), '/', '_'), '=', '');
  _hash  := encode(extensions.digest(_token, 'sha256'), 'hex');
  _exp   := now() + (_ttl_days || ' days')::interval;

  INSERT INTO public.onboarding_submissions(
    organization_id, token_hash, mode, status, expires_at, created_by
  ) VALUES (
    _organization_id, _hash, 'link', 'draft', _exp, auth.uid()
  ) RETURNING id INTO _sid;

  RETURN QUERY SELECT _sid, _token, _exp;
END $function$;