
-- Índice de apoio para checagem de conflito
CREATE INDEX IF NOT EXISTS idx_calendar_events_user_time_active
  ON public.calendar_events (user_id, start_time, end_time)
  WHERE status <> 'cancelled';

CREATE OR REPLACE FUNCTION public.enforce_booking_slot_uniqueness()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conflict RECORD;
  v_new_guest_email TEXT;
  v_new_guest_phone TEXT;
  v_conf_guest_email TEXT;
  v_conf_guest_phone TEXT;
  v_same_lead BOOLEAN;
BEGIN
  -- Só valida eventos ativos
  IF NEW.status = 'cancelled' THEN
    RETURN NEW;
  END IF;

  -- Aplica regra apenas quando envolve agendamento/lead
  IF NEW.event_type <> 'booking' AND NEW.lead_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_new_guest_email := lower(coalesce(NEW.metadata->>'guest_email',''));
  v_new_guest_phone := regexp_replace(coalesce(NEW.metadata->>'guest_phone',''), '\D', '', 'g');

  FOR v_conflict IN
    SELECT id, lead_id, metadata, event_type
    FROM public.calendar_events
    WHERE user_id = NEW.user_id
      AND status <> 'cancelled'
      AND id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND start_time < NEW.end_time
      AND end_time > NEW.start_time
  LOOP
    v_conf_guest_email := lower(coalesce(v_conflict.metadata->>'guest_email',''));
    v_conf_guest_phone := regexp_replace(coalesce(v_conflict.metadata->>'guest_phone',''), '\D', '', 'g');

    v_same_lead := (
      (NEW.lead_id IS NOT NULL AND v_conflict.lead_id IS NOT NULL AND NEW.lead_id = v_conflict.lead_id)
      OR (length(v_new_guest_email) > 0 AND v_new_guest_email = v_conf_guest_email)
      OR (length(v_new_guest_phone) > 0 AND v_new_guest_phone = v_conf_guest_phone)
    );

    IF v_same_lead THEN
      -- Mesmo lead remarcando: cancela o evento anterior
      UPDATE public.calendar_events
      SET status = 'cancelled',
          metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
            'replaced_by', NEW.id,
            'cancellation_reason', 'rescheduled_by_same_lead',
            'cancelled_at', now()
          ),
          updated_at = now()
      WHERE id = v_conflict.id;

      UPDATE public.booking_requests
      SET status = 'cancelado',
          cancellation_reason = 'rescheduled_by_same_lead',
          updated_at = now()
      WHERE calendar_event_id = v_conflict.id
        AND status NOT IN ('cancelado','cancelled');

    ELSIF NEW.event_type = 'booking' OR v_conflict.event_type = 'booking' THEN
      -- Lead diferente: bloqueia
      RAISE EXCEPTION 'slot_conflict: horário já reservado para este responsável'
        USING ERRCODE = 'unique_violation';
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_booking_slot_uniqueness ON public.calendar_events;
CREATE TRIGGER trg_enforce_booking_slot_uniqueness
BEFORE INSERT OR UPDATE OF start_time, end_time, user_id, status, lead_id, event_type
ON public.calendar_events
FOR EACH ROW
EXECUTE FUNCTION public.enforce_booking_slot_uniqueness();
