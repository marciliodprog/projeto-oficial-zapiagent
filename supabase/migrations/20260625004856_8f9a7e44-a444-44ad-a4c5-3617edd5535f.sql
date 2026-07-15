
-- ============================================
-- Etapa 3: Circuit breaker columns
-- ============================================
ALTER TABLE public.evolution_instances
  ADD COLUMN IF NOT EXISTS cooldown_until timestamptz,
  ADD COLUMN IF NOT EXISTS consecutive_failures integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_failure_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_failure_reason text;

ALTER TABLE public.whatsapp_meta_connections
  ADD COLUMN IF NOT EXISTS cooldown_until timestamptz,
  ADD COLUMN IF NOT EXISTS consecutive_failures integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_failure_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_failure_reason text;

CREATE INDEX IF NOT EXISTS idx_evolution_instances_cooldown ON public.evolution_instances(cooldown_until) WHERE cooldown_until IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_meta_connections_cooldown ON public.whatsapp_meta_connections(cooldown_until) WHERE cooldown_until IS NOT NULL;

-- ============================================
-- Report failure RPC
-- ============================================
CREATE OR REPLACE FUNCTION public.report_provider_failure(
  p_provider text,
  p_connection_id uuid,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_failures integer;
  v_last_at timestamptz;
  v_cooldown_until timestamptz;
BEGIN
  IF p_provider = 'evolution' THEN
    SELECT consecutive_failures, last_failure_at INTO v_failures, v_last_at
      FROM public.evolution_instances WHERE id = p_connection_id FOR UPDATE;

    IF v_last_at IS NULL OR v_last_at < now() - interval '10 minutes' THEN
      v_failures := 1;
    ELSE
      v_failures := COALESCE(v_failures, 0) + 1;
    END IF;

    IF v_failures >= 3 THEN
      v_cooldown_until := now() + interval '5 minutes';
      UPDATE public.evolution_instances
        SET consecutive_failures = 0,
            last_failure_at = now(),
            last_failure_reason = p_reason,
            cooldown_until = v_cooldown_until
        WHERE id = p_connection_id;
    ELSE
      UPDATE public.evolution_instances
        SET consecutive_failures = v_failures,
            last_failure_at = now(),
            last_failure_reason = p_reason
        WHERE id = p_connection_id;
    END IF;

  ELSIF p_provider = 'meta_whatsapp' THEN
    SELECT consecutive_failures, last_failure_at INTO v_failures, v_last_at
      FROM public.whatsapp_meta_connections WHERE id = p_connection_id FOR UPDATE;

    IF v_last_at IS NULL OR v_last_at < now() - interval '10 minutes' THEN
      v_failures := 1;
    ELSE
      v_failures := COALESCE(v_failures, 0) + 1;
    END IF;

    IF v_failures >= 3 THEN
      v_cooldown_until := now() + interval '5 minutes';
      UPDATE public.whatsapp_meta_connections
        SET consecutive_failures = 0,
            last_failure_at = now(),
            last_failure_reason = p_reason,
            cooldown_until = v_cooldown_until
        WHERE id = p_connection_id;
    ELSE
      UPDATE public.whatsapp_meta_connections
        SET consecutive_failures = v_failures,
            last_failure_at = now(),
            last_failure_reason = p_reason
        WHERE id = p_connection_id;
    END IF;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_provider');
  END IF;

  RETURN jsonb_build_object('ok', true, 'failures', v_failures, 'cooldown_until', v_cooldown_until);
END;
$$;

-- ============================================
-- Report success RPC
-- ============================================
CREATE OR REPLACE FUNCTION public.report_provider_success(
  p_provider text,
  p_connection_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_provider = 'evolution' THEN
    UPDATE public.evolution_instances
      SET consecutive_failures = 0,
          cooldown_until = NULL,
          last_failure_reason = NULL
      WHERE id = p_connection_id
        AND (consecutive_failures > 0 OR cooldown_until IS NOT NULL);
  ELSIF p_provider = 'meta_whatsapp' THEN
    UPDATE public.whatsapp_meta_connections
      SET consecutive_failures = 0,
          cooldown_until = NULL,
          last_failure_reason = NULL
      WHERE id = p_connection_id
        AND (consecutive_failures > 0 OR cooldown_until IS NOT NULL);
  END IF;
END;
$$;

-- ============================================
-- Clear cooldown RPC (super admin)
-- ============================================
CREATE OR REPLACE FUNCTION public.clear_provider_cooldown(
  p_provider text,
  p_connection_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin'::app_role) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_provider = 'evolution' THEN
    UPDATE public.evolution_instances
      SET cooldown_until = NULL, consecutive_failures = 0, last_failure_reason = NULL
      WHERE id = p_connection_id;
  ELSIF p_provider = 'meta_whatsapp' THEN
    UPDATE public.whatsapp_meta_connections
      SET cooldown_until = NULL, consecutive_failures = 0, last_failure_reason = NULL
      WHERE id = p_connection_id;
  END IF;
END;
$$;

-- ============================================
-- claim_campaign_targets v3: skip cooldown connections
-- ============================================
CREATE OR REPLACE FUNCTION public.claim_campaign_targets(
  p_global_limit integer DEFAULT 100,
  p_per_org_limit integer DEFAULT 10,
  p_lookahead_multiplier integer DEFAULT 10
) RETURNS SETOF campaign_targets
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH eligible AS (
    SELECT ct.id, ct.organization_id, ct.scheduled_for
      FROM public.campaign_targets ct
      LEFT JOIN public.evolution_instances ei
        ON ct.connection_type = 'evolution' AND ei.id = ct.instance_id
      LEFT JOIN public.whatsapp_meta_connections mc
        ON ct.connection_type = 'meta_whatsapp' AND mc.id = ct.instance_id
     WHERE ct.status = 'queued'
       AND ct.scheduled_for <= now()
       AND (ei.cooldown_until IS NULL OR ei.cooldown_until <= now())
       AND (mc.cooldown_until IS NULL OR mc.cooldown_until <= now())
     ORDER BY ct.scheduled_for
     FOR UPDATE OF ct SKIP LOCKED
     LIMIT GREATEST(p_global_limit * p_lookahead_multiplier, p_global_limit)
  ),
  ranked AS (
    SELECT id,
           ROW_NUMBER() OVER (PARTITION BY organization_id ORDER BY scheduled_for) AS rn
      FROM eligible
  ),
  capped AS (
    SELECT id FROM ranked WHERE rn <= p_per_org_limit LIMIT p_global_limit
  )
  UPDATE public.campaign_targets ct
     SET status = 'sending',
         attempts = COALESCE(ct.attempts, 0) + 1
    FROM capped
   WHERE ct.id = capped.id
  RETURNING ct.*;
END;
$$;
