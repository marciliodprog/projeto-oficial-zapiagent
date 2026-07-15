
CREATE OR REPLACE FUNCTION public.get_products_stats(_organization_id uuid)
RETURNS TABLE (
  product_id uuid,
  total_leads bigint,
  sellers_count bigint,
  won_count bigint,
  won_value numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p.id AS product_id,
    COALESCE((SELECT COUNT(*) FROM public.leads l WHERE l.product_id = p.id), 0) AS total_leads,
    COALESCE((SELECT COUNT(*) FROM public.user_product_assignments u WHERE u.product_id = p.id), 0) AS sellers_count,
    COALESCE((SELECT COUNT(*) FROM public.deals d WHERE d.product_id = p.id AND d.status = 'won'), 0) AS won_count,
    COALESCE((SELECT SUM(d.deal_value) FROM public.deals d WHERE d.product_id = p.id AND d.status = 'won'), 0) AS won_value
  FROM public.products p
  WHERE p.organization_id = _organization_id
     OR public.has_role(auth.uid(), 'super_admin'::app_role);
$$;

GRANT EXECUTE ON FUNCTION public.get_products_stats(uuid) TO authenticated;
