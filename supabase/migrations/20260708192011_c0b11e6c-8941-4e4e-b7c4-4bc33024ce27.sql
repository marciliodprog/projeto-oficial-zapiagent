
UPDATE public.voice_call_sessions
SET cost_usd_estimated = ROUND((duration_sec/60.0 * 0.10)::numeric, 6),
    provider = COALESCE(provider, 'grok'),
    pricing_snapshot = jsonb_build_object(
      'backfill', true, 'minute', jsonb_build_object('rate', 0.10, 'minutes', ROUND((duration_sec/60.0)::numeric, 2))
    )
WHERE cost_usd_estimated = 0 AND duration_sec > 0;
