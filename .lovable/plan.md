# Por que o segundo comentário não disparou nada

## Diagnóstico

Não é regra da Meta. É uma trava **nossa**, dentro do `ig-flow-executor`:

- Cada fluxo tem o campo `throttle_per_sender_hours` (default **24h**).
- Antes de executar, o executor checa `instagram_flow_runs` do mesmo `sender_ig_id` nas últimas N horas. Se já existe run recente com status ≠ `skipped`, ele grava um novo run com `status='skipped'` e `error='throttled_by_sender'` e **não faz nada** (não curte, não responde, não manda DM).
- Como seu comentário anterior foi há poucos minutos, o segundo comentário do mesmo usuário caiu direto no throttle.

Ou seja: a Meta aceitaria responder de novo (o limite real dela é outro, ver abaixo). Quem bloqueou foi a nossa regra anti-spam por remetente.

## O que a Meta realmente restringe (docs oficiais usadas)

- **Private Reply a comentário** — `Instagram Platform > Send a Private Reply to a Commenter`: só pode ser usada **uma vez por comentário** e dentro de **7 dias** após o comentário. Não há limite "1 por usuário a cada 24h".
- **Responder comentário público** — `Instagram Platform > Comment Moderation / IG Comment Replies` (`POST /<IG_COMMENT_ID>/replies`): sem janela de 24h; sujeito só aos rate limits gerais da Graph API.
- **DM padrão (fora de private reply)** — `Instagram API with Instagram Login > Messaging API`: aí sim existe a **janela de 24 horas** de mensageria, mas ela se aplica a **enviar DM depois** que o usuário te mandou uma mensagem. Não bloqueia responder comentário.
- **Curtir comentário** — `Instagram Platform > Like Media and Comments API`: sem janela de 24h; exige permissão `instagram_manage_engagement`.

Conclusão: nenhuma dessas APIs impõe "1 automação por usuário a cada 24h". Esse limite é 100% nosso.

## Correções propostas

1. **Deixar claro na UI que o throttle é interno**
   - Na aba **Config** do Builder, renomear o campo para "Throttle por remetente (nossa proteção anti-spam)".
   - Adicionar helper text explicando: "Impede que o mesmo usuário do Instagram dispare este fluxo repetidas vezes. Não é uma regra da Meta. Coloque 0 para desativar."
   - Permitir valor **0 = sem throttle**.

2. **Ajustar o executor**
   - `ig-flow-executor`: quando `throttle_per_sender_hours === 0`, pular a checagem inteira.
   - Melhorar o registro do run "skipped": incluir `next_allowed_at` para a UI mostrar "próximo disparo liberado às HH:MM".

3. **Mostrar na aba Execuções**
   - Runs com `error='throttled_by_sender'` aparecem hoje como falha genérica. Trocar para um badge amarelo "Throttle interno — mesmo usuário disparou há X min" com botão **"Liberar este remetente agora"** (deleta os runs recentes desse `sender_ig_id` para o fluxo).

4. **Novo default para fluxos novos**
   - Reduzir o default de `throttle_per_sender_hours` de 24 para **1 hora** em fluxos recém-criados. Fluxos existentes ficam como estão (não mexer no banco).

5. **Documentação inline**
   - Adicionar tooltip no builder listando as regras reais da Meta (private reply 1×/comentário, janela 24h só para DM padrão, permissão para curtir) para o usuário não confundir com nosso throttle.

## Detalhes técnicos

- Arquivo: `supabase/functions/ig-flow-executor/index.ts` — linhas ~48–78 (bloco do throttle).
- Arquivo: `src/components/admin/instagram/InstagramFlowBuilder.tsx` — aba Config + aba Execuções.
- Tabelas: `instagram_flows.throttle_per_sender_hours`, `instagram_flow_runs` (nenhuma migração necessária).
- Sem mudança de escopo OAuth. Sem chamada nova à Graph API.

## Validação

1. Editar o fluxo, colocar throttle = 0, comentar de novo com a mesma conta → deve curtir + responder + mandar DM.
2. Voltar throttle para 1h, comentar 2× seguidos → segundo comentário aparece na aba Execuções como "throttle interno", com botão para liberar.
