
-- 1) Função de limpeza de chamadas presas
CREATE OR REPLACE FUNCTION public.sweep_stale_voice_calls()
RETURNS TABLE(closed_call_logs int, closed_sessions int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_logs int;
  v_sessions int;
BEGIN
  -- Fecha call_logs travados em statuses "ativos" há mais de 30 min sem ended_at
  WITH updated AS (
    UPDATE public.call_logs
    SET status = 'failed',
        ended_at = now(),
        metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('sweep_reason', 'stale_timeout', 'swept_at', now())
    WHERE status IN ('initiated','ringing','in_progress')
      AND ended_at IS NULL
      AND started_at < now() - interval '30 minutes'
    RETURNING 1
  )
  SELECT count(*) INTO v_logs FROM updated;

  -- Fecha voice_call_sessions correspondentes
  WITH updated AS (
    UPDATE public.voice_call_sessions
    SET ended_at = now(),
        outcome = COALESCE(outcome, 'abandoned')
    WHERE ended_at IS NULL
      AND started_at < now() - interval '30 minutes'
    RETURNING 1
  )
  SELECT count(*) INTO v_sessions FROM updated;

  RETURN QUERY SELECT v_logs, v_sessions;
END;
$$;

REVOKE ALL ON FUNCTION public.sweep_stale_voice_calls() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sweep_stale_voice_calls() TO service_role;

-- 2) Backfill imediato dos registros já presos
SELECT public.sweep_stale_voice_calls();
