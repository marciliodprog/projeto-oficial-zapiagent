
-- ============================================================
-- Onboarding de Implantação Vendus
-- Tabela de submissões + tokens + colunas extras
-- ============================================================

-- 1. Colunas novas em organizations
ALTER TABLE public.organizations
  ADD COLUMN IF NOT EXISTS instagram text,
  ADD COLUMN IF NOT EXISTS website text,
  ADD COLUMN IF NOT EXISTS onboarding_completed_at timestamptz;

-- 2. Colunas novas em products
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS category text,
  ADD COLUMN IF NOT EXISTS short_description text,
  ADD COLUMN IF NOT EXISTS custom_info text;

-- 3. Tabela onboarding_submissions
CREATE TABLE IF NOT EXISTS public.onboarding_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  token_hash text UNIQUE,
  mode text NOT NULL CHECK (mode IN ('link','first_access')),
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','submitted','applied','expired')),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  submitted_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  applied_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  submitted_ip text,
  user_agent text,
  applied_refs jsonb NOT NULL DEFAULT '{}'::jsonb,
  error_message text,
  expires_at timestamptz,
  consumed_at timestamptz,
  submitted_at timestamptz,
  applied_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_onboarding_submissions_org ON public.onboarding_submissions(organization_id);
CREATE INDEX IF NOT EXISTS idx_onboarding_submissions_status ON public.onboarding_submissions(status);

GRANT SELECT, INSERT, UPDATE ON public.onboarding_submissions TO authenticated;
GRANT ALL ON public.onboarding_submissions TO service_role;

ALTER TABLE public.onboarding_submissions ENABLE ROW LEVEL SECURITY;

-- Apenas super admins têm acesso direto; demais operam via RPCs SECURITY DEFINER.
CREATE POLICY "super_admin_all_onboarding"
  ON public.onboarding_submissions FOR ALL
  TO authenticated
  USING (public.has_role(auth.uid(), 'super_admin'))
  WITH CHECK (public.has_role(auth.uid(), 'super_admin'));

-- Admin da org pode ler suas próprias submissions (para o wizard interno)
CREATE POLICY "org_admin_select_own_onboarding"
  ON public.onboarding_submissions FOR SELECT
  TO authenticated
  USING (
    organization_id = (SELECT organization_id FROM public.profiles WHERE id = auth.uid())
    AND public.has_role(auth.uid(), 'admin')
  );

-- Trigger de updated_at
CREATE OR REPLACE FUNCTION public.touch_onboarding_submissions()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_touch_onboarding_submissions ON public.onboarding_submissions;
CREATE TRIGGER trg_touch_onboarding_submissions
  BEFORE UPDATE ON public.onboarding_submissions
  FOR EACH ROW EXECUTE FUNCTION public.touch_onboarding_submissions();

-- ============================================================
-- RPCs SECURITY DEFINER
-- ============================================================

-- Gera link de onboarding (Super Admin only). Retorna token em claro UMA vez.
CREATE OR REPLACE FUNCTION public.create_onboarding_link(
  _organization_id uuid,
  _ttl_days integer DEFAULT 7
) RETURNS TABLE(submission_id uuid, token text, expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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

  _token := encode(gen_random_bytes(32), 'base64');
  _token := replace(replace(replace(_token, '+', '-'), '/', '_'), '=', '');
  _hash  := encode(digest(_token, 'sha256'), 'hex');
  _exp   := now() + (_ttl_days || ' days')::interval;

  INSERT INTO public.onboarding_submissions(
    organization_id, token_hash, mode, status, expires_at, created_by
  ) VALUES (
    _organization_id, _hash, 'link', 'draft', _exp, auth.uid()
  ) RETURNING id INTO _sid;

  RETURN QUERY SELECT _sid, _token, _exp;
END $$;

GRANT EXECUTE ON FUNCTION public.create_onboarding_link(uuid, integer) TO authenticated;

-- Valida token (chamado pela edge / wizard público). Exige user logado.
CREATE OR REPLACE FUNCTION public.validate_onboarding_token(_token text)
RETURNS TABLE(submission_id uuid, organization_id uuid, payload jsonb, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _hash text;
  _row public.onboarding_submissions%ROWTYPE;
  _user_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required';
  END IF;
  IF _token IS NULL OR length(_token) < 20 THEN
    RAISE EXCEPTION 'invalid_token';
  END IF;

  _hash := encode(digest(_token, 'sha256'), 'hex');
  SELECT * INTO _row FROM public.onboarding_submissions WHERE token_hash = _hash;

  IF _row.id IS NULL THEN
    RAISE EXCEPTION 'invalid_token';
  END IF;
  IF _row.expires_at < now() OR _row.consumed_at IS NOT NULL OR _row.status = 'applied' THEN
    RAISE EXCEPTION 'expired_token';
  END IF;

  SELECT p.organization_id INTO _user_org FROM public.profiles p WHERE p.id = auth.uid();
  IF _user_org IS NULL OR _user_org <> _row.organization_id THEN
    RAISE EXCEPTION 'org_mismatch';
  END IF;

  RETURN QUERY SELECT _row.id, _row.organization_id, _row.payload, _row.status;
END $$;

GRANT EXECUTE ON FUNCTION public.validate_onboarding_token(text) TO authenticated;

-- Salva rascunho (autosave). Usado pelos 2 modos.
CREATE OR REPLACE FUNCTION public.save_onboarding_draft(
  _submission_id uuid,
  _payload jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _row public.onboarding_submissions%ROWTYPE;
  _user_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'auth_required'; END IF;
  SELECT * INTO _row FROM public.onboarding_submissions WHERE id = _submission_id;
  IF _row.id IS NULL THEN RAISE EXCEPTION 'not_found'; END IF;

  SELECT p.organization_id INTO _user_org FROM public.profiles p WHERE p.id = auth.uid();
  IF _user_org IS NULL OR _user_org <> _row.organization_id THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF NOT public.has_role(auth.uid(), 'admin') AND NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF _row.status NOT IN ('draft','submitted') THEN
    RAISE EXCEPTION 'locked';
  END IF;

  UPDATE public.onboarding_submissions
     SET payload = _payload, status = 'draft'
   WHERE id = _submission_id;
END $$;

GRANT EXECUTE ON FUNCTION public.save_onboarding_draft(uuid, jsonb) TO authenticated;

-- Cria/recupera submission do modo "first_access" para o admin logado.
CREATE OR REPLACE FUNCTION public.get_or_create_first_access_onboarding()
RETURNS TABLE(submission_id uuid, organization_id uuid, payload jsonb, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _org uuid;
  _row public.onboarding_submissions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'auth_required'; END IF;
  IF NOT public.has_role(auth.uid(), 'admin') AND NOT public.has_role(auth.uid(), 'super_admin') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT p.organization_id INTO _org FROM public.profiles p WHERE p.id = auth.uid();
  IF _org IS NULL THEN RAISE EXCEPTION 'no_org'; END IF;

  SELECT * INTO _row FROM public.onboarding_submissions
   WHERE organization_id = _org AND status IN ('draft','submitted')
   ORDER BY created_at DESC LIMIT 1;

  IF _row.id IS NULL THEN
    INSERT INTO public.onboarding_submissions(organization_id, mode, status, created_by)
    VALUES (_org, 'first_access', 'draft', auth.uid())
    RETURNING * INTO _row;
  END IF;

  RETURN QUERY SELECT _row.id, _row.organization_id, _row.payload, _row.status;
END $$;

GRANT EXECUTE ON FUNCTION public.get_or_create_first_access_onboarding() TO authenticated;

-- Marca como submitted (a edge apply-onboarding faz o resto).
CREATE OR REPLACE FUNCTION public.submit_onboarding(
  _submission_id uuid,
  _ip text DEFAULT NULL,
  _ua text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _row public.onboarding_submissions%ROWTYPE;
  _user_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'auth_required'; END IF;
  SELECT * INTO _row FROM public.onboarding_submissions WHERE id = _submission_id;
  IF _row.id IS NULL THEN RAISE EXCEPTION 'not_found'; END IF;
  SELECT p.organization_id INTO _user_org FROM public.profiles p WHERE p.id = auth.uid();
  IF _user_org <> _row.organization_id THEN RAISE EXCEPTION 'forbidden'; END IF;

  UPDATE public.onboarding_submissions
     SET status = 'submitted',
         submitted_by = auth.uid(),
         submitted_at = now(),
         submitted_ip = _ip,
         user_agent = _ua,
         consumed_at = COALESCE(consumed_at, now())
   WHERE id = _submission_id;
END $$;

GRANT EXECUTE ON FUNCTION public.submit_onboarding(uuid, text, text) TO authenticated;
