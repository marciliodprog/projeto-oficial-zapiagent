
CREATE OR REPLACE FUNCTION public.fn_stop_auto_followup_on_human_takeover()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason text := NULL;
  v_outreach_cancelled int := 0;
  v_cadence_stopped int := 0;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.status::text = 'waiting_human' AND OLD.status::text IS DISTINCT FROM NEW.status::text THEN
      v_reason := 'transferred_to_human_queue';
    ELSIF NEW.status::text = 'human_active' AND OLD.status::text IS DISTINCT FROM NEW.status::text THEN
      v_reason := 'human_accepted';
    ELSIF NEW.status::text = 'closed' AND OLD.status::text IS DISTINCT FROM NEW.status::text THEN
      v_reason := 'conversation_closed';
    ELSIF NEW.assigned_user_id IS NOT NULL AND OLD.assigned_user_id IS NULL THEN
      v_reason := 'human_accepted';
    END IF;
  END IF;

  IF v_reason IS NULL THEN
    RETURN NEW;
  END IF;

  WITH upd AS (
    UPDATE public.ai_outreach_queue
       SET status = 'completed',
           followup_enabled = false,
           next_followup_at = NULL,
           ruler_closed = true,
           error_message = v_reason
     WHERE conversation_id = NEW.id
       AND status IN ('pending','scheduled','processing','sent')
       AND ruler_closed = false
     RETURNING 1
  )
  SELECT count(*) INTO v_outreach_cancelled FROM upd;

  IF NEW.lead_id IS NOT NULL THEN
    WITH upd2 AS (
      UPDATE public.cadence_enrollments
         SET status = 'stopped',
             stopped_at = now(),
             stop_reason = v_reason,
             updated_at = now()
       WHERE lead_id = NEW.lead_id
         AND organization_id = NEW.organization_id
         AND status = 'active'
       RETURNING 1
    )
    SELECT count(*) INTO v_cadence_stopped FROM upd2;
  END IF;

  IF (v_outreach_cancelled + v_cadence_stopped) > 0 THEN
    BEGIN
      PERFORM public.emit_journey_event(
        p_organization_id  := NEW.organization_id,
        p_subject_type     := 'lead',
        p_subject_id       := NEW.lead_id,
        p_event_type       := 'cadence_completed'::journey_event_type,
        p_event_category   := 'attendance'::journey_event_category,
        p_source_module    := 'auto_followup',
        p_channel          := NULL,
        p_source           := NULL,
        p_title            := 'Follow-up automático interrompido',
        p_description      := 'Motivo: ' || v_reason,
        p_payload          := jsonb_build_object(
                                'reason', v_reason,
                                'outreach_cancelled', v_outreach_cancelled,
                                'cadence_stopped', v_cadence_stopped
                              ),
        p_actor_type       := 'system',
        p_actor_id         := NULL,
        p_lead_id          := NEW.lead_id,
        p_conversation_id  := NEW.id,
        p_deal_id          := NULL,
        p_product_id       := NULL,
        p_pipeline_stage_id:= NULL,
        p_user_id          := NEW.assigned_user_id,
        p_agent_id         := NULL,
        p_occurred_at      := now(),
        p_correlation_id   := NULL,
        p_session_id       := NULL,
        p_dedupe_key       := 'auto_followup_stop:' || NEW.id::text || ':' || v_reason
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_close_followup_on_conv_close ON public.webchat_conversations;
DROP TRIGGER IF EXISTS trg_stop_auto_followup_on_human_takeover ON public.webchat_conversations;

CREATE TRIGGER trg_stop_auto_followup_on_human_takeover
AFTER UPDATE OF status, assigned_user_id ON public.webchat_conversations
FOR EACH ROW
EXECUTE FUNCTION public.fn_stop_auto_followup_on_human_takeover();

-- Backfill
UPDATE public.ai_outreach_queue q
   SET status = 'completed',
       followup_enabled = false,
       next_followup_at = NULL,
       ruler_closed = true,
       error_message = 'backfill_human_takeover'
  FROM public.webchat_conversations c
 WHERE q.conversation_id = c.id
   AND c.status::text IN ('waiting_human','human_active')
   AND q.status IN ('pending','scheduled','processing','sent')
   AND q.ruler_closed = false;

UPDATE public.cadence_enrollments e
   SET status = 'stopped',
       stopped_at = now(),
       stop_reason = 'backfill_human_takeover',
       updated_at = now()
  FROM public.webchat_conversations c
 WHERE e.lead_id = c.lead_id
   AND e.organization_id = c.organization_id
   AND c.status::text IN ('waiting_human','human_active')
   AND e.status = 'active';
