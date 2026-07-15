-- 1) Nova permissão
ALTER TABLE public.user_permissions
  ADD COLUMN IF NOT EXISTS view_ai_agents_tab boolean NOT NULL DEFAULT false;

-- 2) Atualiza inbox_count_conversations: separa human/agents/waiting
-- (mantém assinatura — usada pelo client com mesmo set de parâmetros)
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
  p_search text DEFAULT NULL::text
)
RETURNS TABLE(attending bigint, agents bigint, waiting bigint, resolved bigint)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org_id uuid;
  v_is_super boolean;
  v_is_admin boolean;
  v_view_other_users boolean := false;
  v_view_other_queues boolean := false;
  v_view_unassigned boolean := false;
  v_sectors uuid[];
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;

  SELECT pr.organization_id INTO v_org_id FROM public.profiles pr WHERE pr.id = p_user_id;

  SELECT EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = p_user_id AND ur.role = 'super_admin'::app_role) INTO v_is_super;
  SELECT EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = p_user_id AND ur.role = 'admin'::app_role) INTO v_is_admin;

  IF NOT v_is_super AND NOT v_is_admin THEN
    SELECT COALESCE(up.view_other_users_conversations,false),
           COALESCE(up.view_other_queues_conversations,false),
           COALESCE(up.view_unassigned_conversations,false)
      INTO v_view_other_users, v_view_other_queues, v_view_unassigned
    FROM public.user_permissions up WHERE up.user_id = p_user_id LIMIT 1;

    SELECT COALESCE(array_agg(sm.sector_id), ARRAY[]::uuid[]) INTO v_sectors
    FROM public.sector_members sm WHERE sm.user_id = p_user_id;
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT c.*
    FROM public.webchat_conversations c
    WHERE c.organization_id = v_org_id
      AND (
        v_is_super OR v_is_admin
        OR c.assigned_user_id = p_user_id
        OR (v_view_other_queues)
        OR (v_view_other_users AND c.sector_id = ANY(v_sectors))
        OR (v_view_unassigned AND c.assigned_user_id IS NULL AND c.sector_id = ANY(v_sectors))
      )
      AND (p_product_ids IS NULL OR c.product_id = ANY(p_product_ids) OR (p_include_no_product AND c.product_id IS NULL))
      AND (p_sector_ids IS NULL OR c.sector_id = ANY(p_sector_ids) OR (p_include_no_sector AND c.sector_id IS NULL))
      AND (p_assigned_user_ids IS NULL OR c.assigned_user_id = ANY(p_assigned_user_ids) OR (p_include_unassigned AND c.assigned_user_id IS NULL))
      AND (p_channel IS NULL OR c.channel = p_channel)
      AND (
        p_search IS NULL OR p_search = ''
        OR c.visitor_name ILIKE '%'||p_search||'%'
        OR c.visitor_phone ILIKE '%'||p_search||'%'
        OR c.visitor_email ILIKE '%'||p_search||'%'
      )
      AND (
        p_tag_ids IS NULL OR EXISTS (
          SELECT 1 FROM public.lead_tag_assignments lta
          WHERE lta.lead_id = c.lead_id AND lta.tag_id = ANY(p_tag_ids)
        )
      )
  )
  SELECT
    COUNT(*) FILTER (WHERE status = 'human_active')::bigint AS attending,
    COUNT(*) FILTER (WHERE status = 'bot_active' OR (status = 'waiting_human' AND current_agent_id IS NOT NULL))::bigint AS agents,
    COUNT(*) FILTER (WHERE status = 'waiting_human' AND current_agent_id IS NULL)::bigint AS waiting,
    COUNT(*) FILTER (WHERE status = 'closed')::bigint AS resolved
  FROM base;
END;
$$;

-- 3) Atualiza inbox_list_conversations: novo p_tab='agents' + redefine attending/waiting
CREATE OR REPLACE FUNCTION public.inbox_list_conversations(
  p_user_id uuid,
  p_tab text DEFAULT 'attending'::text,
  p_product_ids uuid[] DEFAULT NULL::uuid[],
  p_include_no_product boolean DEFAULT false,
  p_sector_ids uuid[] DEFAULT NULL::uuid[],
  p_include_no_sector boolean DEFAULT false,
  p_assigned_user_ids uuid[] DEFAULT NULL::uuid[],
  p_include_unassigned boolean DEFAULT false,
  p_tag_ids uuid[] DEFAULT NULL::uuid[],
  p_channel text DEFAULT NULL::text,
  p_search text DEFAULT NULL::text,
  p_cursor_last_message_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_limit integer DEFAULT 50
)
RETURNS SETOF public.webchat_conversations
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org_id uuid;
  v_is_super boolean;
  v_is_admin boolean;
  v_view_other_users boolean := false;
  v_view_other_queues boolean := false;
  v_view_unassigned boolean := false;
  v_sectors uuid[];
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;

  SELECT pr.organization_id INTO v_org_id
  FROM public.profiles pr WHERE pr.id = p_user_id;

  SELECT EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = p_user_id AND ur.role = 'super_admin'::app_role) INTO v_is_super;
  SELECT EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = p_user_id AND ur.role = 'admin'::app_role) INTO v_is_admin;

  IF NOT v_is_super AND NOT v_is_admin THEN
    SELECT COALESCE(up.view_other_users_conversations,false),
           COALESCE(up.view_other_queues_conversations,false),
           COALESCE(up.view_unassigned_conversations,false)
      INTO v_view_other_users, v_view_other_queues, v_view_unassigned
    FROM public.user_permissions up
    WHERE up.user_id = p_user_id LIMIT 1;

    SELECT COALESCE(array_agg(sm.sector_id), ARRAY[]::uuid[]) INTO v_sectors
    FROM public.sector_members sm WHERE sm.user_id = p_user_id;
  END IF;

  RETURN QUERY
  SELECT c.*
  FROM public.webchat_conversations c
  WHERE c.organization_id = v_org_id
    AND (
      p_tab = 'all'
      OR (p_tab = 'attending' AND c.status = 'human_active')
      OR (p_tab = 'agents'    AND (c.status = 'bot_active' OR (c.status = 'waiting_human' AND c.current_agent_id IS NOT NULL)))
      OR (p_tab = 'waiting'   AND c.status = 'waiting_human' AND c.current_agent_id IS NULL)
      OR (p_tab = 'resolved'  AND c.status = 'closed')
    )
    AND (
      v_is_super OR v_is_admin
      OR c.assigned_user_id = p_user_id
      OR (v_view_other_queues)
      OR (v_view_other_users AND c.sector_id = ANY(v_sectors))
      OR (v_view_unassigned AND c.assigned_user_id IS NULL AND c.sector_id = ANY(v_sectors))
    )
    AND (p_product_ids IS NULL OR c.product_id = ANY(p_product_ids) OR (p_include_no_product AND c.product_id IS NULL))
    AND (p_sector_ids IS NULL OR c.sector_id = ANY(p_sector_ids) OR (p_include_no_sector AND c.sector_id IS NULL))
    AND (p_assigned_user_ids IS NULL OR c.assigned_user_id = ANY(p_assigned_user_ids) OR (p_include_unassigned AND c.assigned_user_id IS NULL))
    AND (p_channel IS NULL OR c.channel = p_channel)
    AND (
      p_search IS NULL OR p_search = ''
      OR c.visitor_name ILIKE '%'||p_search||'%'
      OR c.visitor_phone ILIKE '%'||p_search||'%'
      OR c.visitor_email ILIKE '%'||p_search||'%'
    )
    AND (
      p_tag_ids IS NULL OR EXISTS (
        SELECT 1 FROM public.lead_tag_assignments lta
        WHERE lta.lead_id = c.lead_id AND lta.tag_id = ANY(p_tag_ids)
      )
    )
    AND (p_cursor_last_message_at IS NULL OR c.last_message_at < p_cursor_last_message_at)
  ORDER BY c.last_message_at DESC NULLS LAST
  LIMIT GREATEST(p_limit, 1);
END;
$$;