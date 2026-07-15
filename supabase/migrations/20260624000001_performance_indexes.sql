-- Performance indexes — Fase 1 do diagnóstico de performance
-- Corrige sequential scans em webchat_messages.metadata,
-- acelera Inbox, Kanban e lookup de instâncias WhatsApp.

-- Índices funcionais em webchat_messages.metadata
-- (sem CONCURRENTLY pois migration roda em ambiente limpo)

CREATE INDEX IF NOT EXISTS idx_wcmsg_meta_external_id
  ON public.webchat_messages ((metadata->>'external_id'))
  WHERE metadata->>'external_id' IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_wcmsg_meta_evolution_msg_id
  ON public.webchat_messages ((metadata->>'evolution_message_id'))
  WHERE metadata->>'evolution_message_id' IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_wcmsg_meta_wa_lid
  ON public.webchat_messages ((metadata->>'wa_lid'))
  WHERE metadata->>'wa_lid' IS NOT NULL;

-- Inbox render: mensagens por conversa (criadas_at DESC)
CREATE INDEX IF NOT EXISTS idx_wcmsg_conv_created
  ON public.webchat_messages (conversation_id, created_at DESC)
  WHERE is_deleted = false;

-- Kanban: leads quentes/mornos por org
CREATE INDEX IF NOT EXISTS idx_leads_org_temp_assigned
  ON public.leads (organization_id, temperature, assigned_to)
  WHERE temperature IN ('hot', 'warm');

-- Evolution instances lookup
CREATE INDEX IF NOT EXISTS idx_evolution_inst_name
  ON public.evolution_instances (instance_name)
  WHERE status = 'connected';
