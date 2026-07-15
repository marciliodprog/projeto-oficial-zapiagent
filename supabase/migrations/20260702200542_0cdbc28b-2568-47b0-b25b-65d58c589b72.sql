-- Journey Engine — Phase 2: refactor log_journey_event to use emit_journey_event
-- and add triggers for cadence, transfers, tags, notes, form submissions.

-- 1) Rewrite legacy log_journey_event to route through emit_journey_event
CREATE OR REPLACE FUNCTION public.log_journey_event(
  p_org UUID,
  p_lead UUID,
  p_type public.journey_event_type,
  p_category public.journey_event_category,
  p_channel TEXT DEFAULT NULL,
  p_source TEXT DEFAULT NULL,
  p_title TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_payload JSONB DEFAULT '{}'::jsonb,
  p_conversation UUID DEFAULT NULL,
  p_deal UUID DEFAULT NULL,
  p_product UUID DEFAULT NULL,
  p_stage UUID DEFAULT NULL,
  p_user UUID DEFAULT NULL,
  p_agent UUID DEFAULT NULL,
  p_occurred TIMESTAMPTZ DEFAULT now()
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
  IF p_org IS NULL OR p_lead IS NULL THEN RETURN NULL; END IF;
  v_id := public.emit_journey_event(
    p_organization_id := p_org,
    p_subject_type := 'lead',
    p_subject_id := p_lead,
    p_event_type := p_type,
    p_event_category := p_category,
    p_source_module := COALESCE(p_source, 'legacy_trigger'),
    p_channel := p_channel,
    p_source := p_source,
    p_title := p_title,
    p_description := p_description,
    p_payload := COALESCE(p_payload,'{}'::jsonb),
    p_actor_type := CASE WHEN p_agent IS NOT NULL THEN 'ai'
                         WHEN p_user IS NOT NULL THEN 'human'
                         ELSE 'system' END,
    p_actor_id := COALESCE(p_user, p_agent),
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
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END; $$;

-- 2) Trigger: lead_transfer_history → lead_transferred
CREATE OR REPLACE FUNCTION public.journey_on_lead_transfer()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org UUID;
BEGIN
  SELECT organization_id INTO v_org FROM public.leads WHERE id = NEW.lead_id;
  IF v_org IS NULL THEN RETURN NEW; END IF;
  PERFORM public.emit_journey_event(
    p_organization_id := v_org,
    p_subject_type := 'lead',
    p_subject_id := NEW.lead_id,
    p_event_type := 'lead_transferred'::public.journey_event_type,
    p_event_category := 'attendance'::public.journey_event_category,
    p_source_module := 'lead_transfer',
    p_title := 'Lead transferido',
    p_description := NEW.reason,
    p_payload := jsonb_build_object(
      'from_user_id', NEW.from_user_id,
      'to_user_id', NEW.to_user_id,
      'from_squad_id', NEW.from_squad_id,
      'to_squad_id', NEW.to_squad_id,
      'reason', NEW.reason
    ),
    p_actor_type := CASE WHEN NEW.transferred_by IS NOT NULL THEN 'human' ELSE 'system' END,
    p_actor_id := NEW.transferred_by,
    p_lead_id := NEW.lead_id,
    p_user_id := NEW.to_user_id,
    p_occurred_at := COALESCE(NEW.created_at, now()),
    p_dedupe_key := 'transfer:' || NEW.id::text
  );
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_journey_lead_transfer ON public.lead_transfer_history;
CREATE TRIGGER trg_journey_lead_transfer
AFTER INSERT ON public.lead_transfer_history
FOR EACH ROW EXECUTE FUNCTION public.journey_on_lead_transfer();

-- 3) Trigger: lead_tag_assignments → tag_added / tag_removed
CREATE OR REPLACE FUNCTION public.journey_on_tag_assignment()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org UUID; v_tag_name TEXT; v_lead UUID;
BEGIN
  v_lead := COALESCE(NEW.lead_id, OLD.lead_id);
  SELECT organization_id INTO v_org FROM public.leads WHERE id = v_lead;
  IF v_org IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;
  SELECT name INTO v_tag_name FROM public.lead_tags WHERE id = COALESCE(NEW.tag_id, OLD.tag_id);

  IF TG_OP = 'INSERT' THEN
    PERFORM public.emit_journey_event(
      p_organization_id := v_org,
      p_subject_type := 'lead', p_subject_id := v_lead,
      p_event_type := 'tag_added'::public.journey_event_type,
      p_event_category := 'qualification'::public.journey_event_category,
      p_source_module := COALESCE(NEW.source, 'tag_manual'),
      p_title := 'Tag adicionada: ' || COALESCE(v_tag_name, '(desconhecida)'),
      p_payload := jsonb_build_object('tag_id', NEW.tag_id, 'tag_name', v_tag_name, 'source', NEW.source),
      p_actor_type := CASE WHEN NEW.applied_by IS NOT NULL THEN 'human' ELSE 'system' END,
      p_actor_id := NEW.applied_by,
      p_lead_id := v_lead,
      p_occurred_at := COALESCE(NEW.applied_at, now()),
      p_dedupe_key := 'tag+:' || v_lead::text || ':' || NEW.tag_id::text || ':' || extract(epoch from COALESCE(NEW.applied_at, now()))::bigint::text
    );
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM public.emit_journey_event(
      p_organization_id := v_org,
      p_subject_type := 'lead', p_subject_id := v_lead,
      p_event_type := 'tag_removed'::public.journey_event_type,
      p_event_category := 'qualification'::public.journey_event_category,
      p_source_module := 'tag_manual',
      p_title := 'Tag removida: ' || COALESCE(v_tag_name, '(desconhecida)'),
      p_payload := jsonb_build_object('tag_id', OLD.tag_id, 'tag_name', v_tag_name),
      p_lead_id := v_lead,
      p_dedupe_key := 'tag-:' || v_lead::text || ':' || OLD.tag_id::text || ':' || extract(epoch from now())::bigint::text
    );
  END IF;
  RETURN COALESCE(NEW, OLD);
END; $$;

DROP TRIGGER IF EXISTS trg_journey_tag_assignment ON public.lead_tag_assignments;
CREATE TRIGGER trg_journey_tag_assignment
AFTER INSERT OR DELETE ON public.lead_tag_assignments
FOR EACH ROW EXECUTE FUNCTION public.journey_on_tag_assignment();

-- 4) Trigger: cadence_enrollments → cadence lifecycle
CREATE OR REPLACE FUNCTION public.journey_on_cadence_enrollment()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_type public.journey_event_type; v_title TEXT;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_type := 'followup_created'; v_title := 'Cadência iniciada';
  ELSIF NEW.status = 'completed' AND (OLD.status IS DISTINCT FROM 'completed') THEN
    v_type := 'followup_done'; v_title := 'Cadência concluída';
  ELSIF NEW.status = 'stopped' AND (OLD.status IS DISTINCT FROM 'stopped') THEN
    v_type := 'followup_done'; v_title := 'Cadência interrompida';
  ELSE
    RETURN NEW;
  END IF;

  PERFORM public.emit_journey_event(
    p_organization_id := NEW.organization_id,
    p_subject_type := 'lead', p_subject_id := NEW.lead_id,
    p_event_type := v_type,
    p_event_category := 'attendance'::public.journey_event_category,
    p_source_module := 'cadence',
    p_title := v_title,
    p_payload := jsonb_build_object(
      'cadence_id', NEW.cadence_id, 'enrollment_id', NEW.id,
      'status', NEW.status, 'stop_reason', NEW.stop_reason, 'source', NEW.source
    ),
    p_lead_id := NEW.lead_id,
    p_occurred_at := COALESCE(NEW.completed_at, NEW.stopped_at, NEW.enrolled_at, now()),
    p_dedupe_key := 'cadence-enroll:' || NEW.id::text || ':' || NEW.status
  );
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_journey_cadence_enrollment ON public.cadence_enrollments;
CREATE TRIGGER trg_journey_cadence_enrollment
AFTER INSERT OR UPDATE OF status ON public.cadence_enrollments
FOR EACH ROW EXECUTE FUNCTION public.journey_on_cadence_enrollment();

-- 5) Trigger: cadence_step_runs → step sent/failed/skipped
CREATE OR REPLACE FUNCTION public.journey_on_cadence_step_run()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_lead UUID;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  IF NEW.status NOT IN ('sent','failed','skipped') THEN RETURN NEW; END IF;
  SELECT lead_id INTO v_lead FROM public.cadence_enrollments WHERE id = NEW.enrollment_id;
  IF v_lead IS NULL THEN RETURN NEW; END IF;

  PERFORM public.emit_journey_event(
    p_organization_id := NEW.organization_id,
    p_subject_type := 'lead', p_subject_id := v_lead,
    p_event_type := CASE WHEN NEW.status = 'sent' THEN 'message_sent'::public.journey_event_type
                         ELSE 'followup_created'::public.journey_event_type END,
    p_event_category := 'attendance'::public.journey_event_category,
    p_source_module := 'cadence',
    p_channel := 'whatsapp',
    p_title := CASE NEW.status
                 WHEN 'sent' THEN 'Passo de cadência enviado'
                 WHEN 'failed' THEN 'Passo de cadência falhou'
                 ELSE 'Passo de cadência ignorado' END,
    p_description := left(COALESCE(NEW.agent_message, ''), 500),
    p_payload := jsonb_build_object(
      'enrollment_id', NEW.enrollment_id, 'step_id', NEW.step_id,
      'status', NEW.status, 'skip_reason', NEW.skip_reason,
      'error', NEW.error, 'conversation_id', NEW.conversation_id
    ),
    p_actor_type := 'ai',
    p_lead_id := v_lead,
    p_conversation_id := NEW.conversation_id,
    p_occurred_at := COALESCE(NEW.executed_at, now()),
    p_dedupe_key := 'cadence-run:' || NEW.id::text || ':' || NEW.status
  );
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_journey_cadence_step_run ON public.cadence_step_runs;
CREATE TRIGGER trg_journey_cadence_step_run
AFTER UPDATE OF status ON public.cadence_step_runs
FOR EACH ROW EXECUTE FUNCTION public.journey_on_cadence_step_run();

-- 6) Trigger: lead_notes
CREATE OR REPLACE FUNCTION public.journey_on_lead_note()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org UUID;
BEGIN
  SELECT organization_id INTO v_org FROM public.leads WHERE id = NEW.lead_id;
  IF v_org IS NULL THEN RETURN NEW; END IF;
  PERFORM public.emit_journey_event(
    p_organization_id := v_org,
    p_subject_type := 'lead', p_subject_id := NEW.lead_id,
    p_event_type := 'field_changed'::public.journey_event_type,
    p_event_category := 'attendance'::public.journey_event_category,
    p_source_module := 'lead_notes',
    p_title := 'Nota adicionada',
    p_description := left(NEW.content, 500),
    p_payload := jsonb_build_object('note_id', NEW.id, 'author_id', NEW.author_id),
    p_actor_type := 'human',
    p_actor_id := NEW.author_id,
    p_user_id := NEW.author_id,
    p_lead_id := NEW.lead_id,
    p_occurred_at := COALESCE(NEW.created_at, now()),
    p_dedupe_key := 'note:' || NEW.id::text
  );
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_journey_lead_note ON public.lead_notes;
CREATE TRIGGER trg_journey_lead_note
AFTER INSERT ON public.lead_notes
FOR EACH ROW EXECUTE FUNCTION public.journey_on_lead_note();

-- 7) Trigger: form_submissions → origin
CREATE OR REPLACE FUNCTION public.journey_on_form_submission()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org UUID; v_form_name TEXT; v_utm_source TEXT; v_utm_campaign TEXT;
BEGIN
  IF NEW.lead_id IS NULL THEN RETURN NEW; END IF;
  SELECT organization_id, name INTO v_org, v_form_name FROM public.forms WHERE id = NEW.form_id;
  IF v_org IS NULL THEN
    SELECT organization_id INTO v_org FROM public.leads WHERE id = NEW.lead_id;
  END IF;
  IF v_org IS NULL THEN RETURN NEW; END IF;

  BEGIN
    v_utm_source := (to_jsonb(NEW) ->> 'utm_source');
    v_utm_campaign := (to_jsonb(NEW) ->> 'utm_campaign');
  EXCEPTION WHEN OTHERS THEN NULL; END;

  PERFORM public.emit_journey_event(
    p_organization_id := v_org,
    p_subject_type := 'lead', p_subject_id := NEW.lead_id,
    p_event_type := 'lead_created'::public.journey_event_type,
    p_event_category := 'origin'::public.journey_event_category,
    p_source_module := 'form_submit',
    p_channel := 'form',
    p_source := COALESCE(v_utm_source, v_form_name),
    p_title := 'Formulário enviado: ' || COALESCE(v_form_name, 'sem nome'),
    p_payload := jsonb_build_object(
      'form_id', NEW.form_id, 'submission_id', NEW.id,
      'total_score', NEW.total_score, 'tags', NEW.tags,
      'utm_source', v_utm_source, 'utm_campaign', v_utm_campaign
    ),
    p_lead_id := NEW.lead_id,
    p_occurred_at := COALESCE(NEW.created_at, now()),
    p_dedupe_key := 'form-sub:' || NEW.id::text
  );
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_journey_form_submission ON public.form_submissions;
CREATE TRIGGER trg_journey_form_submission
AFTER INSERT ON public.form_submissions
FOR EACH ROW EXECUTE FUNCTION public.journey_on_form_submission();