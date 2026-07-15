
DROP VIEW IF EXISTS public.admin_cron_health;
CREATE VIEW public.admin_cron_health
WITH (security_invoker = on) AS
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

GRANT SELECT ON public.admin_cron_health TO service_role;
