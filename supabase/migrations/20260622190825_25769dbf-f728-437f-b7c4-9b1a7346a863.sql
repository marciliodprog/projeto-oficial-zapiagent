
-- 1) Higieniza backlog: cancela targets queued de campanhas que não estão active
UPDATE public.campaign_targets t
SET status = 'cancelled',
    error = COALESCE(error, 'campaign_not_active_cleanup')
FROM public.campaigns c
WHERE t.campaign_id = c.id
  AND t.status = 'queued'
  AND c.status <> 'active';

-- 2) Trigger de coerência: ao pausar/cancelar/finalizar campanha, cancela targets queued
CREATE OR REPLACE FUNCTION public.cancel_queued_targets_on_campaign_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status IN ('paused','cancelled','completed','draft') THEN
    UPDATE public.campaign_targets
    SET status = 'cancelled',
        error = COALESCE(error, 'campaign_status_' || NEW.status)
    WHERE campaign_id = NEW.id
      AND status = 'queued';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cancel_queued_targets_on_campaign_status ON public.campaigns;
CREATE TRIGGER trg_cancel_queued_targets_on_campaign_status
AFTER UPDATE OF status ON public.campaigns
FOR EACH ROW
EXECUTE FUNCTION public.cancel_queued_targets_on_campaign_status();

-- 3) Índices de apoio (idempotentes)
CREATE INDEX IF NOT EXISTS idx_campaign_targets_queued_sched
  ON public.campaign_targets (campaign_id, scheduled_for)
  WHERE status = 'queued';

CREATE INDEX IF NOT EXISTS idx_webchat_messages_meta_n
  ON public.webchat_messages ((metadata->>'n'));

CREATE INDEX IF NOT EXISTS idx_webchat_messages_meta_external_id
  ON public.webchat_messages ((metadata->>'external_id'));

-- 4) View admin_cron_health (saúde dos cron jobs e detecção de duplicação)
CREATE OR REPLACE VIEW public.admin_cron_health AS
SELECT
  j.jobname,
  j.schedule,
  j.active,
  COUNT(*) FILTER (WHERE d.start_time > now() - interval '24 hours') AS runs_24h,
  COUNT(*) FILTER (WHERE d.status = 'failed' AND d.start_time > now() - interval '24 hours') AS failed_24h,
  MAX(d.start_time) AS last_run,
  MAX(d.status)     AS last_status,
  ROUND(AVG(EXTRACT(EPOCH FROM (d.end_time - d.start_time))*1000)
        FILTER (WHERE d.start_time > now() - interval '24 hours')::numeric, 1) AS avg_ms_24h,
  (SELECT COUNT(*) FROM cron.job j2 WHERE j2.jobname = j.jobname) AS duplicates
FROM cron.job j
LEFT JOIN cron.job_run_details d ON d.jobid = j.jobid
GROUP BY j.jobname, j.schedule, j.active;

REVOKE ALL ON public.admin_cron_health FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.admin_cron_health TO service_role;
