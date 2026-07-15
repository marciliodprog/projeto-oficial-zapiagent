
-- =====================================================================
-- 1) TABELA user_organizations
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.user_organizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  role public.app_role NOT NULL DEFAULT 'admin',
  is_default boolean NOT NULL DEFAULT false,
  joined_via text NOT NULL DEFAULT 'invite',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, organization_id)
);
CREATE INDEX IF NOT EXISTS user_organizations_user_idx ON public.user_organizations(user_id);
CREATE INDEX IF NOT EXISTS user_organizations_org_idx ON public.user_organizations(organization_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_organizations TO authenticated;
GRANT ALL ON public.user_organizations TO service_role;

ALTER TABLE public.user_organizations ENABLE ROW LEVEL SECURITY;

-- usuário vê seus próprios vínculos
CREATE POLICY "User reads own memberships"
ON public.user_organizations FOR SELECT TO authenticated
USING (user_id = auth.uid());

-- admin lê vínculos da sua org ativa
CREATE POLICY "Admin reads memberships of own org"
ON public.user_organizations FOR SELECT TO authenticated
USING (
  has_role(auth.uid(), 'admin'::app_role)
  AND organization_id = public.get_user_organization(auth.uid())
);

-- super_admin lê tudo
CREATE POLICY "Super admin reads all memberships"
ON public.user_organizations FOR SELECT TO authenticated
USING (has_role(auth.uid(), 'super_admin'::app_role));

-- admin insere vínculos na própria org
CREATE POLICY "Admin inserts memberships in own org"
ON public.user_organizations FOR INSERT TO authenticated
WITH CHECK (
  has_role(auth.uid(), 'admin'::app_role)
  AND organization_id = public.get_user_organization(auth.uid())
);

-- super_admin insere qualquer vínculo
CREATE POLICY "Super admin inserts memberships"
ON public.user_organizations FOR INSERT TO authenticated
WITH CHECK (has_role(auth.uid(), 'super_admin'::app_role));

-- admin remove vínculos da própria org (exceto super_admin do alvo)
CREATE POLICY "Admin removes memberships in own org"
ON public.user_organizations FOR DELETE TO authenticated
USING (
  has_role(auth.uid(), 'admin'::app_role)
  AND organization_id = public.get_user_organization(auth.uid())
  AND role <> 'super_admin'::app_role
);

CREATE POLICY "Super admin removes memberships"
ON public.user_organizations FOR DELETE TO authenticated
USING (has_role(auth.uid(), 'super_admin'::app_role));

-- admin atualiza role/default dentro da org
CREATE POLICY "Admin updates memberships in own org"
ON public.user_organizations FOR UPDATE TO authenticated
USING (
  has_role(auth.uid(), 'admin'::app_role)
  AND organization_id = public.get_user_organization(auth.uid())
)
WITH CHECK (
  organization_id = public.get_user_organization(auth.uid())
);

-- usuário pode trocar seu próprio is_default
CREATE POLICY "User updates own default"
ON public.user_organizations FOR UPDATE TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- =====================================================================
-- 2) LOG de troca
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.user_org_switch_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  from_org uuid,
  to_org uuid,
  switched_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT ON public.user_org_switch_log TO authenticated;
GRANT ALL ON public.user_org_switch_log TO service_role;
ALTER TABLE public.user_org_switch_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Owner reads own switches"
ON public.user_org_switch_log FOR SELECT TO authenticated
USING (user_id = auth.uid() OR has_role(auth.uid(), 'super_admin'::app_role));

-- =====================================================================
-- 3) auto_join em organizations
-- =====================================================================
ALTER TABLE public.organizations
  ADD COLUMN IF NOT EXISTS auto_join_email_domains text[] NOT NULL DEFAULT '{}'::text[];

-- =====================================================================
-- 4) BACKFILL — todo profile com organization_id vira membership padrão
-- =====================================================================
INSERT INTO public.user_organizations (user_id, organization_id, role, is_default, joined_via)
SELECT
  p.id,
  p.organization_id,
  COALESCE(
    (SELECT ur.role FROM public.user_roles ur
       WHERE ur.user_id = p.id AND ur.role <> 'super_admin'::app_role
       ORDER BY (ur.role = 'admin'::app_role) DESC LIMIT 1),
    'seller'::app_role
  ),
  true,
  'legacy_backfill'
FROM public.profiles p
WHERE p.organization_id IS NOT NULL
ON CONFLICT (user_id, organization_id) DO NOTHING;

-- =====================================================================
-- 5) Trigger: garantir único is_default por usuário
-- =====================================================================
CREATE OR REPLACE FUNCTION public.enforce_unique_default_membership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.is_default THEN
    UPDATE public.user_organizations
      SET is_default = false
      WHERE user_id = NEW.user_id
        AND id <> NEW.id
        AND is_default = true;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_unique_default_membership ON public.user_organizations;
CREATE TRIGGER trg_unique_default_membership
AFTER INSERT OR UPDATE OF is_default ON public.user_organizations
FOR EACH ROW WHEN (NEW.is_default = true)
EXECUTE FUNCTION public.enforce_unique_default_membership();

-- =====================================================================
-- 6) RPC switch_active_organization
-- =====================================================================
CREATE OR REPLACE FUNCTION public.switch_active_organization(target_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_role public.app_role;
  v_current_org uuid;
  v_is_super boolean;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  SELECT organization_id INTO v_current_org FROM public.profiles WHERE id = v_user;
  v_is_super := has_role(v_user, 'super_admin'::app_role);

  -- valida membership ou super_admin
  SELECT role INTO v_role
    FROM public.user_organizations
   WHERE user_id = v_user AND organization_id = target_org_id;

  IF v_role IS NULL THEN
    IF v_is_super THEN
      v_role := 'admin'::app_role;
    ELSE
      RAISE EXCEPTION 'not_a_member';
    END IF;
  END IF;

  -- troca organization_id no profile
  UPDATE public.profiles
     SET organization_id = target_org_id,
         updated_at = now(),
         -- limpa conexão padrão se não pertencer à nova org
         default_connection_id = CASE
           WHEN default_connection_id IS NULL THEN NULL
           WHEN EXISTS (
             SELECT 1 FROM public.evolution_instances ei
              WHERE ei.id = profiles.default_connection_id
                AND ei.organization_id = target_org_id
           ) THEN default_connection_id
           ELSE NULL
         END
   WHERE id = v_user;

  -- atualiza is_default
  UPDATE public.user_organizations
     SET is_default = (organization_id = target_org_id)
   WHERE user_id = v_user;

  -- sincroniza user_roles com role da org (preservando super_admin)
  DELETE FROM public.user_roles
   WHERE user_id = v_user AND role <> 'super_admin'::app_role;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_user, v_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  -- garante user_permissions default para a nova org
  INSERT INTO public.user_permissions (user_id, organization_id)
  VALUES (v_user, target_org_id)
  ON CONFLICT (user_id) DO UPDATE SET organization_id = EXCLUDED.organization_id;

  -- log
  INSERT INTO public.user_org_switch_log (user_id, from_org, to_org)
  VALUES (v_user, v_current_org, target_org_id);

  RETURN jsonb_build_object(
    'ok', true,
    'organization_id', target_org_id,
    'role', v_role
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.switch_active_organization(uuid) TO authenticated;

-- =====================================================================
-- 7) RPC link_user_to_organization (admin)
-- =====================================================================
CREATE OR REPLACE FUNCTION public.link_user_to_organization(
  p_email text,
  p_organization_id uuid,
  p_role public.app_role DEFAULT 'admin'::app_role
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_target uuid;
  v_confirmed timestamptz;
  v_existing_membership uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  -- caller deve ser admin/super_admin da org alvo
  IF NOT (
    has_role(v_caller, 'super_admin'::app_role)
    OR (
      has_role(v_caller, 'admin'::app_role)
      AND public.get_user_organization(v_caller) = p_organization_id
    )
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT id, email_confirmed_at INTO v_target, v_confirmed
    FROM auth.users WHERE lower(email) = lower(p_email) LIMIT 1;

  IF v_target IS NULL THEN
    RETURN jsonb_build_object('status', 'no_user');
  END IF;

  IF v_confirmed IS NULL THEN
    RETURN jsonb_build_object('status', 'email_unconfirmed', 'user_id', v_target);
  END IF;

  SELECT id INTO v_existing_membership
    FROM public.user_organizations
   WHERE user_id = v_target AND organization_id = p_organization_id;

  IF v_existing_membership IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'already_member', 'user_id', v_target);
  END IF;

  INSERT INTO public.user_organizations (user_id, organization_id, role, joined_via)
  VALUES (v_target, p_organization_id, p_role, 'super_admin');

  -- garante linha em user_permissions
  INSERT INTO public.user_permissions (user_id, organization_id)
  VALUES (v_target, p_organization_id)
  ON CONFLICT (user_id) DO NOTHING;

  RETURN jsonb_build_object('status', 'linked', 'user_id', v_target);
END;
$$;

GRANT EXECUTE ON FUNCTION public.link_user_to_organization(text, uuid, public.app_role) TO authenticated;

-- =====================================================================
-- 8) Trigger auto-join por domínio
-- =====================================================================
CREATE OR REPLACE FUNCTION public.auto_join_orgs_for_email()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_domain text;
  v_org RECORD;
  v_has_active boolean;
BEGIN
  IF NEW.email IS NULL OR NEW.email_confirmed_at IS NULL THEN
    RETURN NEW;
  END IF;

  v_domain := lower(split_part(NEW.email, '@', 2));
  IF v_domain = '' THEN RETURN NEW; END IF;

  SELECT (organization_id IS NOT NULL) INTO v_has_active
    FROM public.profiles WHERE id = NEW.id;

  FOR v_org IN
    SELECT id FROM public.organizations
     WHERE auto_join_email_domains @> ARRAY[v_domain]
  LOOP
    INSERT INTO public.user_organizations (user_id, organization_id, role, joined_via, is_default)
    VALUES (NEW.id, v_org.id, 'admin'::app_role, 'domain_auto', NOT COALESCE(v_has_active, false))
    ON CONFLICT (user_id, organization_id) DO NOTHING;

    -- se ainda não tem org ativa, adota a primeira
    IF NOT COALESCE(v_has_active, false) THEN
      UPDATE public.profiles SET organization_id = v_org.id WHERE id = NEW.id;
      INSERT INTO public.user_roles (user_id, role)
        VALUES (NEW.id, 'admin'::app_role)
        ON CONFLICT (user_id, role) DO NOTHING;
      INSERT INTO public.user_permissions (user_id, organization_id)
        VALUES (NEW.id, v_org.id) ON CONFLICT (user_id) DO NOTHING;
      v_has_active := true;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_confirmed_autojoin_ins ON auth.users;
CREATE TRIGGER on_auth_user_confirmed_autojoin_ins
AFTER INSERT ON auth.users
FOR EACH ROW
WHEN (NEW.email_confirmed_at IS NOT NULL)
EXECUTE FUNCTION public.auto_join_orgs_for_email();

DROP TRIGGER IF EXISTS on_auth_user_confirmed_autojoin_upd ON auth.users;
CREATE TRIGGER on_auth_user_confirmed_autojoin_upd
AFTER UPDATE OF email_confirmed_at ON auth.users
FOR EACH ROW
WHEN (OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL)
EXECUTE FUNCTION public.auto_join_orgs_for_email();

-- =====================================================================
-- 9) RPC list_my_organizations — usado pelo switcher
-- =====================================================================
CREATE OR REPLACE FUNCTION public.list_my_organizations()
RETURNS TABLE (
  organization_id uuid,
  name text,
  logo_url text,
  role public.app_role,
  is_default boolean,
  is_active boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    o.id,
    o.name,
    o.logo_url,
    uo.role,
    uo.is_default,
    (o.id = (SELECT organization_id FROM public.profiles WHERE id = auth.uid())) AS is_active
  FROM public.user_organizations uo
  JOIN public.organizations o ON o.id = uo.organization_id
  WHERE uo.user_id = auth.uid()
  ORDER BY is_active DESC, uo.is_default DESC, o.name ASC;
$$;

GRANT EXECUTE ON FUNCTION public.list_my_organizations() TO authenticated;
