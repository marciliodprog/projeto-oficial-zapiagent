
-- Index supporting the throughput view
CREATE INDEX IF NOT EXISTS idx_campaign_targets_org_status_sentat
  ON public.campaign_targets (organization_id, status, sent_at DESC)
  WHERE sent_at IS NOT NULL;

-- Throughput view: 7 days, per org, per hour, per status
CREATE OR REPLACE VIEW public.v_campaign_throughput
WITH (security_invoker = true)
AS
SELECT
  organization_id,
  date_trunc('hour', COALESCE(sent_at, scheduled_for)) AS bucket_hour,
  status,
  COUNT(*)::bigint AS total
FROM public.campaign_targets
WHERE COALESCE(sent_at, scheduled_for) >= now() - interval '7 days'
GROUP BY organization_id, date_trunc('hour', COALESCE(sent_at, scheduled_for)), status;

GRANT SELECT ON public.v_campaign_throughput TO authenticated;
GRANT SELECT ON public.v_campaign_throughput TO service_role;

-- Provider health view: connections currently in cooldown
CREATE OR REPLACE VIEW public.v_provider_health
WITH (security_invoker = true)
AS
SELECT
  'evolution'::text AS provider,
  ei.id AS connection_id,
  ei.organization_id,
  ei.name AS connection_name,
  ei.cooldown_until,
  ei.last_failure_reason,
  ei.last_failure_at
FROM public.evolution_instances ei
WHERE ei.cooldown_until IS NOT NULL AND ei.cooldown_until > now()
UNION ALL
SELECT
  'meta_whatsapp'::text AS provider,
  mc.id AS connection_id,
  mc.organization_id,
  mc.display_name AS connection_name,
  mc.cooldown_until,
  mc.last_failure_reason,
  mc.last_failure_at
FROM public.whatsapp_meta_connections mc
WHERE mc.cooldown_until IS NOT NULL AND mc.cooldown_until > now();

GRANT SELECT ON public.v_provider_health TO authenticated;
GRANT SELECT ON public.v_provider_health TO service_role;
