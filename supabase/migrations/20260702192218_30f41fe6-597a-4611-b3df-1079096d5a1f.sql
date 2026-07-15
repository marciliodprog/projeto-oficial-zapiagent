
-- ============================================================
-- MÓDULO JORNADA DO LEAD
-- ============================================================

-- Enum de tipos de evento (aceita ALTER TYPE ADD VALUE futuramente)
DO $$ BEGIN
  CREATE TYPE public.journey_event_type AS ENUM (
    'lead_created','lead_updated','lead_assigned','lead_transferred',
    'lead_archived','lead_reopened','lead_qualified','lead_disqualified',
    'temperature_changed','tag_added','tag_removed','field_changed',
    'first_conversation','first_message_in','first_reply_out',
    'human_reply','ai_reply','conversation_accepted','conversation_transferred',
    'conversation_archived','conversation_reopened','message_scheduled',
    'message_sent','message_read','call_made',
    'opportunity_created','pipeline_changed','stage_changed',
    'meeting_created','meeting_confirmed','meeting_cancelled',
    'task_created','task_completed','followup_created','followup_done',
    'proposal_created','proposal_sent','proposal_viewed',
    'pix_generated','pix_paid','checkout_created',
    'sale_completed','post_sale_started','customer_lost','customer_reactivated'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.journey_event_category AS ENUM (
    'origin','contact','attendance','qualification','opportunity',
    'meeting','proposal','negotiation','sale','post_sale','system'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ============================================================
-- Tabela principal
-- ============================================================
CREATE TABLE IF NOT EXISTS public.lead_journey_events (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  lead_id UUID REFERENCES public.leads(id) ON DELETE CASCADE,
  conversation_id UUID REFERENCES public.webchat_conversations(id) ON DELETE SET NULL,
  deal_id UUID REFERENCES public.deals(id) ON DELETE SET NULL,
  product_id UUID REFERENCES public.products(id) ON DELETE SET NULL,
  pipeline_stage_id UUID REFERENCES public.pipeline_stages(id) ON DELETE SET NULL,
  user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  agent_id UUID REFERENCES public.product_agents(id) ON DELETE SET NULL,
  event_type public.journey_event_type NOT NULL,
  event_category public.journey_event_category NOT NULL DEFAULT 'system',
  channel TEXT,
  source TEXT,
  title TEXT,
  description TEXT,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  previous_event_id UUID,
  time_since_previous_seconds INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_journey_org_lead_time
  ON public.lead_journey_events (organization_id, lead_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_journey_org_type_time
  ON public.lead_journey_events (organization_id, event_type, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_journey_org_channel
  ON public.lead_journey_events (organization_id, channel);
CREATE INDEX IF NOT EXISTS idx_journey_org_time
  ON public.lead_journey_events (organization_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_journey_org_category_time
  ON public.lead_journey_events (organization_id, event_category, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_journey_conversation
  ON public.lead_journey_events (conversation_id) WHERE conversation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_journey_payload_gin
  ON public.lead_journey_events USING GIN (payload);

-- ============================================================
-- GRANTs (RLS abaixo restringe leitura por lead)
-- ============================================================
GRANT SELECT, INSERT ON public.lead_journey_events TO authenticated;
GRANT ALL ON public.lead_journey_events TO service_role;

ALTER TABLE public.lead_journey_events ENABLE ROW LEVEL SECURITY;

-- SELECT: mesma visibilidade que o lead relacionado (ou org, se não houver lead)
CREATE POLICY "journey select via lead visibility"
  ON public.lead_journey_events FOR SELECT
  USING (
    public.is_super_admin(auth.uid())
    OR (
      organization_id = public.get_user_organization(auth.uid())
      AND (
        lead_id IS NULL AND (
          public.has_role(auth.uid(),'admin'::app_role)
          OR public.has_role(auth.uid(),'manager'::app_role)
        )
      )
      OR EXISTS (
        SELECT 1 FROM public.leads l
        WHERE l.id = lead_journey_events.lead_id
      )
    )
  );

-- INSERT: qualquer usuário autenticado da organização pode registrar eventos da própria org
CREATE POLICY "journey insert in own org"
  ON public.lead_journey_events FOR INSERT
  WITH CHECK (
    organization_id = public.get_user_organization(auth.uid())
    OR public.is_super_admin(auth.uid())
  );

-- ============================================================
-- Trigger BEFORE INSERT: calcula previous_event_id + delta
-- ============================================================
CREATE OR REPLACE FUNCTION public.fill_journey_previous_event()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  prev RECORD;
BEGIN
  IF NEW.lead_id IS NOT NULL THEN
    SELECT id, occurred_at INTO prev
    FROM public.lead_journey_events
    WHERE lead_id = NEW.lead_id AND occurred_at <= NEW.occurred_at
    ORDER BY occurred_at DESC, created_at DESC
    LIMIT 1;

    IF prev.id IS NOT NULL THEN
      NEW.previous_event_id := prev.id;
      NEW.time_since_previous_seconds := GREATEST(0, EXTRACT(EPOCH FROM (NEW.occurred_at - prev.occurred_at))::INT);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_fill_journey_previous
  BEFORE INSERT ON public.lead_journey_events
  FOR EACH ROW EXECUTE FUNCTION public.fill_journey_previous_event();

-- ============================================================
-- Helper interno para gravação segura (best-effort)
-- ============================================================
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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  IF p_org IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.lead_journey_events (
    organization_id, lead_id, conversation_id, deal_id, product_id,
    pipeline_stage_id, user_id, agent_id, event_type, event_category,
    channel, source, title, description, payload, occurred_at
  ) VALUES (
    p_org, p_lead, p_conversation, p_deal, p_product,
    p_stage, p_user, p_agent, p_type, p_category,
    p_channel, p_source, p_title, p_description, COALESCE(p_payload,'{}'::jsonb), p_occurred
  ) RETURNING id INTO v_id;
  RETURN v_id;
EXCEPTION WHEN OTHERS THEN
  -- best-effort: não bloqueia operação principal
  RETURN NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION public.log_journey_event TO authenticated, service_role;

-- ============================================================
-- Trigger: leads
-- ============================================================
CREATE OR REPLACE FUNCTION public.journey_on_lead_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.log_journey_event(
      NEW.organization_id, NEW.id, 'lead_created', 'origin',
      NEW.lead_channel, COALESCE(NEW.lead_origin, NEW.source, NEW.utm_source),
      'Lead criado', NEW.name,
      jsonb_build_object(
        'utm_source', NEW.utm_source, 'utm_medium', NEW.utm_medium,
        'utm_campaign', NEW.utm_campaign, 'utm_term', NEW.utm_term,
        'utm_content', NEW.utm_content, 'referrer', NEW.referrer_url,
        'landing_page', NEW.landing_page, 'phone', NEW.phone, 'email', NEW.email
      ),
      NULL, NULL, NEW.product_id, NEW.current_stage_id, NEW.assigned_to, NULL, NEW.created_at
    );
    RETURN NEW;
  END IF;

  -- UPDATE
  IF NEW.assigned_to IS DISTINCT FROM OLD.assigned_to THEN
    PERFORM public.log_journey_event(
      NEW.organization_id, NEW.id,
      CASE WHEN OLD.assigned_to IS NULL THEN 'lead_assigned' ELSE 'lead_transferred' END,
      'attendance', NULL, NULL,
      CASE WHEN OLD.assigned_to IS NULL THEN 'Lead atribuído' ELSE 'Lead transferido' END,
      NULL,
      jsonb_build_object('from', OLD.assigned_to, 'to', NEW.assigned_to,
                         'reason', NEW.transfer_reason),
      NULL, NULL, NEW.product_id, NEW.current_stage_id, NEW.assigned_to, NULL, now()
    );
  END IF;

  IF NEW.temperature IS DISTINCT FROM OLD.temperature THEN
    PERFORM public.log_journey_event(
      NEW.organization_id, NEW.id, 'temperature_changed', 'qualification',
      NULL, NULL, 'Temperatura alterada',
      OLD.temperature::text || ' → ' || NEW.temperature::text,
      jsonb_build_object('from', OLD.temperature, 'to', NEW.temperature),
      NULL, NULL, NEW.product_id, NEW.current_stage_id, NEW.assigned_to, NULL, now()
    );
  END IF;

  IF NEW.tags IS DISTINCT FROM OLD.tags THEN
    PERFORM public.log_journey_event(
      NEW.organization_id, NEW.id, 'tag_added', 'qualification',
      NULL, NULL, 'Etiquetas alteradas', NULL,
      jsonb_build_object('old', OLD.tags, 'new', NEW.tags),
      NULL, NULL, NEW.product_id, NEW.current_stage_id, NEW.assigned_to, NULL, now()
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journey_leads ON public.leads;
CREATE TRIGGER trg_journey_leads
  AFTER INSERT OR UPDATE ON public.leads
  FOR EACH ROW EXECUTE FUNCTION public.journey_on_lead_change();

-- ============================================================
-- Trigger: lead_stage_history
-- ============================================================
CREATE OR REPLACE FUNCTION public.journey_on_stage_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lead RECORD;
  v_stage RECORD;
BEGIN
  SELECT organization_id, product_id, assigned_to INTO v_lead
    FROM public.leads WHERE id = NEW.lead_id;
  IF v_lead.organization_id IS NULL THEN RETURN NEW; END IF;

  SELECT name, color, is_won, is_lost, order_index INTO v_stage
    FROM public.pipeline_stages WHERE id = NEW.stage_id;

  PERFORM public.log_journey_event(
    v_lead.organization_id, NEW.lead_id,
    CASE
      WHEN v_stage.is_won THEN 'sale_completed'
      WHEN v_stage.is_lost THEN 'customer_lost'
      ELSE 'stage_changed'
    END,
    CASE
      WHEN v_stage.is_won THEN 'sale'
      WHEN v_stage.is_lost THEN 'negotiation'
      ELSE 'opportunity'
    END,
    NULL, NULL,
    COALESCE(v_stage.name,'Mudança de etapa'),
    NULL,
    jsonb_build_object('stage_name', v_stage.name, 'order', v_stage.order_index,
                       'is_won', v_stage.is_won, 'is_lost', v_stage.is_lost),
    NULL, NULL, v_lead.product_id, NEW.stage_id, v_lead.assigned_to, NULL,
    COALESCE(NEW.entered_at, now())
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journey_stage ON public.lead_stage_history;
CREATE TRIGGER trg_journey_stage
  AFTER INSERT ON public.lead_stage_history
  FOR EACH ROW EXECUTE FUNCTION public.journey_on_stage_change();

-- ============================================================
-- Trigger: deals
-- ============================================================
CREATE OR REPLACE FUNCTION public.journey_on_deal_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.log_journey_event(
      NEW.organization_id, NEW.lead_id, 'opportunity_created', 'opportunity',
      NULL, NULL, 'Oportunidade criada', NULL,
      jsonb_build_object('deal_value', NEW.deal_value, 'status', NEW.status),
      NULL, NEW.id, NULL, NULL, NEW.seller_id, NULL, NEW.created_at
    );
    RETURN NEW;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status = 'won' THEN
      PERFORM public.log_journey_event(NEW.organization_id, NEW.lead_id,
        'sale_completed','sale',NULL,NULL,'Venda concluída',NULL,
        jsonb_build_object('deal_value',NEW.deal_value),
        NULL,NEW.id,NULL,NULL,NEW.seller_id,NULL,now());
    ELSIF NEW.status = 'lost' OR NEW.status = 'cancelled' THEN
      PERFORM public.log_journey_event(NEW.organization_id, NEW.lead_id,
        'customer_lost','negotiation',NULL,NULL,'Cliente perdido',NULL,
        jsonb_build_object('status',NEW.status),
        NULL,NEW.id,NULL,NULL,NEW.seller_id,NULL,now());
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journey_deals ON public.deals;
CREATE TRIGGER trg_journey_deals
  AFTER INSERT OR UPDATE ON public.deals
  FOR EACH ROW EXECUTE FUNCTION public.journey_on_deal_change();

-- ============================================================
-- Trigger: calendar_events (reuniões)
-- ============================================================
CREATE OR REPLACE FUNCTION public.journey_on_calendar_event()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.lead_id IS NULL THEN RETURN NEW; END IF;

  IF TG_OP = 'INSERT' THEN
    PERFORM public.log_journey_event(
      NEW.organization_id, NEW.lead_id, 'meeting_created', 'meeting',
      NULL, NULL, 'Reunião agendada', NEW.title,
      jsonb_build_object('event_type', NEW.event_type, 'status', NEW.status,
                         'start', NEW.start_time),
      NULL, NULL, NULL, NULL, NEW.user_id, NULL, NEW.created_at
    );
  ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status = 'confirmed' THEN
      PERFORM public.log_journey_event(NEW.organization_id, NEW.lead_id,
        'meeting_confirmed','meeting',NULL,NULL,'Reunião confirmada',NEW.title,
        jsonb_build_object('start',NEW.start_time),NULL,NULL,NULL,NULL,NEW.user_id,NULL,now());
    ELSIF NEW.status = 'cancelled' THEN
      PERFORM public.log_journey_event(NEW.organization_id, NEW.lead_id,
        'meeting_cancelled','meeting',NULL,NULL,'Reunião cancelada',NEW.title,
        '{}'::jsonb,NULL,NULL,NULL,NULL,NEW.user_id,NULL,now());
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journey_calendar ON public.calendar_events;
CREATE TRIGGER trg_journey_calendar
  AFTER INSERT OR UPDATE ON public.calendar_events
  FOR EACH ROW EXECUTE FUNCTION public.journey_on_calendar_event();

-- ============================================================
-- Trigger: tasks
-- ============================================================
CREATE OR REPLACE FUNCTION public.journey_on_task_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org UUID;
BEGIN
  IF NEW.lead_id IS NULL THEN RETURN NEW; END IF;
  SELECT organization_id INTO v_org FROM public.leads WHERE id = NEW.lead_id;
  IF v_org IS NULL THEN RETURN NEW; END IF;

  IF TG_OP = 'INSERT' THEN
    PERFORM public.log_journey_event(
      v_org, NEW.lead_id,
      CASE WHEN NEW.type = 'follow_up' THEN 'followup_created' ELSE 'task_created' END,
      'attendance', NULL, NULL,
      COALESCE(NEW.title,'Tarefa criada'), NEW.description,
      jsonb_build_object('type',NEW.type,'due_date',NEW.due_date),
      NULL, NULL, NULL, NULL, NEW.user_id, NULL, NEW.created_at
    );
  ELSIF NEW.status IS DISTINCT FROM OLD.status AND NEW.status = 'completed' THEN
    PERFORM public.log_journey_event(
      v_org, NEW.lead_id,
      CASE WHEN NEW.type = 'follow_up' THEN 'followup_done' ELSE 'task_completed' END,
      'attendance', NULL, NULL,
      COALESCE(NEW.title,'Tarefa concluída'), NULL,
      jsonb_build_object('type',NEW.type),
      NULL, NULL, NULL, NULL, NEW.user_id, NULL, now()
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journey_tasks ON public.tasks;
CREATE TRIGGER trg_journey_tasks
  AFTER INSERT OR UPDATE ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.journey_on_task_change();

-- ============================================================
-- Trigger: webchat_conversations
-- ============================================================
CREATE OR REPLACE FUNCTION public.journey_on_conversation_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.log_journey_event(
      NEW.organization_id, NEW.lead_id, 'first_conversation', 'contact',
      NEW.channel, NEW.channel, 'Conversa iniciada', NULL,
      jsonb_build_object('channel',NEW.channel,'status',NEW.status),
      NEW.id, NULL, NULL, NULL, NEW.assigned_user_id, NULL, NEW.created_at
    );
    RETURN NEW;
  END IF;

  IF NEW.assigned_user_id IS DISTINCT FROM OLD.assigned_user_id
     AND NEW.assigned_user_id IS NOT NULL THEN
    PERFORM public.log_journey_event(
      NEW.organization_id, NEW.lead_id,
      CASE WHEN OLD.assigned_user_id IS NULL THEN 'conversation_accepted'
           ELSE 'conversation_transferred' END,
      'attendance', NEW.channel, NULL,
      CASE WHEN OLD.assigned_user_id IS NULL
           THEN 'Conversa aceita' ELSE 'Conversa transferida' END,
      NULL,
      jsonb_build_object('from',OLD.assigned_user_id,'to',NEW.assigned_user_id),
      NEW.id, NULL, NULL, NULL, NEW.assigned_user_id, NULL, now()
    );
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status::text = 'archived' OR NEW.status::text = 'closed' THEN
      PERFORM public.log_journey_event(NEW.organization_id, NEW.lead_id,
        'conversation_archived','attendance',NEW.channel,NULL,
        'Conversa arquivada',NULL,jsonb_build_object('status',NEW.status),
        NEW.id,NULL,NULL,NULL,NEW.assigned_user_id,NULL,now());
    ELSIF OLD.status::text IN ('archived','closed')
          AND NEW.status::text NOT IN ('archived','closed') THEN
      PERFORM public.log_journey_event(NEW.organization_id, NEW.lead_id,
        'conversation_reopened','attendance',NEW.channel,NULL,
        'Conversa reaberta',NULL,'{}'::jsonb,
        NEW.id,NULL,NULL,NULL,NEW.assigned_user_id,NULL,now());
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journey_conversations ON public.webchat_conversations;
CREATE TRIGGER trg_journey_conversations
  AFTER INSERT OR UPDATE ON public.webchat_conversations
  FOR EACH ROW EXECUTE FUNCTION public.journey_on_conversation_change();

-- ============================================================
-- Trigger: webchat_messages (só a 1ª entrada e 1ª saída por conversa
-- + eventos ai_reply/human_reply para respostas subsequentes leves)
-- ============================================================
CREATE OR REPLACE FUNCTION public.journey_on_message_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conv RECORD;
  v_has_inbound BOOLEAN;
  v_has_outbound BOOLEAN;
BEGIN
  SELECT organization_id, lead_id, channel INTO v_conv
    FROM public.webchat_conversations WHERE id = NEW.conversation_id;
  IF v_conv.organization_id IS NULL THEN RETURN NEW; END IF;

  -- verifica se é a primeira do tipo nessa conversa (evita floods)
  IF NEW.direction = 'inbound' THEN
    SELECT EXISTS(
      SELECT 1 FROM public.webchat_messages
      WHERE conversation_id = NEW.conversation_id
        AND direction = 'inbound' AND id <> NEW.id
    ) INTO v_has_inbound;
    IF NOT v_has_inbound THEN
      PERFORM public.log_journey_event(
        v_conv.organization_id, v_conv.lead_id, 'first_message_in','contact',
        v_conv.channel, NULL, 'Primeira mensagem do lead',
        LEFT(COALESCE(NEW.content,''), 200), '{}'::jsonb,
        NEW.conversation_id, NULL, NULL, NULL, NULL, NULL, NEW.created_at
      );
    END IF;
  ELSIF NEW.direction = 'outbound' THEN
    SELECT EXISTS(
      SELECT 1 FROM public.webchat_messages
      WHERE conversation_id = NEW.conversation_id
        AND direction = 'outbound' AND id <> NEW.id
    ) INTO v_has_outbound;
    IF NOT v_has_outbound THEN
      PERFORM public.log_journey_event(
        v_conv.organization_id, v_conv.lead_id, 'first_reply_out','contact',
        v_conv.channel, NULL, 'Primeira resposta enviada',
        LEFT(COALESCE(NEW.content,''), 200),
        jsonb_build_object('sender_type', NEW.sender_type),
        NEW.conversation_id, NULL, NULL, NULL, NEW.sender_id, NULL, NEW.created_at
      );
    ELSE
      -- respostas subsequentes: humano vs IA
      IF NEW.sender_type = 'bot' THEN
        PERFORM public.log_journey_event(
          v_conv.organization_id, v_conv.lead_id, 'ai_reply','attendance',
          v_conv.channel, NULL, 'Resposta IA',
          LEFT(COALESCE(NEW.content,''), 200), '{}'::jsonb,
          NEW.conversation_id, NULL, NULL, NULL, NULL, NULL, NEW.created_at
        );
      ELSIF NEW.sender_type = 'agent' THEN
        PERFORM public.log_journey_event(
          v_conv.organization_id, v_conv.lead_id, 'human_reply','attendance',
          v_conv.channel, NULL, 'Resposta humana',
          LEFT(COALESCE(NEW.content,''), 200), '{}'::jsonb,
          NEW.conversation_id, NULL, NULL, NULL, NEW.sender_id, NULL, NEW.created_at
        );
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journey_messages ON public.webchat_messages;
CREATE TRIGGER trg_journey_messages
  AFTER INSERT ON public.webchat_messages
  FOR EACH ROW EXECUTE FUNCTION public.journey_on_message_insert();

-- ============================================================
-- View de touchpoints agregados por canal
-- ============================================================
CREATE OR REPLACE VIEW public.lead_journey_touchpoints_v
WITH (security_invoker=on) AS
SELECT
  organization_id,
  lead_id,
  COALESCE(channel, source, 'other') AS channel,
  COUNT(*)::INT AS touches,
  MIN(occurred_at) AS first_touch_at,
  MAX(occurred_at) AS last_touch_at
FROM public.lead_journey_events
WHERE COALESCE(channel, source) IS NOT NULL
GROUP BY organization_id, lead_id, COALESCE(channel, source, 'other');

GRANT SELECT ON public.lead_journey_touchpoints_v TO authenticated, service_role;
