CREATE OR REPLACE FUNCTION public.inbox_count_conversations(
  p_user_id uuid,
  p_product_ids uuid[] DEFAULT NULL::uuid[],
  p_include_no_product boolean DEFAULT false,
  p_sector_ids uuid[] DEFAULT NULL::uuid[],
  p_include_no_sector boolean DEFAULT false,
  p_assigned_user_ids uuid[] DEFAULT NULL::uuid[],
  p_include_unassigned boolean DEFAULT false,
  p_tag_ids uuid[] DEFAULT NULL::uuid[],
  p_channel text DEFAULT NULL::text,
  p_search text DEFAULT NULL::text,
  p_channels text[] DEFAULT NULL::text[],
  p_evolution_ids uuid[] DEFAULT NULL::uuid[],
  p_meta_ids uuid[] DEFAULT NULL::uuid[],
  p_instagram_ids uuid[] DEFAULT NULL::uuid[]
)
RETURNS TABLE(attending bigint, waiting bigint, resolved bigint)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_org_id uuid;
  v_is_super_admin boolean;
  v_is_admin boolean;
  v_perm_queue boolean := false;
  v_perm_other_users boolean := false;
  v_perm_other_queues boolean := false;
  v_perm_unassigned_sector boolean := false;
  v_user_sectors uuid[];
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_id is required';
  END IF;

  SELECT pr.organization_id INTO v_org_id FROM public.profiles pr WHERE pr.id = p_user_id;

  v_is_super_admin := EXISTS (
    SELECT 1 FROM public.user_roles ur WHERE ur.user_id = p_user_id AND ur.role = 'super_admin'::app_role
  );
  v_is_admin := v_is_super_admin OR EXISTS (
    SELECT 1 FROM public.user_roles ur WHERE ur.user_id = p_user_id AND ur.role = 'admin'::app_role
  );

  IF v_org_id IS NULL AND NOT v_is_super_admin THEN
    RAISE EXCEPTION 'User has no organization';
  END IF;

  IF NOT v_is_admin THEN
    SELECT
      COALESCE(up.view_queue_conversations, false),
      COALESCE(up.view_other_users_conversations, false),
      COALESCE(up.view_other_queues_conversations, false),
      COALESCE(up.view_unassigned_sector_tickets, false)
    INTO v_perm_queue, v_perm_other_users, v_perm_other_queues, v_perm_unassigned_sector
    FROM public.user_permissions up WHERE up.user_id = p_user_id LIMIT 1;

    SELECT COALESCE(array_agg(sm.sector_id), ARRAY[]::uuid[]) INTO v_user_sectors
    FROM public.sector_members sm WHERE sm.user_id = p_user_id;
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT c.status, c.id
    FROM public.webchat_conversations c
    LEFT JOIN public.leads l           ON l.id = c.lead_id
    LEFT JOIN public.webchat_widgets w ON w.id = c.widget_id
    WHERE
      (v_org_id IS NULL OR c.organization_id = v_org_id)
      AND (p_channel IS NULL OR c.channel = p_channel)
      AND (p_channels IS NULL OR c.channel = ANY(p_channels))
      AND (
        (p_evolution_ids IS NULL AND p_meta_ids IS NULL AND p_instagram_ids IS NULL)
        OR (p_evolution_ids IS NOT NULL AND c.evolution_instance_id = ANY(p_evolution_ids))
        OR (p_meta_ids IS NOT NULL AND c.meta_connection_id = ANY(p_meta_ids))
        OR (p_instagram_ids IS NOT NULL AND c.instagram_connection_id = ANY(p_instagram_ids))
      )
      AND (
        v_is_admin
        OR c.assigned_user_id = p_user_id
        OR (c.sector_id IS NULL AND v_perm_unassigned_sector)
        OR (c.sector_id = ANY(v_user_sectors) AND c.assigned_user_id IS NULL AND v_perm_queue)
        OR (c.sector_id = ANY(v_user_sectors) AND c.assigned_user_id IS NOT NULL AND v_perm_other_users)
        OR (c.sector_id IS NOT NULL AND NOT (c.sector_id = ANY(v_user_sectors)) AND v_perm_other_queues)
      )
      AND (
        (p_product_ids IS NULL AND NOT p_include_no_product)
        OR (p_include_no_product AND COALESCE(c.product_id, l.product_id, w.product_id) IS NULL)
        OR (p_product_ids IS NOT NULL AND COALESCE(c.product_id, l.product_id, w.product_id) = ANY(p_product_ids))
      )
      AND (
        (p_sector_ids IS NULL AND NOT p_include_no_sector)
        OR (p_include_no_sector AND c.sector_id IS NULL)
        OR (p_sector_ids IS NOT NULL AND c.sector_id = ANY(p_sector_ids))
      )
      AND (
        (p_assigned_user_ids IS NULL AND NOT p_include_unassigned)
        OR (p_include_unassigned AND c.assigned_user_id IS NULL)
        OR (p_assigned_user_ids IS NOT NULL AND c.assigned_user_id = ANY(p_assigned_user_ids))
      )
      AND (
        p_tag_ids IS NULL
        OR EXISTS (
          SELECT 1 FROM public.lead_tag_assignments lta
          WHERE lta.lead_id = c.lead_id AND lta.tag_id = ANY(p_tag_ids)
        )
      )
      AND (
        p_search IS NULL OR p_search = ''
        OR c.visitor_name  ILIKE '%' || p_search || '%'
        OR c.visitor_email ILIKE '%' || p_search || '%'
        OR c.visitor_phone ILIKE '%' || p_search || '%'
        OR l.name          ILIKE '%' || p_search || '%'
        OR l.email         ILIKE '%' || p_search || '%'
        OR l.phone         ILIKE '%' || p_search || '%'
      )
  )
  SELECT
    COUNT(*) FILTER (WHERE status = 'human_active')::bigint AS attending,
    COUNT(*) FILTER (WHERE status IN ('waiting_human','bot_active'))::bigint AS waiting,
    COUNT(*) FILTER (WHERE status = 'closed')::bigint AS resolved
  FROM base;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.inbox_count_conversations(uuid,uuid[],boolean,uuid[],boolean,uuid[],boolean,uuid[],text,text,text[],uuid[],uuid[],uuid[]) TO authenticated, service_role;