
-- 1. New permission columns
ALTER TABLE public.user_permissions
  ADD COLUMN IF NOT EXISTS view_my_portfolio boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS view_squad_portfolio boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS view_all_portfolio boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS view_unassigned_portfolio boolean NOT NULL DEFAULT false;

-- 2. Backfill: admins/managers get full visibility
UPDATE public.user_permissions up
SET view_squad_portfolio = true,
    view_all_portfolio = true,
    view_unassigned_portfolio = true
WHERE EXISTS (
  SELECT 1 FROM public.user_roles ur
  WHERE ur.user_id = up.user_id
    AND ur.role IN ('admin','manager')
);

-- 3. Generic permission helper
CREATE OR REPLACE FUNCTION public.user_has_permission(_user_id uuid, _perm text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v boolean;
BEGIN
  EXECUTE format('SELECT COALESCE((SELECT %I FROM public.user_permissions WHERE user_id = $1), false)', _perm)
    INTO v USING _user_id;
  RETURN COALESCE(v, false);
END;
$$;

-- 4. Update initialize_user_permissions to seed the new columns
CREATE OR REPLACE FUNCTION public.initialize_user_permissions(p_user_id uuid, p_organization_id uuid, p_role text DEFAULT 'seller'::text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  INSERT INTO public.user_permissions (user_id, organization_id,
    view_queue_conversations, view_other_users_conversations, view_other_queues_conversations,
    allow_close_pending_tickets, view_all_contacts, allow_pipeline,
    allow_manage_client_portfolio, view_all_kanban_cards, view_all_schedules,
    allow_dashboard, allow_inbox_panel, allow_groups, allow_connection_actions,
    view_unassigned_sector_tickets, view_schedules_mode,
    view_my_portfolio, view_squad_portfolio, view_all_portfolio, view_unassigned_portfolio)
  VALUES (
    p_user_id, p_organization_id,
    true,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END,
    true,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END,
    CASE WHEN p_role = 'admin' THEN true ELSE false END,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END,
    CASE WHEN p_role IN ('admin','manager') THEN 'all' ELSE 'mine_only' END,
    -- portfolio scopes
    true,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END,
    CASE WHEN p_role IN ('admin','manager') THEN true ELSE false END
  )
  ON CONFLICT (user_id) DO NOTHING;

  INSERT INTO public.user_notification_settings (user_id, organization_id)
  VALUES (p_user_id, p_organization_id)
  ON CONFLICT (user_id) DO NOTHING;
END;
$function$;

-- 5. Rewrite SELECT policies on public.leads to honor portfolio scopes
DROP POLICY IF EXISTS "Users can view leads" ON public.leads;
DROP POLICY IF EXISTS "Squad members can view squad leads" ON public.leads;
DROP POLICY IF EXISTS "Users with view_all_kanban_cards can view all org leads" ON public.leads;

CREATE POLICY "Leads visibility by portfolio scope"
ON public.leads
FOR SELECT
TO authenticated
USING (
  organization_id = public.get_user_organization(auth.uid())
  AND (
    public.has_role(auth.uid(), 'admin'::app_role)
    OR public.has_role(auth.uid(), 'manager'::app_role)
    OR public.user_has_permission(auth.uid(), 'view_all_portfolio')
    OR public.user_has_permission(auth.uid(), 'view_all_kanban_cards')
    OR assigned_to = auth.uid()
    OR sdr_id     = auth.uid()
    OR closer_id  = auth.uid()
    OR (
      public.user_has_permission(auth.uid(), 'view_squad_portfolio')
      AND squad_id IS NOT NULL
      AND squad_id IN (SELECT sm.squad_id FROM public.squad_members sm WHERE sm.user_id = auth.uid())
    )
    OR (
      public.user_has_permission(auth.uid(), 'view_unassigned_portfolio')
      AND assigned_to IS NULL
    )
  )
);
