
CREATE OR REPLACE FUNCTION public.sync_conversation_unread_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Mensagem do visitante chegando → incrementa contador
  IF NEW.direction = 'inbound'
     AND COALESCE(NEW.sender_type, '') = 'visitor'
     AND COALESCE(NEW.is_deleted, false) = false
  THEN
    UPDATE public.webchat_conversations
       SET unread_count_agents = COALESCE(unread_count_agents, 0) + 1
     WHERE id = NEW.conversation_id
       AND COALESCE(status, '') <> 'closed';
    RETURN NEW;
  END IF;

  -- Resposta do atendente humano (não bot) → zera contador
  IF NEW.direction = 'outbound'
     AND COALESCE(NEW.sender_type, '') IN ('agent', 'operator', 'admin', 'user', 'human')
  THEN
    UPDATE public.webchat_conversations
       SET unread_count_agents = 0
     WHERE id = NEW.conversation_id
       AND COALESCE(unread_count_agents, 0) > 0;
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_conversation_unread_count ON public.webchat_messages;
CREATE TRIGGER trg_sync_conversation_unread_count
AFTER INSERT ON public.webchat_messages
FOR EACH ROW
EXECUTE FUNCTION public.sync_conversation_unread_count();
