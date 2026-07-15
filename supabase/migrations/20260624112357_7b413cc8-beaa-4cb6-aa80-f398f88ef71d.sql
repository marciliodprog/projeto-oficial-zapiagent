
-- Suspender empresa: desativa conexões e marca status='suspended'
CREATE OR REPLACE FUNCTION public.deactivate_organization(_org_id uuid, _reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Permissão: super admin OU service_role (cron / edge functions)
  IF NOT (
    public.is_super_admin(auth.uid())
    OR current_setting('request.jwt.claim.role', true) = 'service_role'
    OR auth.uid() IS NULL
  ) THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  UPDATE public.organizations SET status = 'suspended', updated_at = now() WHERE id = _org_id;

  UPDATE public.evolution_instances
    SET status = 'disconnected', updated_at = now()
    WHERE organization_id = _org_id AND status <> 'disconnected';

  UPDATE public.whatsapp_meta_connections
    SET status = 'inactive', updated_at = now()
    WHERE organization_id = _org_id AND status <> 'inactive';

  UPDATE public.instagram_connections
    SET is_active = false, updated_at = now()
    WHERE organization_id = _org_id AND is_active = true;

  UPDATE public.product_agents
    SET is_active = false, updated_at = now()
    WHERE organization_id = _org_id AND is_active = true;

  INSERT INTO public.platform_audit_logs (actor_id, action, entity_type, entity_id, metadata)
  VALUES (
    auth.uid(),
    'Empresa suspensa',
    'organization',
    _org_id,
    jsonb_build_object('reason', COALESCE(_reason, 'manual'))
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.reactivate_organization(_org_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (
    public.is_super_admin(auth.uid())
    OR current_setting('request.jwt.claim.role', true) = 'service_role'
    OR auth.uid() IS NULL
  ) THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  UPDATE public.organizations SET status = 'active', updated_at = now() WHERE id = _org_id;

  INSERT INTO public.platform_audit_logs (actor_id, action, entity_type, entity_id, metadata)
  VALUES (auth.uid(), 'Empresa reativada', 'organization', _org_id, '{}'::jsonb);
END;
$$;

-- Cron: suspende empresas com plano vencido
CREATE OR REPLACE FUNCTION public.check_expired_subscriptions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN
    SELECT s.id, s.organization_id, s.current_period_end
    FROM public.subscriptions s
    JOIN public.organizations o ON o.id = s.organization_id
    WHERE s.status = 'active'
      AND s.current_period_end IS NOT NULL
      AND s.current_period_end < now()
      AND o.status = 'active'
  LOOP
    UPDATE public.subscriptions
      SET status = 'past_due', updated_at = now()
      WHERE id = rec.id;

    PERFORM public.deactivate_organization(
      rec.organization_id,
      'Plano vencido em ' || to_char(rec.current_period_end, 'YYYY-MM-DD')
    );
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.deactivate_organization(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reactivate_organization(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.check_expired_subscriptions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.deactivate_organization(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reactivate_organization(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.check_expired_subscriptions() TO service_role;

-- Agendar cron diário 03:00 UTC
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('check-expired-subscriptions') WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'check-expired-subscriptions'
    );
    PERFORM cron.schedule(
      'check-expired-subscriptions',
      '0 3 * * *',
      $cron$ SELECT public.check_expired_subscriptions(); $cron$
    );
  END IF;
END;
$$;
