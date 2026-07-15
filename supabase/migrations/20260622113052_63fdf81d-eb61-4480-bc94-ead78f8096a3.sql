
-- ============================================================
-- Travas de segurança no link público de implantação
-- ============================================================

-- 1. Novas colunas
ALTER TABLE public.onboarding_submissions
  ADD COLUMN IF NOT EXISTS first_seen_at timestamptz,
  ADD COLUMN IF NOT EXISTS first_seen_ip text,
  ADD COLUMN IF NOT EXISTS first_seen_ua text,
  ADD COLUMN IF NOT EXISTS session_token text,
  ADD COLUMN IF NOT EXISTS revoked_at timestamptz,
  ADD COLUMN IF NOT EXISTS revoked_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS access_count integer NOT NULL DEFAULT 0;

ALTER TABLE public.organizations
  ADD COLUMN IF NOT EXISTS onboarding_locked boolean NOT NULL DEFAULT false;

-- 2. Backfill: organizações com onboarding_completed_at viram locked
UPDATE public.organizations
   SET onboarding_locked = true
 WHERE onboarding_completed_at IS NOT NULL AND onboarding_locked = false;

-- ============================================================
-- 3. create_onboarding_link (Super Admin)
--    Aceita force_reopen para empresas já configuradas.
-- ============================================================
DROP FUNCTION IF EXISTS public.create_onboarding_link(uuid, integer);
DROP FUNCTION IF EXISTS public.create_onboarding_link(uuid, integer, boolean);

CREATE OR REPLACE FUNCTION public.create_onboarding_link(
  _organization_id uuid,
  _ttl_days integer DEFAULT 7,
  _force_reopen boolean DEFAULT false
) RETURNS TABLE(submission_id uuid, token text, expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = 'public', 'extensions'
AS $$
DECLARE
  _token text;
  _hash text;
  _exp timestamptz;
  _sid uuid;
  _org public.organizations%ROWTYPE;
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF _ttl_days IS NULL OR _ttl_days < 1 OR _ttl_days > 30 THEN
    _ttl_days := 7;
  END IF;

  SELECT * INTO _org FROM public.organizations WHERE id = _organization_id;
  IF _org.id IS NULL THEN
    RAISE EXCEPTION 'org_not_found';
  END IF;

  -- Empresa já configurada exige force_reopen
  IF (_org.onboarding_completed_at IS NOT NULL OR _org.onboarding_locked) AND NOT _force_reopen THEN
    RAISE EXCEPTION 'org_already_onboarded';
  END IF;

  -- Revoga submissions abertas pré-existentes para a mesma org
  UPDATE public.onboarding_submissions
     SET revoked_at = now(), revoked_by = auth.uid()
   WHERE organization_id = _organization_id
     AND status IN ('draft','submitted')
     AND revoked_at IS NULL;

  -- Se for reabertura forçada, destrava a organização
  IF _force_reopen THEN
    UPDATE public.organizations
       SET onboarding_locked = false
     WHERE id = _organization_id;
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

  -- Audit
  BEGIN
    INSERT INTO public.platform_audit_logs(action, actor_id, organization_id, metadata)
    VALUES ('onboarding_link_created', auth.uid(), _organization_id,
            jsonb_build_object('submission_id', _sid, 'ttl_days', _ttl_days, 'force_reopen', _force_reopen));
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN QUERY SELECT _sid, _token, _exp;
END $$;

GRANT EXECUTE ON FUNCTION public.create_onboarding_link(uuid, integer, boolean) TO authenticated;

-- ============================================================
-- 4. revoke_onboarding_link (Super Admin)
-- ============================================================
CREATE OR REPLACE FUNCTION public.revoke_onboarding_link(_submission_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  _row public.onboarding_submissions%ROWTYPE;
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  SELECT * INTO _row FROM public.onboarding_submissions WHERE id = _submission_id;
  IF _row.id IS NULL THEN RAISE EXCEPTION 'not_found'; END IF;

  UPDATE public.onboarding_submissions
     SET revoked_at = now(), revoked_by = auth.uid()
   WHERE id = _submission_id;

  BEGIN
    INSERT INTO public.platform_audit_logs(action, actor_id, organization_id, metadata)
    VALUES ('onboarding_link_revoked', auth.uid(), _row.organization_id,
            jsonb_build_object('submission_id', _submission_id));
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
END $$;

GRANT EXECUTE ON FUNCTION public.revoke_onboarding_link(uuid) TO authenticated;

-- ============================================================
-- 5. validate_onboarding_token (público — sem login)
--    Trava no primeiro acesso e retorna session_token.
-- ============================================================
DROP FUNCTION IF EXISTS public.validate_onboarding_token(text);
DROP FUNCTION IF EXISTS public.validate_onboarding_token(text, text, text, text);

CREATE OR REPLACE FUNCTION public.validate_onboarding_token(
  _token text,
  _session_token text DEFAULT NULL,
  _ip text DEFAULT NULL,
  _ua text DEFAULT NULL
) RETURNS TABLE(
  submission_id uuid,
  organization_id uuid,
  payload jsonb,
  status text,
  session_token text
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = 'public', 'extensions'
AS $$
DECLARE
  _hash text;
  _row public.onboarding_submissions%ROWTYPE;
  _org public.organizations%ROWTYPE;
  _new_session text;
BEGIN
  IF _token IS NULL OR length(_token) < 20 THEN
    RAISE EXCEPTION 'invalid_token';
  END IF;

  _hash := encode(extensions.digest(_token, 'sha256'), 'hex');
  SELECT * INTO _row FROM public.onboarding_submissions WHERE token_hash = _hash;

  IF _row.id IS NULL THEN RAISE EXCEPTION 'invalid_token'; END IF;
  IF _row.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'link_revoked'; END IF;
  IF _row.expires_at IS NOT NULL AND _row.expires_at < now() THEN RAISE EXCEPTION 'expired_token'; END IF;
  IF _row.status = 'applied' THEN RAISE EXCEPTION 'already_applied'; END IF;
  IF _row.status NOT IN ('draft','submitted') THEN RAISE EXCEPTION 'expired_token'; END IF;

  SELECT * INTO _org FROM public.organizations WHERE id = _row.organization_id;
  IF _org.id IS NULL THEN RAISE EXCEPTION 'org_not_found'; END IF;
  IF _org.onboarding_completed_at IS NOT NULL OR _org.onboarding_locked THEN
    RAISE EXCEPTION 'already_applied';
  END IF;

  -- Lock no primeiro acesso
  IF _row.first_seen_at IS NULL THEN
    _new_session := encode(extensions.gen_random_bytes(24), 'hex');
    UPDATE public.onboarding_submissions
       SET first_seen_at = now(),
           first_seen_ip = _ip,
           first_seen_ua = _ua,
           session_token = _new_session,
           access_count = access_count + 1
     WHERE id = _row.id;
    _row.session_token := _new_session;
  ELSE
    -- Acessos subsequentes precisam do session_token correto
    IF _session_token IS NULL OR _session_token <> _row.session_token THEN
      RAISE EXCEPTION 'link_already_in_use';
    END IF;
    UPDATE public.onboarding_submissions
       SET access_count = access_count + 1
     WHERE id = _row.id;
  END IF;

  RETURN QUERY SELECT _row.id, _row.organization_id, _row.payload, _row.status, _row.session_token;
END $$;

GRANT EXECUTE ON FUNCTION public.validate_onboarding_token(text, text, text, text) TO anon, authenticated;

-- ============================================================
-- 6. save_onboarding_draft_public (token + session_token)
-- ============================================================
CREATE OR REPLACE FUNCTION public.save_onboarding_draft_public(
  _token text,
  _session_token text,
  _payload jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = 'public', 'extensions'
AS $$
DECLARE
  _hash text;
  _row public.onboarding_submissions%ROWTYPE;
  _org public.organizations%ROWTYPE;
BEGIN
  IF _token IS NULL OR _session_token IS NULL THEN RAISE EXCEPTION 'invalid_token'; END IF;
  _hash := encode(extensions.digest(_token, 'sha256'), 'hex');
  SELECT * INTO _row FROM public.onboarding_submissions WHERE token_hash = _hash;
  IF _row.id IS NULL THEN RAISE EXCEPTION 'invalid_token'; END IF;
  IF _row.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'link_revoked'; END IF;
  IF _row.expires_at IS NOT NULL AND _row.expires_at < now() THEN RAISE EXCEPTION 'expired_token'; END IF;
  IF _row.status NOT IN ('draft') THEN RAISE EXCEPTION 'locked'; END IF;
  IF _row.session_token IS NULL OR _row.session_token <> _session_token THEN
    RAISE EXCEPTION 'link_already_in_use';
  END IF;

  SELECT * INTO _org FROM public.organizations WHERE id = _row.organization_id;
  IF _org.onboarding_completed_at IS NOT NULL OR _org.onboarding_locked THEN
    RAISE EXCEPTION 'already_applied';
  END IF;

  UPDATE public.onboarding_submissions
     SET payload = _payload, status = 'draft'
   WHERE id = _row.id;
END $$;

GRANT EXECUTE ON FUNCTION public.save_onboarding_draft_public(text, text, jsonb) TO anon, authenticated;

-- ============================================================
-- 7. submit_onboarding_public (token + session_token)
-- ============================================================
CREATE OR REPLACE FUNCTION public.submit_onboarding_public(
  _token text,
  _session_token text,
  _ip text DEFAULT NULL,
  _ua text DEFAULT NULL
) RETURNS TABLE(submission_id uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = 'public', 'extensions'
AS $$
DECLARE
  _hash text;
  _row public.onboarding_submissions%ROWTYPE;
  _org public.organizations%ROWTYPE;
BEGIN
  IF _token IS NULL OR _session_token IS NULL THEN RAISE EXCEPTION 'invalid_token'; END IF;
  _hash := encode(extensions.digest(_token, 'sha256'), 'hex');
  SELECT * INTO _row FROM public.onboarding_submissions WHERE token_hash = _hash;
  IF _row.id IS NULL THEN RAISE EXCEPTION 'invalid_token'; END IF;
  IF _row.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'link_revoked'; END IF;
  IF _row.expires_at IS NOT NULL AND _row.expires_at < now() THEN RAISE EXCEPTION 'expired_token'; END IF;
  IF _row.status NOT IN ('draft') THEN RAISE EXCEPTION 'locked'; END IF;
  IF _row.session_token IS NULL OR _row.session_token <> _session_token THEN
    RAISE EXCEPTION 'link_already_in_use';
  END IF;

  SELECT * INTO _org FROM public.organizations WHERE id = _row.organization_id;
  IF _org.onboarding_completed_at IS NOT NULL OR _org.onboarding_locked THEN
    RAISE EXCEPTION 'already_applied';
  END IF;

  UPDATE public.onboarding_submissions
     SET status = 'submitted',
         submitted_at = now(),
         submitted_ip = _ip,
         user_agent = _ua,
         consumed_at = COALESCE(consumed_at, now())
   WHERE id = _row.id;

  RETURN QUERY SELECT _row.id;
END $$;

GRANT EXECUTE ON FUNCTION public.submit_onboarding_public(text, text, text, text) TO anon, authenticated;
