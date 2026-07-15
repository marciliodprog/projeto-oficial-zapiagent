
-- 1) Trigger: protege humano dono da conversa
CREATE OR REPLACE FUNCTION public.enforce_single_attendant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Humano definido (ou trocado) → IA sai
  IF NEW.assigned_user_id IS NOT NULL
     AND NEW.assigned_user_id IS DISTINCT FROM OLD.assigned_user_id THEN
    NEW.current_agent_id := NULL;
    RETURN NEW;
  END IF;

  -- Tentativa de colocar/trocar IA
  IF NEW.current_agent_id IS NOT NULL
     AND NEW.current_agent_id IS DISTINCT FROM OLD.current_agent_id THEN
    -- Se já existe humano dono e a operação NÃO está explicitamente liberando o humano,
    -- bloqueia silenciosamente a entrada da IA (mantém o estado anterior do agent).
    IF OLD.assigned_user_id IS NOT NULL
       AND NEW.assigned_user_id IS NOT DISTINCT FROM OLD.assigned_user_id THEN
      NEW.current_agent_id := OLD.current_agent_id;
      RETURN NEW;
    END IF;
    -- Caso contrário (sem humano, ou humano sendo liberado/trocado nesta mesma operação),
    -- comportamento original: IA entra, humano sai.
    NEW.assigned_user_id := NULL;
  END IF;

  RETURN NEW;
END;
$function$;

-- 2) RPC inbox_list_conversations: aba "attending" exige assigned_user_id
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
  p_limit integer DEFAULT 50,
  p_channels text[] DEFAULT NULL::text[],
  p_evolution_ids uuid[] DEFAULT NULL::uuid[],
  p_meta_ids uuid[] DEFAULT NULL::uuid[],
  p_instagram_ids uuid[] DEFAULT NULL::uuid[],
  p_agent_ids uuid[] DEFAULT NULL::uuid[]
)
RETURNS TABLE(id uuid, organization_id uuid, widget_id uuid, visitor_id text, lead_id uuid, product_id uuid, effective_product_id uuid, effective_product_name text, assigned_user_id uuid, assigned_user_name text, assigned_user_avatar text, current_agent_id uuid, current_agent_name text, current_agent_avatar text, sector_id uuid, sector_name text, sector_color text, evolution_instance_id uuid, meta_connection_id uuid, instagram_connection_id uuid, status text, channel text, needs_human boolean, last_message_at timestamp with time zone, unread_count_agents integer, created_at timestamp with time zone, updated_at timestamp with time zone, closed_at timestamp with time zone, visitor_name text, visitor_email text, visitor_phone text, visitor_avatar_url text, visitor_whatsapp text, accepted_at timestamp with time zone, accepted_by uuid, widget_name text, widget_primary_color text, widget_product_id uuid, lead_name text, lead_email text, lead_phone text, lead_product_id uuid, last_message_content text, last_message_metadata jsonb, last_message_sender_type text, last_message_created_at timestamp with time zone)
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

  SELECT pr.organization_id INTO v_org_id
    FROM public.profiles pr WHERE pr.id = p_user_id;

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
    FROM public.user_permissions up
    WHERE up.user_id = p_user_id
    LIMIT 1;

    SELECT COALESCE(array_agg(sm.sector_id), ARRAY[]::uuid[]) INTO v_user_sectors
    FROM public.sector_members sm WHERE sm.user_id = p_user_id;
  END IF;

  RETURN QUERY
  SELECT
    c.id, c.organization_id, c.widget_id, c.visitor_id::text, c.lead_id, c.product_id,
    COALESCE(c.product_id, l.product_id, w.product_id) AS effective_product_id,
    prd.name::text AS effective_product_name,
    c.assigned_user_id, pa.full_name::text AS assigned_user_name, pa.avatar_url::text AS assigned_user_avatar,
    c.current_agent_id, ag.name::text AS current_agent_name, ag.avatar_url::text AS current_agent_avatar,
    c.sector_id, sec.name::text AS sector_name, sec.color::text AS sector_color,
    c.evolution_instance_id,
    c.meta_connection_id,
    c.instagram_connection_id,
    c.status::text, c.channel::text, c.needs_human,
    c.last_message_at, c.unread_count_agents,
    c.created_at, c.updated_at, c.closed_at,
    c.visitor_name::text, c.visitor_email::text, c.visitor_phone::text,
    c.visitor_avatar_url::text, c.visitor_whatsapp::text,
    c.accepted_at, c.accepted_by,
    w.name::text AS widget_name, w.primary_color::text AS widget_primary_color, w.product_id AS widget_product_id,
    l.name::text AS lead_name, l.email::text AS lead_email, l.phone::text AS lead_phone, l.product_id AS lead_product_id,
    c.last_message_content::text, c.last_message_metadata, c.last_message_sender_type::text, c.last_message_created_at
  FROM public.webchat_conversations c
  LEFT JOIN public.leads l            ON l.id = c.lead_id
  LEFT JOIN public.webchat_widgets w  ON w.id = c.widget_id
  LEFT JOIN public.profiles pa        ON pa.id = c.assigned_user_id
  LEFT JOIN public.product_agents ag  ON ag.id = c.current_agent_id
  LEFT JOIN public.sectors sec        ON sec.id = c.sector_id
  LEFT JOIN public.products prd       ON prd.id = COALESCE(c.product_id, l.product_id, w.product_id)
  WHERE
    (v_org_id IS NULL OR c.organization_id = v_org_id)
    AND (
      p_tab = 'all'
      OR (p_tab = 'attending' AND c.status = 'human_active' AND c.assigned_user_id IS NOT NULL)
      OR (p_tab = 'agents'    AND (c.status = 'bot_active' OR (c.status = 'waiting_human' AND c.current_agent_id IS NOT NULL)))
      OR (p_tab = 'waiting'   AND (
            (c.status = 'waiting_human' AND c.current_agent_id IS NULL)
            OR (c.status = 'human_active' AND c.assigned_user_id IS NULL)
          ))
      OR (p_tab = 'resolved'  AND c.status = 'closed')
    )
    AND (p_channel IS NULL OR c.channel = p_channel)
    AND (p_channels IS NULL OR c.channel = ANY(p_channels))
    AND (
      (p_evolution_ids IS NULL AND p_meta_ids IS NULL AND p_instagram_ids IS NULL)
      OR (p_evolution_ids IS NOT NULL AND c.evolution_instance_id = ANY(p_evolution_ids))
      OR (p_meta_ids IS NOT NULL AND c.meta_connection_id = ANY(p_meta_ids))
      OR (p_instagram_ids IS NOT NULL AND c.instagram_connection_id = ANY(p_instagram_ids))
    )
    AND (p_agent_ids IS NULL OR c.current_agent_id = ANY(p_agent_ids))
    AND (p_cursor_last_message_at IS NULL OR c.last_message_at < p_cursor_last_message_at)
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
  ORDER BY c.last_message_at DESC NULLS LAST, c.id DESC
  LIMIT GREATEST(1, LEAST(p_limit, 200));
END;
$function$;

-- 3) Backfill: restaurar conversas órfãs (human_active + sem dono + com IA)
DO $$
DECLARE
  r record;
  v_prev_user uuid;
BEGIN
  FOR r IN
    SELECT id, accepted_by
    FROM public.webchat_conversations
    WHERE status = 'human_active'
      AND assigned_user_id IS NULL
      AND current_agent_id IS NOT NULL
  LOOP
    -- 1) último assignee histórico via webchat_assignment_events
    SELECT to_user_id INTO v_prev_user
    FROM public.webchat_assignment_events
    WHERE conversation_id = r.id AND to_user_id IS NOT NULL
    ORDER BY created_at DESC
    LIMIT 1;

    -- 2) fallback: accepted_by
    IF v_prev_user IS NULL THEN
      v_prev_user := r.accepted_by;
    END IF;

    IF v_prev_user IS NOT NULL THEN
      UPDATE public.webchat_conversations
      SET assigned_user_id = v_prev_user,
          current_agent_id = NULL
      WHERE id = r.id;
    ELSE
      -- sem histórico: devolve para a fila
      UPDATE public.webchat_conversations
      SET status = 'waiting_human',
          current_agent_id = NULL,
          assigned_user_id = NULL,
          needs_human = true
      WHERE id = r.id;
    END IF;

    v_prev_user := NULL;
  END LOOP;
END $$;
