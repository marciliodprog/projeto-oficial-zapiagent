CREATE OR REPLACE FUNCTION public.sync_conversation_last_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_conv_id uuid;
  v_last RECORD;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_conv_id := OLD.conversation_id;
  ELSE
    v_conv_id := NEW.conversation_id;
  END IF;

  IF v_conv_id IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP IN ('INSERT', 'UPDATE')
     AND COALESCE(NEW.is_deleted, false) = false
     AND NEW.content IS NOT NULL THEN
    UPDATE public.webchat_conversations c
       SET last_message_content      = NEW.content,
           last_message_metadata     = NEW.metadata,
           last_message_sender_type  = NEW.sender_type,
           last_message_created_at   = NEW.created_at,
           last_message_at           = NEW.created_at
     WHERE c.id = v_conv_id
       AND (c.last_message_created_at IS NULL OR NEW.created_at >= c.last_message_created_at);
    RETURN NEW;
  END IF;

  SELECT m.content, m.metadata, m.sender_type, m.created_at
    INTO v_last
    FROM public.webchat_messages m
    WHERE m.conversation_id = v_conv_id
      AND COALESCE(m.is_deleted, false) = false
    ORDER BY m.created_at DESC
    LIMIT 1;

  UPDATE public.webchat_conversations c
     SET last_message_content      = v_last.content,
         last_message_metadata     = v_last.metadata,
         last_message_sender_type  = v_last.sender_type,
         last_message_created_at   = v_last.created_at,
         last_message_at           = v_last.created_at
   WHERE c.id = v_conv_id;

  RETURN COALESCE(NEW, OLD);
END;
$function$;