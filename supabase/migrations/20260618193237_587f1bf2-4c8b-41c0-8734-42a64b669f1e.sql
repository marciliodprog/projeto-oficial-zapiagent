
-- ============================================================================
-- Follow-up Régua Progressiva: nunca reinicia, só avança
-- ============================================================================

-- 1. Novas colunas em ai_outreach_queue
ALTER TABLE public.ai_outreach_queue
  ADD COLUMN IF NOT EXISTS last_attempt_executed integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS attempts_completed integer[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS ruler_closed boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS last_interaction_at timestamptz;

-- 2. Saneamento: popular novos campos a partir do estado atual
UPDATE public.ai_outreach_queue
SET last_attempt_executed = COALESCE(followups_sent, 0),
    attempts_completed = CASE
      WHEN COALESCE(followups_sent, 0) > 0 THEN
        (SELECT array_agg(g) FROM generate_series(1, followups_sent) g)
      ELSE '{}'::int[]
    END,
    ruler_closed = (COALESCE(followups_sent, 0) >= COALESCE(max_followups, 3)),
    last_interaction_at = COALESCE(last_outreach_at, created_at)
WHERE last_interaction_at IS NULL;

-- Encerra linhas presas em 'processing' há mais de 30 min
UPDATE public.ai_outreach_queue
SET status = 'completed',
    followup_enabled = false,
    next_followup_at = NULL,
    ruler_closed = true,
    error_message = COALESCE(error_message, 'stuck_processing_cleanup')
WHERE status = 'processing'
  AND COALESCE(last_outreach_at, created_at) < now() - interval '30 minutes';

-- 3. Índice parcial otimizado para o cron
DROP INDEX IF EXISTS public.idx_ai_outreach_queue_followup;
CREATE INDEX IF NOT EXISTS idx_ai_outreach_queue_due
  ON public.ai_outreach_queue (next_followup_at)
  WHERE status IN ('sent','scheduled')
    AND followup_enabled = true
    AND ruler_closed = false;

-- 4. Trigger do agente: NUNCA reinicia contador. Só atualiza last_interaction_at
--    e recalcula next_followup_at se ainda houver tentativa pendente.
CREATE OR REPLACE FUNCTION public.fn_schedule_agent_followup_on_bot_message()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conv RECORD;
  v_agent RECORD;
  v_intervals integer[];
  v_max int;
  v_next_attempt int;
  v_delay_min int;
  v_next_at timestamptz;
  v_existing RECORD;
  v_lead RECORD;
BEGIN
  IF NEW.sender_type NOT IN ('bot', 'agent') OR NEW.direction <> 'outbound' THEN
    RETURN NEW;
  END IF;

  -- Mensagens do próprio cron de follow-up: não reagenda
  IF NEW.metadata IS NOT NULL
     AND NEW.metadata ? 'origin'
     AND NEW.metadata->>'origin' = 'ai_followup' THEN
    -- Apenas registra interação na linha ativa
    UPDATE public.ai_outreach_queue
       SET last_interaction_at = now()
     WHERE conversation_id = NEW.conversation_id
       AND status IN ('sent','scheduled','processing')
       AND ruler_closed = false;
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
  v_max := LEAST(
    COALESCE(v_agent.followup_max_attempts, array_length(v_intervals, 1)),
    array_length(v_intervals, 1)
  );

  SELECT name, email, phone INTO v_lead FROM public.leads WHERE id = v_conv.lead_id;

  -- Procura linha ativa (mesmo ciclo da conversa)
  SELECT id, last_attempt_executed, ruler_closed, followups_sent
    INTO v_existing
  FROM public.ai_outreach_queue
  WHERE lead_id = v_conv.lead_id
    AND agent_id = v_conv.current_agent_id
    AND status IN ('scheduled', 'sent', 'processing')
    AND ruler_closed = false
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_existing.id IS NOT NULL THEN
    -- AVANÇA (não reinicia): próxima tentativa = last_attempt_executed + 1
    v_next_attempt := v_existing.last_attempt_executed + 1;
    IF v_next_attempt > v_max THEN
      -- Régua já esgotada — encerra
      UPDATE public.ai_outreach_queue
         SET ruler_closed = true,
             status = 'completed',
             followup_enabled = false,
             next_followup_at = NULL,
             last_interaction_at = now()
       WHERE id = v_existing.id;
      RETURN NEW;
    END IF;

    v_delay_min := v_intervals[v_next_attempt];
    v_next_at := now() + (v_delay_min || ' minutes')::interval;

    UPDATE public.ai_outreach_queue SET
      status = 'sent',
      followup_enabled = true,
      max_followups = v_max,
      followup_intervals_minutes = v_intervals[1:v_max],
      followup_attempt_hints = COALESCE(v_agent.followup_attempt_hints, '[]'::jsonb),
      followup_kind = 'agent_silence',
      next_followup_at = v_next_at,
      last_interaction_at = now(),
      conversation_id = NEW.conversation_id,
      extra_context = v_agent.followup_extra_instructions,
      lead_data = jsonb_build_object('name', v_lead.name, 'email', v_lead.email, 'phone', v_lead.phone)
    WHERE id = v_existing.id;
  ELSE
    -- Nova régua (ciclo novo de conversa)
    v_delay_min := v_intervals[1];
    v_next_at := now() + (v_delay_min || ' minutes')::interval;

    INSERT INTO public.ai_outreach_queue (
      organization_id, lead_id, conversation_id, agent_id, product_id,
      objective, extra_context, lead_data, status, followup_enabled,
      followup_intervals_minutes, followup_attempt_hints, followup_kind,
      max_followups, followups_sent, last_attempt_executed, attempts_completed,
      ruler_closed, next_followup_at, last_interaction_at
    ) VALUES (
      v_conv.organization_id, v_conv.lead_id, NEW.conversation_id, v_conv.current_agent_id, v_conv.product_id,
      'Retomar contato após silêncio do lead', v_agent.followup_extra_instructions,
      jsonb_build_object('name', v_lead.name, 'email', v_lead.email, 'phone', v_lead.phone),
      'sent', true,
      v_intervals[1:v_max], COALESCE(v_agent.followup_attempt_hints, '[]'::jsonb), 'agent_silence',
      v_max, 0, 0, '{}'::int[],
      false, v_next_at, now()
    )
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'fn_schedule_agent_followup_on_bot_message error: %', SQLERRM;
  RETURN NEW;
END;
$$;

-- 5. Trigger da resposta do lead: NÃO cancela mais. Só avança o cronômetro
--    da próxima tentativa baseado em last_interaction_at = now().
CREATE OR REPLACE FUNCTION public.fn_cancel_agent_followup_on_visitor_reply()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lead_id uuid;
  v_row RECORD;
  v_intervals integer[];
  v_next_attempt int;
  v_delay_min int;
  v_next_at timestamptz;
BEGIN
  IF NEW.sender_type <> 'visitor' OR NEW.direction <> 'inbound' THEN
    RETURN NEW;
  END IF;

  SELECT lead_id INTO v_lead_id FROM public.webchat_conversations WHERE id = NEW.conversation_id;
  IF v_lead_id IS NULL THEN RETURN NEW; END IF;

  -- Para cada régua ativa do lead, avança o cronômetro (sem reiniciar)
  FOR v_row IN
    SELECT id, last_attempt_executed, max_followups, followup_intervals_minutes, ruler_closed
      FROM public.ai_outreach_queue
     WHERE lead_id = v_lead_id
       AND followup_kind = 'agent_silence'
       AND status IN ('scheduled','sent','processing')
       AND ruler_closed = false
  LOOP
    v_intervals := COALESCE(NULLIF(v_row.followup_intervals_minutes, '{}'), ARRAY[15,120,1440]::int[]);
    v_next_attempt := v_row.last_attempt_executed + 1;

    IF v_next_attempt > COALESCE(v_row.max_followups, array_length(v_intervals,1)) THEN
      UPDATE public.ai_outreach_queue
         SET ruler_closed = true, status = 'completed',
             followup_enabled = false, next_followup_at = NULL,
             last_interaction_at = now()
       WHERE id = v_row.id;
      CONTINUE;
    END IF;

    v_delay_min := v_intervals[v_next_attempt];
    v_next_at := now() + (v_delay_min || ' minutes')::interval;

    UPDATE public.ai_outreach_queue
       SET status = 'sent',
           next_followup_at = v_next_at,
           last_interaction_at = now()
     WHERE id = v_row.id;
  END LOOP;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'fn_cancel_agent_followup_on_visitor_reply error: %', SQLERRM;
  RETURN NEW;
END;
$$;

-- 6. Quando a conversa fecha → encerra régua definitivamente
CREATE OR REPLACE FUNCTION public.fn_close_followup_on_conversation_close()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status::text = 'closed' AND (OLD.status IS DISTINCT FROM NEW.status) THEN
    UPDATE public.ai_outreach_queue
       SET ruler_closed = true,
           status = 'completed',
           followup_enabled = false,
           next_followup_at = NULL
     WHERE conversation_id = NEW.id
       AND status IN ('sent','scheduled','processing')
       AND ruler_closed = false;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_close_followup_on_conv_close ON public.webchat_conversations;
CREATE TRIGGER trg_close_followup_on_conv_close
AFTER UPDATE OF status ON public.webchat_conversations
FOR EACH ROW EXECUTE FUNCTION public.fn_close_followup_on_conversation_close();
