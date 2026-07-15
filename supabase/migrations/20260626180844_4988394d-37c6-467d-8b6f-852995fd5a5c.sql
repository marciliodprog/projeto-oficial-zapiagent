CREATE OR REPLACE FUNCTION public.protect_booking_public_updates()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- service_role (edge functions / admin) bypasses this guard
  IF current_user = 'service_role' OR current_setting('role', true) = 'service_role' THEN
    RETURN NEW;
  END IF;

  -- Authenticated host/owner edits bypass this guard
  IF auth.uid() IS NOT NULL AND auth.uid() = OLD.host_user_id THEN
    RETURN NEW;
  END IF;

  -- Public/anon updates: keep identity columns immutable
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.event_type_id IS DISTINCT FROM OLD.event_type_id
     OR NEW.host_user_id IS DISTINCT FROM OLD.host_user_id
     OR NEW.confirmation_token IS DISTINCT FROM OLD.confirmation_token
     OR NEW.guest_email IS DISTINCT FROM OLD.guest_email
     OR NEW.guest_name IS DISTINCT FROM OLD.guest_name
     OR NEW.guest_phone IS DISTINCT FROM OLD.guest_phone
     OR NEW.lead_id IS DISTINCT FROM OLD.lead_id
     OR NEW.calendar_event_id IS DISTINCT FROM OLD.calendar_event_id THEN
    RAISE EXCEPTION 'Public updates may only change status, cancellation_reason, start_time, end_time and timezone';
  END IF;
  RETURN NEW;
END;
$function$;