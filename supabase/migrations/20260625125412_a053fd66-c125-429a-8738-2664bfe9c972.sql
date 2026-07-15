
CREATE OR REPLACE FUNCTION public.get_campaign_stats_for_org(p_org uuid)
RETURNS TABLE(campaign_id uuid, status text, cnt bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT ct.campaign_id, ct.status::text, count(*)::bigint
  FROM public.campaign_targets ct
  JOIN public.campaigns c ON c.id = ct.campaign_id
  WHERE c.organization_id = p_org
  GROUP BY ct.campaign_id, ct.status;
$$;

CREATE OR REPLACE FUNCTION public.get_campaign_target_counts(p_campaign uuid)
RETURNS TABLE(status text, cnt bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT ct.status::text, count(*)::bigint
  FROM public.campaign_targets ct
  WHERE ct.campaign_id = p_campaign
  GROUP BY ct.status;
$$;

GRANT EXECUTE ON FUNCTION public.get_campaign_stats_for_org(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_campaign_target_counts(uuid) TO authenticated, service_role;
