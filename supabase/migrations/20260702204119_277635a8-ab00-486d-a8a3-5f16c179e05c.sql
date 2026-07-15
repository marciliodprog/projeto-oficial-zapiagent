-- =========================================================
-- 1. Handoff IA ↔ Humano  (agent_handoff_history)
-- =========================================================
CREATE OR REPLACE FUNCTION public.journey_on_agent_handoff()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_type public.journey_event_type;
BEGIN
  -- Convenção: se to_agent_id é null e from_agent_id não, IA devolveu para humano
  IF NEW.to_agent_id IS NULL AND NEW.from_agent_id IS NOT NULL THEN
    v_type := 'ai_handoff';
  ELSIF NEW.to_agent_id IS NOT NULL AND NEW.from_agent_id IS NULL THEN
    v_type := 'human_handoff';
  ELSE
    v_type := 'ai_handoff';
  END IF;

  PERFORM public.emit_journey_event(
    p_organization_id := NEW.organization_id,
    p_subject_type    := 'lead',
    p_subject_id      := NEW.lead_id,
    p_event_type      := v_type,
    p_event_category  := 'attendance'::public.journey_event_category,
    p_source_module   := 'agents',
    p_actor_type      := 'system'::public.journey_actor_type,
    p_actor_id        := NULL,
    p_channel         := NULL,
    p_payload         := jsonb_build_object(
                            'conversation_id', NEW.conversation_id,
                            'from_agent_id',   NEW.from_agent_id,
                            'to_agent_id',     NEW.to_agent_id,
                            'to_specialist_id', NEW.to_specialist_id,
                            'reason',          NEW.reason,
                            'rule_id',         NEW.rule_id,
                            'context',         NEW.context
                          ),
    p_lead_id         := NEW.lead_id,
    p_conversation_id := NEW.conversation_id,
    p_dedupe_key      := 'handoff:' || NEW.id::text
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journey_agent_handoff ON public.agent_handoff_history;
CREATE TRIGGER trg_journey_agent_handoff
  AFTER INSERT ON public.agent_handoff_history
  FOR EACH ROW EXECUTE FUNCTION public.journey_on_agent_handoff();

-- =========================================================
-- 2. Execução de ferramenta por agente IA (agent_action_logs)
-- =========================================================
CREATE OR REPLACE FUNCTION public.journey_on_agent_action()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Só publica se houver lead vinculado (jornada é por subject)
  IF NEW.lead_id IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM public.emit_journey_event(
    p_organization_id := NEW.organization_id,
    p_subject_type    := 'lead',
    p_subject_id      := NEW.lead_id,
    p_event_type      := 'agent_tool_executed',
    p_event_category  := 'attendance'::public.journey_event_category,
    p_source_module   := 'agents',
    p_actor_type      := 'ai'::public.journey_actor_type,
    p_actor_id        := NEW.agent_id,
    p_channel         := NULL,
    p_payload         := jsonb_build_object(
                            'action_type',   NEW.action_type,
                            'action_data',   NEW.action_data,
                            'result',        NEW.result,
                            'success',       NEW.success,
                            'error_message', NEW.error_message,
                            'product_id',    NEW.product_id,
                            'conversation_id', NEW.conversation_id
                          ),
    p_lead_id         := NEW.lead_id,
    p_conversation_id := NEW.conversation_id,
    p_dedupe_key      := 'agent_action:' || NEW.id::text
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journey_agent_action ON public.agent_action_logs;
CREATE TRIGGER trg_journey_agent_action
  AFTER INSERT ON public.agent_action_logs
  FOR EACH ROW EXECUTE FUNCTION public.journey_on_agent_action();

-- =========================================================
-- 3. Vendas Hotmart (hotmart_orders)
-- =========================================================
CREATE OR REPLACE FUNCTION public.journey_on_hotmart_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_type   public.journey_event_type;
  v_lead   uuid;
  v_status text := lower(coalesce(NEW.status, ''));
  v_event  text := lower(coalesce(NEW.event_type, ''));
BEGIN
  IF v_status IN ('approved','completed','paid','delivered') OR v_event = 'purchase_approved' THEN
    v_type := 'sale_completed';
  ELSIF v_status IN ('canceled','cancelled') OR v_event LIKE '%canceled%' OR v_event LIKE '%cancelled%' THEN
    v_type := 'sale_cancelled';
  ELSIF v_status IN ('refunded','chargeback') OR v_event LIKE '%refunded%' OR v_event LIKE '%chargeback%' THEN
    v_type := 'sale_refunded';
  ELSE
    RETURN NEW;
  END IF;

  -- Tenta amarrar em um lead pelo e-mail do comprador
  IF NEW.buyer_email IS NOT NULL THEN
    SELECT id INTO v_lead
      FROM public.leads
     WHERE organization_id = NEW.organization_id
       AND lower(email)    = lower(NEW.buyer_email)
     ORDER BY updated_at DESC NULLS LAST
     LIMIT 1;
  END IF;

  PERFORM public.emit_journey_event(
    p_organization_id := NEW.organization_id,
    p_subject_type    := CASE WHEN v_lead IS NOT NULL THEN 'lead' ELSE 'order' END,
    p_subject_id      := COALESCE(v_lead, NEW.id),
    p_event_type      := v_type,
    p_event_category  := 'sale'::public.journey_event_category,
    p_source_module   := 'hotmart',
    p_actor_type      := 'external'::public.journey_actor_type,
    p_actor_id        := NULL,
    p_channel         := 'hotmart',
    p_payload         := jsonb_build_object(
                            'transaction_id', NEW.transaction_id,
                            'product_id',     NEW.product_id,
                            'hotmart_product_id', NEW.hotmart_product_id,
                            'hotmart_product_name', NEW.hotmart_product_name,
                            'amount',         NEW.amount,
                            'currency',       NEW.currency,
                            'status',         NEW.status,
                            'event_type',     NEW.event_type,
                            'payment_method', NEW.payment_method,
                            'buyer_email',    NEW.buyer_email
                          ),
    p_lead_id         := v_lead,
    p_amount          := NEW.amount,
    p_currency        := NEW.currency,
    p_dedupe_key      := 'hotmart:' || NEW.transaction_id || ':' || coalesce(NEW.event_type, v_status)
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journey_hotmart_order ON public.hotmart_orders;
CREATE TRIGGER trg_journey_hotmart_order
  AFTER INSERT OR UPDATE OF status, event_type ON public.hotmart_orders
  FOR EACH ROW EXECUTE FUNCTION public.journey_on_hotmart_order();

-- =========================================================
-- 4. Vendas Cakto (cakto_orders)
-- =========================================================
CREATE OR REPLACE FUNCTION public.journey_on_cakto_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_type   public.journey_event_type;
  v_status text := lower(coalesce(NEW.status, ''));
BEGIN
  IF v_status IN ('paid','approved','completed','delivered') THEN
    v_type := 'sale_completed';
  ELSIF v_status IN ('canceled','cancelled') THEN
    v_type := 'sale_cancelled';
  ELSIF v_status IN ('refunded','chargeback') THEN
    v_type := 'sale_refunded';
  ELSE
    RETURN NEW;
  END IF;

  IF NEW.organization_id IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM public.emit_journey_event(
    p_organization_id := NEW.organization_id,
    p_subject_type    := CASE WHEN NEW.lead_id IS NOT NULL THEN 'lead' ELSE 'order' END,
    p_subject_id      := COALESCE(NEW.lead_id, NEW.id),
    p_event_type      := v_type,
    p_event_category  := 'sale'::public.journey_event_category,
    p_source_module   := NEW.provider,
    p_actor_type      := 'external'::public.journey_actor_type,
    p_actor_id        := NULL,
    p_channel         := NEW.provider,
    p_payload         := jsonb_build_object(
                            'cakto_id',       NEW.cakto_id,
                            'product_id',     NEW.product_id,
                            'product_name',   NEW.product_name,
                            'amount',         NEW.amount,
                            'status',         NEW.status,
                            'type',           NEW.type,
                            'offer_type',     NEW.offer_type,
                            'payment_method', NEW.payment_method,
                            'customer_email', NEW.customer_email
                          ),
    p_lead_id         := NEW.lead_id,
    p_amount          := NEW.amount,
    p_currency        := 'BRL',
    p_dedupe_key      := NEW.provider || ':' || NEW.cakto_id || ':' || v_status
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journey_cakto_order ON public.cakto_orders;
CREATE TRIGGER trg_journey_cakto_order
  AFTER INSERT OR UPDATE OF status ON public.cakto_orders
  FOR EACH ROW EXECUTE FUNCTION public.journey_on_cakto_order();

-- =========================================================
-- 5. Comissões (commissions)
-- =========================================================
CREATE OR REPLACE FUNCTION public.journey_on_commission()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lead uuid;
BEGIN
  SELECT lead_id INTO v_lead FROM public.deals WHERE id = NEW.deal_id;

  PERFORM public.emit_journey_event(
    p_organization_id := NEW.organization_id,
    p_subject_type    := CASE WHEN v_lead IS NOT NULL THEN 'lead' ELSE 'deal' END,
    p_subject_id      := COALESCE(v_lead, NEW.deal_id),
    p_event_type      := 'commission_created',
    p_event_category  := 'sale'::public.journey_event_category,
    p_source_module   := 'commissions',
    p_actor_type      := 'system'::public.journey_actor_type,
    p_actor_id        := NEW.user_id,
    p_channel         := NULL,
    p_payload         := jsonb_build_object(
                            'deal_id',            NEW.deal_id,
                            'user_id',            NEW.user_id,
                            'product_id',         NEW.product_id,
                            'amount',             NEW.amount,
                            'percentage_applied', NEW.percentage_applied,
                            'rule_id',            NEW.rule_id
                          ),
    p_lead_id         := v_lead,
    p_amount          := NEW.amount,
    p_currency        := 'BRL',
    p_dedupe_key      := 'commission:' || NEW.id::text
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journey_commission ON public.commissions;
CREATE TRIGGER trg_journey_commission
  AFTER INSERT ON public.commissions
  FOR EACH ROW EXECUTE FUNCTION public.journey_on_commission();