
CREATE OR REPLACE FUNCTION public.can_access_conversation(_user_id uuid, _conv_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_assigned uuid;
  v_sector uuid;
  v_org uuid;
  v_user_org uuid;
  v_q boolean := false;
  v_ou boolean := false;
  v_oq boolean := false;
  v_un boolean := false;
  v_in_sector boolean := false;
BEGIN
  IF _user_id IS NULL OR _conv_id IS NULL THEN RETURN false; END IF;

  SELECT assigned_user_id, sector_id, organization_id
    INTO v_assigned, v_sector, v_org
    FROM public.webchat_conversations WHERE id = _conv_id;
  IF v_org IS NULL THEN RETURN false; END IF;

  v_is_admin := EXISTS (
    SELECT 1 FROM public.user_roles ur
     WHERE ur.user_id = _user_id AND ur.role IN ('admin','super_admin')
  );
  IF v_is_admin THEN
    -- super_admin: ok; admin: limitar à sua org
    IF EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id=_user_id AND ur.role='super_admin') THEN
      RETURN true;
    END IF;
    SELECT organization_id INTO v_user_org FROM public.profiles WHERE id=_user_id;
    RETURN v_user_org = v_org;
  END IF;

  SELECT organization_id INTO v_user_org FROM public.profiles WHERE id=_user_id;
  IF v_user_org IS DISTINCT FROM v_org THEN RETURN false; END IF;

  IF v_assigned = _user_id THEN RETURN true; END IF;

  SELECT
    COALESCE(view_queue_conversations,false),
    COALESCE(view_other_users_conversations,false),
    COALESCE(view_other_queues_conversations,false),
    COALESCE(view_unassigned_sector_tickets,false)
  INTO v_q, v_ou, v_oq, v_un
  FROM public.user_permissions WHERE user_id=_user_id LIMIT 1;

  IF v_sector IS NULL THEN
    RETURN v_un;
  END IF;

  v_in_sector := EXISTS (
    SELECT 1 FROM public.sector_members sm
     WHERE sm.user_id=_user_id AND sm.sector_id=v_sector
  );

  IF v_in_sector THEN
    IF v_assigned IS NULL THEN RETURN v_q; END IF;
    RETURN v_ou;
  ELSE
    RETURN v_oq;
  END IF;
END;
$$;

DROP POLICY IF EXISTS "Users can view their org conversations" ON public.webchat_conversations;
DROP POLICY IF EXISTS "Users can update their org conversations" ON public.webchat_conversations;

CREATE POLICY "Users can view conversations per scope"
ON public.webchat_conversations
FOR SELECT
TO authenticated
USING (public.can_access_conversation(auth.uid(), id));

CREATE POLICY "Users can update conversations per scope"
ON public.webchat_conversations
FOR UPDATE
TO authenticated
USING (public.can_access_conversation(auth.uid(), id))
WITH CHECK (organization_id = public.get_user_organization(auth.uid()));
