---
name: Follow-up automático do agente (régua progressiva)
description: Régua de follow-ups que avança e nunca reinicia — tentativa consumida não volta; resposta do lead só adia o próximo passo
type: feature
---

# Follow-up Automático Contextual — Régua Progressiva

## Regra de negócio

- **Tentativa consumida nunca volta.** Cada tentativa configurada é enviada **uma única vez** por ciclo de conversa.
- **Resposta do lead NÃO reinicia** a régua. Apenas reagenda o próximo passo a partir da nova interação.
- **Mensagem nova do agente NÃO reinicia** a régua. Mantém o ponteiro atual.
- **Régua só reinicia em nova conversa** (conversa fechada → reaberta, novo atendimento, novo funil).
- Após enviar a última tentativa, `ruler_closed=true` e a régua sai da automação.

## Estrutura de persistência — `ai_outreach_queue`

Colunas-chave:

- `last_attempt_executed int` — maior tentativa já enviada (1..max). **Nunca decrementa.**
- `attempts_completed int[]` — tentativas já consumidas (proteção contra workers duplicados).
- `ruler_closed boolean` — true quando esgotou.
- `last_interaction_at timestamptz` — base para calcular o próximo `next_followup_at`.
- `followups_sent` — mantido por compatibilidade, espelha `last_attempt_executed`.

Índice parcial otimizado: `idx_ai_outreach_queue_due` em `next_followup_at` filtrando `status IN ('sent','scheduled')`, `followup_enabled=true`, `ruler_closed=false`.

## Triggers

### `fn_schedule_agent_followup_on_bot_message`
Roda em mensagens outbound do bot/agente. **Não toca em `last_attempt_executed`, `followups_sent` nem `attempts_completed`.** Apenas:
1. Ignora mensagens do próprio cron (`metadata.origin='ai_followup'`) — só atualiza `last_interaction_at`.
2. Se já existe linha ativa (mesma conversa, `ruler_closed=false`) → recalcula `next_followup_at = now() + intervals[last_attempt_executed + 1]`.
3. Se `last_attempt_executed >= max` → encerra com `ruler_closed=true`.
4. Sem linha ativa → cria nova com contadores zerados.

### `fn_cancel_agent_followup_on_visitor_reply`
Roda em mensagens inbound do visitante. **Não cancela mais** (era o bug antigo). Apenas:
- Atualiza `last_interaction_at=now()`.
- Reagenda `next_followup_at = now() + intervals[last_attempt_executed + 1]`.
- Se já passou do máximo → `ruler_closed=true`.

### `trg_close_followup_on_conv_close`
Quando `webchat_conversations.status='closed'` → encerra todas as filas daquela conversa (`ruler_closed=true`, `status='completed'`).

## Cron `ai-followup-cron` (1x/min, batch 100)

1. SELECT `status IN ('sent','scheduled') AND followup_enabled AND ruler_closed=false AND next_followup_at <= now()`.
2. **Claim atômico** por `last_attempt_executed` (token otimista) — substitui o claim antigo por `followups_sent`.
3. Calcula `attemptToSend = last_attempt_executed + 1`. Se já está em `attempts_completed` ou > `max` → encerra.
4. Respeita business hours. Encerra se conversa fechada.
5. Envia. Em sucesso atualiza atomicamente:
   - `last_attempt_executed = attemptToSend`
   - `attempts_completed = attempts_completed || attemptToSend`
   - `last_interaction_at = now()`
   - Se `attemptToSend >= max` → `ruler_closed=true`, `status='completed'`, `followup_enabled=false`, `next_followup_at=null`.
   - Senão → `next_followup_at = now() + intervals[attemptToSend]`, `status='sent'`.
6. Em falha → release com retry +15min, **sem incrementar** contador (tentativa não foi consumida).

## Helper `_shared/followup-scheduler.ts`

- `scheduleAgentFollowup`: se existir linha ativa, **não zera** contadores; só avança `next_followup_at` para `intervals[last_attempt_executed]`. Se já esgotou, encerra.
- `cancelFollowupsForLead`: `reason='lead_replied'` é **no-op** (régua não morre na resposta). Outros motivos (`human_takeover`, `opt_out`, `booking`) encerram com `ruler_closed=true`.

## Impacto em escala

- 1 lead inativo = 1 linha durável (acabou o loop de re-criação a cada msg).
- Triggers fazem 1 SELECT + 1 UPDATE/INSERT — sem laços.
- Resposta do lead não gera mais UPDATE de cancelamento + reinsert.
- Cron usa índice parcial novo; varre apenas linhas realmente devidas.
- Expiração de >12h continua, evitando avalanche pós-downtime.

## CHECK constraint

`ai_outreach_queue_status_check` permite: `pending | scheduled | sent | processing | replied | completed | failed`. O cron usa `processing` para lock.
