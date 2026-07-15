import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { recordLovableUsage } from '../_shared/ai-router.ts';
import { sendWhatsAppForConversation } from '../_shared/whatsapp-router.ts';
import { buildTemporalPromptBlock } from '../_shared/temporalContext.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Default timezone for business-hour calculations.
// Brazil-only product → São Paulo. Override with org-level setting later if needed.
const TZ = 'America/Sao_Paulo';

function getZonedParts(date: Date): { dayOfWeek: number; minutes: number } {
  // Use Intl to extract weekday/hour/minute in the target TZ
  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone: TZ,
    weekday: 'short',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
  const parts = fmt.formatToParts(date);
  const wd = parts.find(p => p.type === 'weekday')?.value || 'Sun';
  const hour = parseInt(parts.find(p => p.type === 'hour')?.value || '0', 10);
  const minute = parseInt(parts.find(p => p.type === 'minute')?.value || '0', 10);
  const map: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  return { dayOfWeek: map[wd] ?? 0, minutes: hour * 60 + minute };
}

// Returns a UTC Date that corresponds to the given local Y/M/D + HH:MM in TZ.
function zonedTimeToUtc(year: number, month: number, day: number, h: number, m: number): Date {
  // Approximation good enough for hourly business windows: build a UTC date,
  // then shift by the TZ offset at that moment.
  const guess = new Date(Date.UTC(year, month - 1, day, h, m, 0));
  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  });
  const parts = fmt.formatToParts(guess);
  const get = (t: string) => parseInt(parts.find(p => p.type === t)?.value || '0', 10);
  const tzY = get('year'), tzMo = get('month'), tzD = get('day'), tzH = get('hour'), tzMi = get('minute');
  const tzMs = Date.UTC(tzY, tzMo - 1, tzD, tzH, tzMi, 0);
  const offset = tzMs - guess.getTime();
  return new Date(guess.getTime() - offset);
}

// Adjust a date to the next valid business time (interpreted in TZ)
function adjustToBusinessHours(date: Date, startTime: string, endTime: string, businessDays: number[]): Date {
  const [startH, startM] = startTime.split(':').map(Number);
  const [endH, endM] = endTime.split(':').map(Number);
  let cursor = new Date(date);

  for (let i = 0; i < 14; i++) {
    const { dayOfWeek, minutes } = getZonedParts(cursor);
    // Get cursor's local Y/M/D in TZ
    const dParts = new Intl.DateTimeFormat('en-CA', {
      timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
    }).formatToParts(cursor);
    const Y = parseInt(dParts.find(p => p.type === 'year')!.value, 10);
    const Mo = parseInt(dParts.find(p => p.type === 'month')!.value, 10);
    const D = parseInt(dParts.find(p => p.type === 'day')!.value, 10);

    if (businessDays.includes(dayOfWeek)) {
      const startMinutes = startH * 60 + startM;
      const endMinutes = endH * 60 + endM;
      if (minutes < startMinutes) return zonedTimeToUtc(Y, Mo, D, startH, startM);
      if (minutes < endMinutes) return cursor;
    }
    // advance one day at start-of-business in TZ
    cursor = zonedTimeToUtc(Y, Mo, D + 1, startH, startM);
  }
  return cursor;
}

// Check if current time is within business hours (in TZ)
function isWithinBusinessHours(now: Date, startTime: string, endTime: string, businessDays: number[]): boolean {
  const { dayOfWeek, minutes } = getZonedParts(now);
  if (!businessDays.includes(dayOfWeek)) return false;
  const [startH, startM] = startTime.split(':').map(Number);
  const [endH, endM] = endTime.split(':').map(Number);
  return minutes >= startH * 60 + startM && minutes < endH * 60 + endM;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // (provider WhatsApp removido — sempre Evolution Go)
    const lovableApiKey = Deno.env.get('LOVABLE_API_KEY');

    if (!lovableApiKey) {
      return new Response(
        JSON.stringify({ error: 'Missing LOVABLE_API_KEY' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const now = new Date();
    const nowIso = now.toISOString();
    const tickStart = Date.now();

    // Expira itens muito antigos (>12h) para evitar avalanche pós-downtime
    // e manter a fila enxuta em escala. Lead já esfriou — não vale mais reativar.
    const expiryCutoff = new Date(Date.now() - 12 * 60 * 60 * 1000).toISOString();
    const { count: expiredCount } = await supabase
      .from('ai_outreach_queue')
      .update({ status: 'completed', error_message: 'expired_backlog' }, { count: 'exact' })
      .in('status', ['sent', 'scheduled'])
      .eq('followup_enabled', true)
      .lt('next_followup_at', expiryCutoff);

    const { data: pendingFollowups, error: fetchError } = await supabase
      .from('ai_outreach_queue')
      .select('*')
      .in('status', ['sent', 'scheduled'])
      .eq('followup_enabled', true)
      .eq('ruler_closed', false)
      .lte('next_followup_at', nowIso)
      .order('next_followup_at', { ascending: true })
      .limit(100);



    if (fetchError) {
      console.error('[FollowupCron] Error fetching queue:', fetchError);
      throw fetchError;
    }

    if (!pendingFollowups || pendingFollowups.length === 0) {
      console.log('[FollowupCron] No pending follow-ups');
      return new Response(
        JSON.stringify({ processed: 0 }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log(`[FollowupCron] Processing ${pendingFollowups.length} follow-ups`);
    let processed = 0;
    let failed = 0;

    for (const item of pendingFollowups) {
      try {
        // Régua progressiva: tentativa a enviar = last_attempt_executed + 1
        const lastExecuted: number = item.last_attempt_executed ?? 0;
        const completedSet: number[] = Array.isArray(item.attempts_completed) ? item.attempts_completed : [];
        const attemptToSend = lastExecuted + 1;

        const { data: claimed, error: claimError } = await supabase
          .from('ai_outreach_queue')
          .update({ status: 'processing' })
          .eq('id', item.id)
          .in('status', ['sent', 'scheduled'])
          .eq('ruler_closed', false)
          .eq('last_attempt_executed', lastExecuted)
          .lte('next_followup_at', nowIso)
          .select('id')
          .maybeSingle();

        if (claimError) {
          console.error(`[FollowupCron] Claim error on ${item.id}:`, claimError);
          continue;
        }
        if (!claimed) {
          console.log(`[FollowupCron] Skipping ${item.id}, already claimed or no longer due`);
          continue;
        }

        const releaseForRetry = async (message: string, delayMinutes = 15) => {
          await supabase
            .from('ai_outreach_queue')
            .update({
              status: 'sent',
              error_message: message,
              next_followup_at: new Date(Date.now() + delayMinutes * 60000).toISOString(),
            })
            .eq('id', item.id);
        };

        const steps: Array<{ delay_hours: number; instruction?: string }> = item.followup_steps || [];
        const intervalsMin: number[] = Array.isArray(item.followup_intervals_minutes)
          ? item.followup_intervals_minutes
          : [];
        const hints: Array<{ attempt: number; hint: string }> = Array.isArray(item.followup_attempt_hints)
          ? item.followup_attempt_hints
          : [];
        const maxFollowups = intervalsMin.length > 0
          ? intervalsMin.length
          : (steps.length > 0 ? steps.length : (item.max_followups || 3));
        const businessStart = item.business_hours_start || '09:00';
        const businessEnd = item.business_hours_end || '18:00';
        const businessDays: number[] = item.business_days || [1, 2, 3, 4, 5];

        // Guarda: régua já encerrada ou tentativa já consumida
        if (attemptToSend > maxFollowups || completedSet.includes(attemptToSend)) {
          await supabase
            .from('ai_outreach_queue')
            .update({ status: 'completed', ruler_closed: true, followup_enabled: false, next_followup_at: null })
            .eq('id', item.id);
          continue;
        }


        // Check business hours - if not in hours, reschedule
        if (!isWithinBusinessHours(now, businessStart, businessEnd, businessDays)) {
          const nextBizTime = adjustToBusinessHours(now, businessStart, businessEnd, businessDays);
          await supabase
            .from('ai_outreach_queue')
            .update({ status: 'sent', next_followup_at: nextBizTime.toISOString() })
            .eq('id', item.id);
          console.log(`[FollowupCron] Outside business hours, rescheduled ${item.id} to ${nextBizTime.toISOString()}`);
          continue;
        }

        // Régua progressiva: resposta do lead NÃO cancela mais — só avança o cronômetro
        // (feito pelo trigger fn_cancel_agent_followup_on_visitor_reply). Aqui só encerra
        // se a conversa foi fechada ou se humano assumiu (apenas para non-agent_silence).
        if (item.conversation_id) {
          const { data: convInfo } = await supabase
            .from('webchat_conversations')
            .select('status')
            .eq('id', item.conversation_id)
            .maybeSingle();

          if (convInfo?.status === 'closed') {
            await supabase
              .from('ai_outreach_queue')
              .update({ status: 'completed', ruler_closed: true, followup_enabled: false, next_followup_at: null })
              .eq('id', item.id);
            console.log(`[FollowupCron] Conversation ${item.conversation_id} closed, ending ruler for ${item.id}`);
            continue;
          }

          if (item.followup_kind !== 'agent_silence' && (convInfo?.status === 'human_active' || convInfo?.status === 'waiting_human')) {
            await supabase
              .from('ai_outreach_queue')
              .update({ status: 'completed', ruler_closed: true, followup_enabled: false, next_followup_at: null })
              .eq('id', item.id);
            console.log(`[FollowupCron] Human took over conv ${item.conversation_id}, stopping non-agent follow-up for ${item.id}`);
            continue;
          }
        }


        // Get agent
        const { data: agent } = await supabase
          .from('product_agents')
          .select('*')
          .eq('id', item.agent_id)
          .single();

        if (!agent) {
          console.error(`[FollowupCron] Agent ${item.agent_id} not found`);
          await releaseForRetry(`Agent ${item.agent_id} not found`);
          continue;
        }

        // Get conversation history
        let previousMessages: string[] = [];
        if (item.conversation_id) {
          const { data: messages } = await supabase
            .from('webchat_messages')
            .select('content, sender_type')
            .eq('conversation_id', item.conversation_id)
            .order('created_at', { ascending: true });

          previousMessages = (messages || []).map(
            m => `[${m.sender_type === 'bot' ? 'Agente' : 'Lead'}]: ${m.content}`
          );
        }

        // Get step-specific instruction
        const currentStepIndex = attemptToSend - 1;
        const currentStep = steps[currentStepIndex];
        const stepInstruction = currentStep?.instruction || '';
        const attemptNumber = attemptToSend;
        const isLastAttempt = attemptNumber >= maxFollowups;


        const currentHint = hints.find((h) => h.attempt === attemptNumber)?.hint || stepInstruction;

        // Build follow-up prompt
        const systemPrompt = `Você é ${agent.name}, um agente de ${agent.agent_type}.
TOM DE VOZ: ${agent.tone_style || 'Consultivo'}
ESTILO: ${agent.message_style || 'Curta e objetiva'}
TOM DA RETOMADA: ${agent.followup_tone || 'warm'}
OBJETIVO: ${item.objective || agent.primary_objective}
${item.extra_context ? `CONTEXTO: ${item.extra_context}` : ''}
${agent.followup_extra_instructions ? `DIRETRIZES EXTRAS: ${agent.followup_extra_instructions}` : ''}

REGRAS:
- Gere APENAS a mensagem, sem explicações
- Cite o nome do lead quando fizer sentido, de forma natural
- Mensagem curta para WhatsApp/Instagram (1-2 linhas)
- DIFERENTE das mensagens anteriores e contextual ao que já foi falado
${currentHint ? `- INTENÇÃO DESTA TENTATIVA: ${currentHint}` : ''}
${isLastAttempt ? '- Esta é a ÚLTIMA tentativa. Ofereça uma alternativa (ligação, material, falar depois).' : ''}${buildTemporalPromptBlock()}`;

        const userPrompt = `Você já enviou ${attemptToSend} mensagens para este lead sem resposta.

Histórico:
${previousMessages.join('\n')}

Lead: ${item.lead_data?.name || 'Lead'}
Tentativa ${attemptNumber} de ${maxFollowups}

Gere uma mensagem de follow-up estratégica DIFERENTE das anteriores.`;

        // Call AI
        const aiResponse = await fetch('https://ai.gateway.lovable.dev/v1/chat/completions', {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${lovableApiKey}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            model: 'google/gemini-2.5-flash',
            messages: [
              { role: 'system', content: systemPrompt },
              { role: 'user', content: userPrompt },
            ],
          }),
        });

        if (!aiResponse.ok) {
          const errText = await aiResponse.text();
          console.error(`[FollowupCron] AI error for ${item.id}:`, aiResponse.status, errText);
          await releaseForRetry(`AI error ${aiResponse.status}: ${errText.slice(0, 500)}`);
          failed++;
          continue;
        }

        const aiData = await aiResponse.json();
        await recordLovableUsage(supabase, item.organization_id, 'agent_chat', 'google/gemini-2.5-flash', aiData?.usage, 'ai-followup-cron');
        const followupMessage = aiData.choices?.[0]?.message?.content?.trim();

        if (!followupMessage) {
          console.error(`[FollowupCron] Empty AI response for ${item.id}`);
          await releaseForRetry('Empty AI response');
          failed++;
          continue;
        }

        // Send via configured provider
        const phone = item.lead_data?.phone;
        if (!phone) {
          console.error(`[FollowupCron] No phone for ${item.id}`);
          await releaseForRetry('No phone in lead_data');
          failed++;
          continue;
        }

        let sendSuccess = false;
        try {
          let sendResult: any = null;

          if (item.conversation_id) {
            const { data: routeConversation } = await supabase
              .from('webchat_conversations')
              .select('id, organization_id, visitor_phone, meta_connection_id, evolution_instance_id')
              .eq('id', item.conversation_id)
              .maybeSingle();

            if (routeConversation) {
              sendResult = await sendWhatsAppForConversation({
                supabase,
                conversation: {
                  id: routeConversation.id,
                  organization_id: routeConversation.organization_id,
                  meta_connection_id: (routeConversation as any).meta_connection_id,
                  evolution_instance_id: (routeConversation as any).evolution_instance_id,
                  visitor_phone: routeConversation.visitor_phone || phone,
                },
                to: routeConversation.visitor_phone || phone,
                text: followupMessage,
              });
            }
          }

          if (!sendResult) {
            const { data: sendData, error: sendErr } = await supabase.functions.invoke('evolution-send', {
              body: {
                organization_id: item.organization_id,
                type: 'text',
                to: phone,
                payload: { text: followupMessage },
              },
            });
            sendResult = {
              ok: !sendErr && (sendData as any)?.ok !== false,
              provider: 'evolution',
              code: (sendData as any)?.code,
              error: sendErr?.message || (sendData as any)?.error || (sendData as any)?.body,
              message: (sendData as any)?.message,
              raw: sendData,
            };
          }

          sendSuccess = !!sendResult.ok;
          if (!sendSuccess) {
            console.error(`[FollowupCron] WhatsApp send failed for ${item.id}:`, sendResult);
            if (sendResult.code === 'WHATSAPP_VALIDATION_UNRELIABLE') {
              await releaseForRetry(
                `WhatsApp validation unreliable: ${sendResult.message || sendResult.error || 'provider false negative/session issue'}`,
                5,
              );
            } else {
              await releaseForRetry(`WhatsApp send failed: ${JSON.stringify(sendResult).slice(0, 500)}`);
            }
            failed++;
            continue;
          }
        } catch (e) {
          console.error(`[FollowupCron] WhatsApp send exception for ${item.id}:`, e);
          await releaseForRetry(`WhatsApp send exception: ${e instanceof Error ? e.message : String(e)}`);
          failed++;
          continue;
        }

        // Save message in conversation
        // metadata.origin='ai_followup' sinaliza ao trigger trg_schedule_agent_followup
        // que essa mensagem foi o próprio cron enviando — não deve reagendar nova fila.
        if (item.conversation_id) {
          await supabase
            .from('webchat_messages')
            .insert({
              conversation_id: item.conversation_id,
              content: followupMessage,
              sender_type: 'bot',
              direction: 'outbound',
              metadata: { origin: 'ai_followup', queue_id: item.id, attempt: attemptToSend },
            });
        }

        // Régua progressiva: avança last_attempt_executed e attempts_completed
        const newLastExecuted = attemptToSend;
        const newCompleted = Array.from(new Set([...completedSet, attemptToSend])).sort((a, b) => a - b);
        const isNowComplete = newLastExecuted >= maxFollowups;

        let nextFollowupAt: string | null = null;
        if (!isNowComplete) {
          const nextAttemptIdx = newLastExecuted; // intervalsMin[N] = delay para tentativa N+1
          const minutesFromNew = intervalsMin[nextAttemptIdx];
          const nextStep = steps[nextAttemptIdx];
          const delayMs = (typeof minutesFromNew === 'number' && minutesFromNew > 0)
            ? minutesFromNew * 60000
            : (nextStep?.delay_hours || item.followup_interval_hours || 24) * 3600000;
          const rawNext = new Date(Date.now() + delayMs);
          const respectHours = item.followup_kind === 'agent_silence'
            ? !!(agent.followup_respect_business_hours ?? true)
            : true;
          nextFollowupAt = respectHours
            ? adjustToBusinessHours(rawNext, businessStart, businessEnd, businessDays).toISOString()
            : rawNext.toISOString();
        }

        await supabase
          .from('ai_outreach_queue')
          .update({
            followups_sent: newLastExecuted,
            last_attempt_executed: newLastExecuted,
            attempts_completed: newCompleted,
            ruler_closed: isNowComplete,
            last_outreach_at: new Date().toISOString(),
            last_interaction_at: new Date().toISOString(),
            next_followup_at: nextFollowupAt,
            followup_enabled: !isNowComplete,
            status: isNowComplete ? 'completed' : 'sent',
          })
          .eq('id', item.id);

        console.log(`[FollowupCron] Tentativa ${newLastExecuted}/${maxFollowups} enviada para ${item.id}`);

        processed++;
      } catch (itemError: any) {
        console.error(`[FollowupCron] Error processing ${item.id}:`, itemError);
        await supabase
          .from('ai_outreach_queue')
          .update({
            status: 'sent',
            error_message: itemError?.message || String(itemError),
            next_followup_at: new Date(Date.now() + 15 * 60000).toISOString(),
          })
          .eq('id', item.id)
          .eq('status', 'processing');
        failed++;
      }
    }

    console.log(JSON.stringify({
      tag: 'followup_cron_tick',
      processed,
      failed,
      total: pendingFollowups.length,
      expired: expiredCount ?? 0,
      duration_ms: Date.now() - tickStart,
    }));
    return new Response(
      JSON.stringify({ processed, failed, total: pendingFollowups.length, expired: expiredCount ?? 0 }),

      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('[FollowupCron] Unexpected error:', error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
