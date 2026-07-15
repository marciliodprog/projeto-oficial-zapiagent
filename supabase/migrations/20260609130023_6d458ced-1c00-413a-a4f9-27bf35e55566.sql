-- Isolamento de caixa por conexão: o índice único antigo bloqueia múltiplas
-- conversas abertas para o mesmo telefone, impedindo que o mesmo número tenha
-- caixa Evolution + caixa Meta + caixa de outra instância Evolution
-- simultaneamente. Substituímos por um índice único parcial que considera a
-- "caixa" (instância Evolution OU conexão Meta) como parte da chave.
DROP INDEX IF EXISTS public.webchat_conv_open_phone_unique;

-- Unicidade por caixa: cada (org, channel, telefone, caixa) só pode ter UMA
-- conversa aberta por vez. Usa COALESCE para tratar NULL como discriminador.
CREATE UNIQUE INDEX IF NOT EXISTS webchat_conv_open_phone_per_box_unique
ON public.webchat_conversations (
  organization_id,
  channel,
  visitor_phone_normalized,
  COALESCE(evolution_instance_id, '00000000-0000-0000-0000-000000000000'::uuid),
  COALESCE(meta_connection_id,    '00000000-0000-0000-0000-000000000000'::uuid)
)
WHERE status <> 'closed'::webchat_conversation_status
  AND visitor_phone_normalized IS NOT NULL
  AND visitor_phone_normalized <> '';