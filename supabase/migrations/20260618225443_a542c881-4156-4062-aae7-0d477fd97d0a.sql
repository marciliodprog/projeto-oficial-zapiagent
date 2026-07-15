
CREATE OR REPLACE FUNCTION public.get_followup_panel_stats(
  p_from timestamptz DEFAULT (now() - interval '7 days'),
  p_to   timestamptz DEFAULT now(),
  p_agent_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org uuid;
  v_today_start timestamptz := date_trunc('day', now());
  v_kpis jsonb;
  v_recovery jsonb;
  v_trend jsonb;
  v_status jsonb;
  v_upcoming jsonb;
BEGIN
  SELECT organization_id INTO v_org FROM profiles WHERE id = auth.uid();
  IF v_org IS NULL THEN
    RETURN jsonb_build_object('error', 'no_org');
  END IF;

  -- KPIs
  WITH base AS (
    SELECT * FROM ai_outreach_queue
    WHERE organization_id = v_org
      AND (p_agent_id IS NULL OR agent_id = p_agent_id)
  ),
  in_period AS (
    SELECT * FROM base
    WHERE COALESCE(last_outreach_at, created_at) BETWEEN p_from AND p_to
  ),
  active AS (
    SELECT * FROM base
    WHERE ruler_closed = false AND followup_enabled = true
  )
  SELECT jsonb_build_object(
    'leads_in_followup', (SELECT count(DISTINCT lead_id) FROM active),
    'waiting_next', (SELECT count(*) FROM active WHERE next_followup_at IS NOT NULL AND next_followup_at > now()),
    'sent_today', (SELECT count(*) FROM base WHERE last_outreach_at >= v_today_start),
    'recovered', (SELECT count(*) FROM in_period WHERE status = 'replied'),
    'sent_in_period', (SELECT count(*) FROM base WHERE last_outreach_at BETWEEN p_from AND p_to),
    'rulers_closed', (SELECT count(*) FROM base WHERE ruler_closed = true AND last_attempt_executed >= COALESCE(max_followups, 0) AND last_attempt_executed > 0)
  ) INTO v_kpis;

  -- Recovery by attempt (1..5)
  WITH att AS (
    SELECT
      generate_series(1, 5) AS n
  ),
  sent_by_attempt AS (
    SELECT last_attempt_executed AS n, count(*) AS sent
    FROM ai_outreach_queue
    WHERE organization_id = v_org
      AND (p_agent_id IS NULL OR agent_id = p_agent_id)
      AND last_attempt_executed BETWEEN 1 AND 5
      AND COALESCE(last_outreach_at, created_at) BETWEEN p_from AND p_to
    GROUP BY last_attempt_executed
  ),
  replied_by_attempt AS (
    SELECT last_attempt_executed AS n, count(*) AS replied
    FROM ai_outreach_queue
    WHERE organization_id = v_org
      AND (p_agent_id IS NULL OR agent_id = p_agent_id)
      AND status = 'replied'
      AND last_attempt_executed BETWEEN 1 AND 5
      AND COALESCE(last_outreach_at, created_at) BETWEEN p_from AND p_to
    GROUP BY last_attempt_executed
  )
  SELECT jsonb_agg(jsonb_build_object(
    'attempt', a.n,
    'sent', COALESCE(s.sent, 0),
    'replied', COALESCE(r.replied, 0),
    'rate', CASE WHEN COALESCE(s.sent, 0) > 0 THEN ROUND((COALESCE(r.replied,0)::numeric / s.sent::numeric) * 100, 1) ELSE 0 END
  ) ORDER BY a.n)
  FROM att a
  LEFT JOIN sent_by_attempt s ON s.n = a.n
  LEFT JOIN replied_by_attempt r ON r.n = a.n
  INTO v_recovery;

  -- Sent trend last 7 days
  WITH days AS (
    SELECT generate_series(date_trunc('day', now()) - interval '6 days', date_trunc('day', now()), interval '1 day') AS d
  ),
  per_day AS (
    SELECT date_trunc('day', last_outreach_at) AS d, count(*) AS c
    FROM ai_outreach_queue
    WHERE organization_id = v_org
      AND (p_agent_id IS NULL OR agent_id = p_agent_id)
      AND last_outreach_at >= date_trunc('day', now()) - interval '6 days'
    GROUP BY 1
  )
  SELECT jsonb_agg(jsonb_build_object(
    'day', to_char(days.d, 'YYYY-MM-DD'),
    'count', COALESCE(p.c, 0)
  ) ORDER BY days.d)
  FROM days
  LEFT JOIN per_day p ON p.d = days.d
  INTO v_trend;

  -- Status breakdown of active rulers
  WITH active AS (
    SELECT * FROM ai_outreach_queue
    WHERE organization_id = v_org
      AND (p_agent_id IS NULL OR agent_id = p_agent_id)
      AND ruler_closed = false
  )
  SELECT jsonb_build_object(
    'waiting_next', (SELECT count(*) FROM active WHERE followup_enabled = true AND next_followup_at IS NOT NULL AND next_followup_at > now()),
    'waiting_reply', (SELECT count(*) FROM active WHERE followup_enabled = true AND (next_followup_at IS NULL OR next_followup_at <= now())),
    'paused', (SELECT count(*) FROM active WHERE followup_enabled = false),
    'others', 0
  ) INTO v_status;

  -- Upcoming dispatches buckets
  WITH base AS (
    SELECT next_followup_at FROM ai_outreach_queue
    WHERE organization_id = v_org
      AND (p_agent_id IS NULL OR agent_id = p_agent_id)
      AND ruler_closed = false
      AND followup_enabled = true
      AND next_followup_at IS NOT NULL
      AND next_followup_at > now()
  )
  SELECT jsonb_build_object(
    'in_5m',  (SELECT count(*) FROM base WHERE next_followup_at <= now() + interval '5 minutes'),
    'in_15m', (SELECT count(*) FROM base WHERE next_followup_at > now() + interval '5 minutes' AND next_followup_at <= now() + interval '15 minutes'),
    'in_30m', (SELECT count(*) FROM base WHERE next_followup_at > now() + interval '15 minutes' AND next_followup_at <= now() + interval '30 minutes'),
    'in_1h',  (SELECT count(*) FROM base WHERE next_followup_at > now() + interval '30 minutes' AND next_followup_at <= now() + interval '1 hour'),
    'in_2h',  (SELECT count(*) FROM base WHERE next_followup_at > now() + interval '1 hour' AND next_followup_at <= now() + interval '2 hours'),
    'after_24h', (SELECT count(*) FROM base WHERE next_followup_at > now() + interval '24 hours')
  ) INTO v_upcoming;

  RETURN jsonb_build_object(
    'kpis', v_kpis,
    'recovery_by_attempt', COALESCE(v_recovery, '[]'::jsonb),
    'sent_trend_7d', COALESCE(v_trend, '[]'::jsonb),
    'active_status_breakdown', v_status,
    'upcoming_buckets', v_upcoming
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_followup_panel_stats(timestamptz, timestamptz, uuid) TO authenticated;
