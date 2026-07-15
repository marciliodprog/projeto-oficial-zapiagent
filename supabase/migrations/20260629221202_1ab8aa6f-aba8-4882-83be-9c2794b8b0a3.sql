CREATE OR REPLACE FUNCTION public.sync_conversation_unread_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.direction = 'inbound'
     AND COALESCE(NEW.sender_type, '') = 'visitor'
     AND COALESCE(NEW.is_deleted, false) = false
  THEN
    UPDATE public.webchat_conversations
       SET unread_count_agents = COALESCE(unread_count_agents, 0) + 1
     WHERE id = NEW.conversation_id
       AND (status IS NULL OR status::text <> 'closed');
    RETURN NEW;
  END IF;

  IF NEW.direction = 'outbound'
     AND COALESCE(NEW.sender_type, '') IN ('agent','operator','admin','user','human')
  THEN
    UPDATE public.webchat_conversations
       SET unread_count_agents = 0
     WHERE id = NEW.conversation_id
       AND COALESCE(unread_count_agents, 0) > 0;
  END IF;

  RETURN NEW;
END;
$$;