CREATE OR REPLACE FUNCTION public.deactivate_organization(_org_id uuid, _reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
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
    SET status = 'inactive', updated_at = now()
    WHERE organization_id = _org_id AND status <> 'inactive';

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
$function$;