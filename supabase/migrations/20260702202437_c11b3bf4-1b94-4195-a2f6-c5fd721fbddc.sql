CREATE OR REPLACE FUNCTION public.emit_journey_event(
  p_organization_id uuid,
  p_subject_type text,
  p_subject_id uuid,
  p_event_type public.journey_event_type,
  p_event_category public.journey_event_category DEFAULT 'system'::public.journey_event_category,
  p_source_module text DEFAULT NULL,
  p_channel text DEFAULT NULL,
  p_source text DEFAULT NULL,
  p_title text DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_actor_type text DEFAULT 'system',
  p_actor_id uuid DEFAULT NULL,
  p_lead_id uuid DEFAULT NULL,
  p_conversation_id uuid DEFAULT NULL,
  p_deal_id uuid DEFAULT NULL,
  p_product_id uuid DEFAULT NULL,
  p_pipeline_stage_id uuid DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_agent_id uuid DEFAULT NULL,
  p_occurred_at timestamptz DEFAULT now(),
  p_correlation_id uuid DEFAULT NULL,
  p_session_id uuid DEFAULT NULL,
  p_dedupe_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
  v_effective_lead UUID;
BEGIN
  v_effective_lead := COALESCE(p_lead_id, CASE WHEN p_subject_type = 'lead' THEN p_subject_id END);

  -- Idempotência: se veio dedupe_key e já existe, retorna a linha existente
  IF p_dedupe_key IS NOT NULL THEN
    SELECT id INTO v_id
    FROM public.journey_events
    WHERE organization_id = p_organization_id
      AND source_module IS NOT DISTINCT FROM p_source_module
      AND dedupe_key = p_dedupe_key
    LIMIT 1;
    IF v_id IS NOT NULL THEN
      RETURN v_id;
    END IF;
  END IF;

  INSERT INTO public.journey_events (
    organization_id, subject_type, subject_id,
    event_type, event_category, source_module,
    channel, source, title, description, payload,
    actor_type, actor_id,
    lead_id, conversation_id, deal_id, product_id, pipeline_stage_id, user_id, agent_id,
    occurred_at, correlation_id, session_id, dedupe_key
  ) VALUES (
    p_organization_id, p_subject_type, p_subject_id,
    p_event_type, p_event_category, p_source_module,
    p_channel, p_source, p_title, p_description, COALESCE(p_payload, '{}'::jsonb),
    p_actor_type, p_actor_id,
    v_effective_lead, p_conversation_id, p_deal_id, p_product_id, p_pipeline_stage_id, p_user_id, p_agent_id,
    p_occurred_at, p_correlation_id, p_session_id, p_dedupe_key
  )
  RETURNING id INTO v_id;

  RETURN v_id;
EXCEPTION WHEN unique_violation THEN
  -- Corrida com outro insert que ganhou a chave dedupe — busca e retorna
  SELECT id INTO v_id
  FROM public.journey_events
  WHERE organization_id = p_organization_id
    AND source_module IS NOT DISTINCT FROM p_source_module
    AND dedupe_key = p_dedupe_key
  LIMIT 1;
  RETURN v_id;
END; $$;