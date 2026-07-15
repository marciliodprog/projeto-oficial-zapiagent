-- Drop both possible legacy signatures to avoid ambiguity
DROP FUNCTION IF EXISTS public.log_journey_event(uuid, uuid, public.journey_event_type, public.journey_event_category, text, text, text, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, timestamptz);
DROP FUNCTION IF EXISTS public.log_journey_event(uuid, uuid, text, text, text, text, text, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, timestamptz);

CREATE OR REPLACE FUNCTION public.log_journey_event(
  p_org uuid,
  p_lead uuid,
  p_type text,
  p_category text,
  p_channel text DEFAULT NULL,
  p_source text DEFAULT NULL,
  p_title text DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_conversation uuid DEFAULT NULL,
  p_deal uuid DEFAULT NULL,
  p_product uuid DEFAULT NULL,
  p_stage uuid DEFAULT NULL,
  p_user uuid DEFAULT NULL,
  p_agent uuid DEFAULT NULL,
  p_occurred timestamptz DEFAULT now()
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_id uuid;
BEGIN
  v_id := public.emit_journey_event(
    p_organization_id := p_org,
    p_subject_type := 'lead',
    p_subject_id := p_lead,
    p_event_type := p_type::public.journey_event_type,
    p_event_category := p_category::public.journey_event_category,
    p_channel := p_channel,
    p_source := p_source,
    p_title := p_title,
    p_description := p_description,
    p_payload := COALESCE(p_payload, '{}'::jsonb),
    p_lead_id := p_lead,
    p_conversation_id := p_conversation,
    p_deal_id := p_deal,
    p_product_id := p_product,
    p_pipeline_stage_id := p_stage,
    p_user_id := p_user,
    p_agent_id := p_agent,
    p_occurred_at := p_occurred
  );
  RETURN v_id;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'log_journey_event failed: %', SQLERRM;
  RETURN NULL;
END; $$;