
-- 1) Remover triggers + função de auto-join por domínio
DROP TRIGGER IF EXISTS on_auth_user_confirmed_autojoin_ins ON auth.users;
DROP TRIGGER IF EXISTS on_auth_user_confirmed_autojoin_upd ON auth.users;
DROP FUNCTION IF EXISTS public.auto_join_orgs_for_email();

-- 2) accept_invitation: vincular em user_organizations preservando contexto ativo
CREATE OR REPLACE FUNCTION public.accept_invitation(invitation_token text, user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  inv RECORD;
  v_current_org uuid;
BEGIN
  SELECT * INTO inv FROM team_invitations
  WHERE token = invitation_token
    AND status = 'pending'
    AND expires_at > now();

  IF inv IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT organization_id INTO v_current_org FROM profiles WHERE id = user_id;

  -- Sempre garantir o vínculo N:N
  INSERT INTO public.user_organizations (user_id, organization_id, role, joined_via, is_default)
  VALUES (user_id, inv.organization_id, inv.role, 'invite', v_current_org IS NULL)
  ON CONFLICT (user_id, organization_id) DO UPDATE
    SET role = EXCLUDED.role;

  -- Só adota essa empresa como ativa se o usuário ainda não tem uma
  IF v_current_org IS NULL THEN
    UPDATE profiles SET organization_id = inv.organization_id WHERE id = user_id;
    INSERT INTO user_roles (user_id, role)
      VALUES (user_id, inv.role)
      ON CONFLICT DO NOTHING;
    PERFORM public.initialize_user_permissions(user_id, inv.organization_id, inv.role::text);
  END IF;

  -- Squad continua sendo aplicado para a empresa do convite
  IF inv.squad_id IS NOT NULL THEN
    INSERT INTO squad_members (squad_id, user_id, role)
    VALUES (inv.squad_id, user_id, 'member')
    ON CONFLICT DO NOTHING;
  END IF;

  UPDATE team_invitations SET status = 'accepted' WHERE id = inv.id;

  RETURN TRUE;
END;
$$;
