-- Função que agenda/reseta o follow-up automático quando o agente envia mensagem
CREATE OR REPLACE FUNCTION public.fn_schedule_agent_followup_on_bot_message()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conv RECORD;
  v_agent RECORD;
  v_intervals integer[];
  v_max int;
  v_first_delay_min int;
  v_next_at timestamptz;
  v_existing_id uuid;
  v_lead RECORD;
BEGIN
  -- Só interessa mensagem outbound do agente/bot
  IF NEW.sender_type NOT IN ('bot', 'agent') OR NEW.direction <> 'outbound' THEN
    RETURN NEW;
  END IF;

  -- Busca conversa + lead + agente vinculado
  SELECT id, organization_id, lead_id, current_agent_id, status, product_id
    INTO v_conv
  FROM public.webchat_conversations
  WHERE id = NEW.conversation_id;

  IF v_conv.lead_id IS NULL OR v_conv.current_agent_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Não agenda se conversa já está em mãos humanas
  IF v_conv.status IN ('human_active', 'waiting_human', 'closed', 'lost') THEN
    RETURN NEW;
  END IF;

  SELECT id, followup_enabled, followup_max_attempts, followup_intervals_minutes,
         followup_extra_instructions, followup_channels, followup_attempt_hints
    INTO v_agent
  FROM public.product_agents
  WHERE id = v_conv.current_agent_id;

  IF v_agent IS NULL OR v_agent.followup_enabled IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  v_intervals := COALESCE(NULLIF(v_agent.followup_intervals_minutes, '{}'), ARRAY[15,120,1440]::int[]);
  v_max := COALESCE(v_agent.followup_max_attempts, array_length(v_intervals, 1));
  v_first_delay_min := v_intervals[1];
  v_next_at := now() + (v_first_delay_min || ' minutes')::interval;

  -- Snapshot do lead
  SELECT name, email, phone INTO v_lead FROM public.leads WHERE id = v_conv.lead_id;

  -- Procura entrada existente (agendada/aguardando)
  SELECT id INTO v_existing_id
  FROM public.ai_outreach_queue
  WHERE lead_id = v_conv.lead_id
    AND agent_id = v_conv.current_agent_id
    AND status IN ('scheduled', 'sent')
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    UPDATE public.ai_outreach_queue SET
      status = 'sent',
      followup_enabled = true,
      followups_sent = 0,
      max_followups = v_max,
      followup_intervals_minutes = v_intervals[1:v_max],
      followup_attempt_hints = COALESCE(v_agent.followup_attempt_hints, '[]'::jsonb),
      followup_kind = 'agent_silence',
      next_followup_at = v_next_at,
      conversation_id = NEW.conversation_id,
      extra_context = v_agent.followup_extra_instructions,
      lead_data = jsonb_build_object('name', v_lead.name, 'email', v_lead.email, 'phone', v_lead.phone)
    WHERE id = v_existing_id;
  ELSE
    INSERT INTO public.ai_outreach_queue (
      organization_id, lead_id, conversation_id, agent_id, product_id,
      objective, extra_context, lead_data,
      status, followup_enabled, followups_sent, max_followups,
      followup_interval_hours, followup_intervals_minutes, followup_attempt_hints,
      followup_kind, next_followup_at
    ) VALUES (
      v_conv.organization_id, v_conv.lead_id, NEW.conversation_id, v_conv.current_agent_id, v_conv.product_id,
      'Retomar contato após silêncio do lead', v_agent.followup_extra_instructions,
      jsonb_build_object('name', v_lead.name, 'email', v_lead.email, 'phone', v_lead.phone),
      'sent', true, 0, v_max,
      GREATEST(1, ROUND(v_first_delay_min::numeric / 60)::int),
      v_intervals[1:v_max],
      COALESCE(v_agent.followup_attempt_hints, '[]'::jsonb),
      'agent_silence', v_next_at
    );
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Nunca quebra o envio da mensagem por causa do agendamento
  RAISE WARNING 'fn_schedule_agent_followup_on_bot_message error: %', SQLERRM;
  RETURN NEW;
END;
$$;

-- Cancela follow-ups pendentes quando o lead responde
CREATE OR REPLACE FUNCTION public.fn_cancel_agent_followup_on_visitor_reply()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lead_id uuid;
BEGIN
  IF NEW.sender_type <> 'visitor' OR NEW.direction <> 'inbound' THEN
    RETURN NEW;
  END IF;

  SELECT lead_id INTO v_lead_id FROM public.webchat_conversations WHERE id = NEW.conversation_id;
  IF v_lead_id IS NULL THEN RETURN NEW; END IF;

  UPDATE public.ai_outreach_queue
     SET status = 'replied', followup_enabled = false, next_followup_at = NULL
   WHERE lead_id = v_lead_id
     AND followup_kind = 'agent_silence'
     AND status IN ('scheduled', 'sent');

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'fn_cancel_agent_followup_on_visitor_reply error: %', SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_schedule_agent_followup ON public.webchat_messages;
CREATE TRIGGER trg_schedule_agent_followup
AFTER INSERT ON public.webchat_messages
FOR EACH ROW EXECUTE FUNCTION public.fn_schedule_agent_followup_on_bot_message();

DROP TRIGGER IF EXISTS trg_cancel_agent_followup_on_reply ON public.webchat_messages;
CREATE TRIGGER trg_cancel_agent_followup_on_reply
AFTER INSERT ON public.webchat_messages
FOR EACH ROW EXECUTE FUNCTION public.fn_cancel_agent_followup_on_visitor_reply();