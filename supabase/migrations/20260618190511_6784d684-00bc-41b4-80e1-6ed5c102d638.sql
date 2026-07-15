
CREATE OR REPLACE FUNCTION public.fn_schedule_agent_followup_on_bot_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  IF NEW.sender_type NOT IN ('bot', 'agent') OR NEW.direction <> 'outbound' THEN
    RETURN NEW;
  END IF;

  -- Mensagens enviadas pelo próprio cron de follow-up não devem reagendar nova fila.
  IF NEW.metadata IS NOT NULL
     AND NEW.metadata ? 'origin'
     AND NEW.metadata->>'origin' = 'ai_followup' THEN
    RETURN NEW;
  END IF;

  SELECT id, organization_id, lead_id, current_agent_id, status, product_id
    INTO v_conv
  FROM public.webchat_conversations
  WHERE id = NEW.conversation_id;

  IF v_conv.lead_id IS NULL OR v_conv.current_agent_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF v_conv.status::text IN ('human_active', 'waiting_human', 'closed') THEN
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

  SELECT name, email, phone INTO v_lead FROM public.leads WHERE id = v_conv.lead_id;

  -- Inclui 'processing' para não criar linhas duplicadas durante envio em andamento.
  SELECT id INTO v_existing_id
  FROM public.ai_outreach_queue
  WHERE lead_id = v_conv.lead_id
    AND agent_id = v_conv.current_agent_id
    AND status IN ('scheduled', 'sent', 'processing')
  ORDER BY created_at DESC
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
  RAISE WARNING 'fn_schedule_agent_followup_on_bot_message error: %', SQLERRM;
  RETURN NEW;
END;
$function$;

-- Saneamento: itens 'processing' antigos viram completed.
UPDATE public.ai_outreach_queue
SET status = 'completed', followup_enabled = false, next_followup_at = NULL
WHERE status = 'processing'
  AND created_at < now() - interval '30 minutes';

-- Saneamento: para cada (lead_id, agent_id), manter apenas a linha ativa mais recente;
-- as demais linhas em 'sent'/'scheduled' são fechadas.
WITH ranked AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY lead_id, agent_id
           ORDER BY created_at DESC
         ) AS rn
  FROM public.ai_outreach_queue
  WHERE status IN ('sent','scheduled')
)
UPDATE public.ai_outreach_queue q
SET status = 'completed', followup_enabled = false, next_followup_at = NULL
FROM ranked r
WHERE q.id = r.id AND r.rn > 1;
