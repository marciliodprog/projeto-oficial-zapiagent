
-- Etapa 1.1 — Índices parciais para a fila
CREATE INDEX IF NOT EXISTS idx_campaign_targets_queue
  ON public.campaign_targets (status, scheduled_for, organization_id, campaign_id)
  WHERE status = 'queued';

CREATE INDEX IF NOT EXISTS idx_campaign_targets_campaign_status
  ON public.campaign_targets (campaign_id, status);

CREATE INDEX IF NOT EXISTS idx_campaign_targets_org_status_time
  ON public.campaign_targets (organization_id, status, scheduled_for);

-- Etapa 1.2 — RPC fair-share com SKIP LOCKED + ROW_NUMBER por org
CREATE OR REPLACE FUNCTION public.claim_campaign_targets(
  p_global_limit int DEFAULT 100,
  p_per_org_limit int DEFAULT 10,
  p_lookahead_multiplier int DEFAULT 10
)
RETURNS SETOF public.campaign_targets
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH eligible AS (
    SELECT id, organization_id, scheduled_for
      FROM public.campaign_targets
     WHERE status = 'queued'
       AND scheduled_for <= now()
     ORDER BY scheduled_for
     FOR UPDATE SKIP LOCKED
     LIMIT GREATEST(p_global_limit * p_lookahead_multiplier, p_global_limit)
  ),
  ranked AS (
    SELECT id,
           ROW_NUMBER() OVER (PARTITION BY organization_id ORDER BY scheduled_for) AS rn
      FROM eligible
  ),
  capped AS (
    SELECT id
      FROM ranked
     WHERE rn <= p_per_org_limit
     LIMIT p_global_limit
  )
  UPDATE public.campaign_targets ct
     SET status   = 'sending',
         attempts = COALESCE(ct.attempts, 0) + 1
    FROM capped
   WHERE ct.id = capped.id
  RETURNING ct.*;
END
$$;

REVOKE EXECUTE ON FUNCTION public.claim_campaign_targets(int, int, int) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.claim_campaign_targets(int, int, int) TO service_role;
