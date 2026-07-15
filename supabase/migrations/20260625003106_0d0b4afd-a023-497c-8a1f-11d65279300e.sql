CREATE OR REPLACE FUNCTION public.claim_campaign_preparation_jobs(p_limit int DEFAULT 3)
RETURNS SETOF public.campaign_preparation_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH picked AS (
    SELECT id
      FROM public.campaign_preparation_jobs
     WHERE status = 'pending'
     ORDER BY created_at
     FOR UPDATE SKIP LOCKED
     LIMIT p_limit
  )
  UPDATE public.campaign_preparation_jobs j
     SET status = 'running',
         started_at = COALESCE(j.started_at, now()),
         updated_at = now()
    FROM picked
   WHERE j.id = picked.id
  RETURNING j.*;
END $$;

REVOKE EXECUTE ON FUNCTION public.claim_campaign_preparation_jobs(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_campaign_preparation_jobs(int) TO service_role;
