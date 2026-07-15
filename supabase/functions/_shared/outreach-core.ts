// Núcleo do processamento de outreach por lead.
// Extraído de manual-outreach para permitir reutilização em manual-outreach-batch
// com cache compartilhado (agent + knowledge + widget) entre chamadas.
//
// O contrato externo de manual-outreach é preservado — ele apenas delega aqui.

import { splitIntoBubbles } from "./humanizer.ts";
import { recordLovableUsage } from "./ai-router.ts";
import { resolveAgentSendConnection } from "./agent-connection.ts";
import { normalizePhoneBR } from "./phone.ts";
import { buildTemporalPromptBlock } from "./temporalContext.ts";
import { sanitizeAgentOutput } from "./sanitize-agent-output.ts";

export type OutreachTarget = {
  lead_id: string;
  agent_id: string;
  organization_id: string;
  objective?: string;
  extra_context?: string;
  event_context?: Record<string, unknown>;
  mode?: "direct" | "conversational";
  force_when_human?: boolean;
  /** Ação manual do operador no Inbox — ignora dedupe de 24h de outreach. */
  force_manual_followup?: boolean;
  /**
   * Permite reviver a IA em conversa que foi devolvida à fila (status=waiting_human).
   * Só deve ser true em ações explícitas de admin pelo Inbox; nunca em cadências/cron.
   */
  revive_from_queue?: boolean;
  instance_id?: string;
  connection_type?: "evolution" | "meta_whatsapp";
  template_config?: { template_id: string; variable_mapping?: Record<string, any> } | null;
};


export type OutreachResult = {
  leadId: string;
  name?: string | null;
  sent?: boolean;
  skipped?: boolean;
  reason?: string;
  code?: string;
  error?: string;
  conversationId?: string | null;
  via?: string;
};

/**
 * Cache compartilhado por execução. Pode ser reutilizado entre múltiplos
 * `processOutreachTarget` para evitar fetches repetidos.
 */
export type OutreachCache = {
  agents: Map<string, any>; // agent_id -> agent row
  knowledge: Map<string, string>; // product_id -> formatted knowledge string
  widgets: Map<string, string | null>; // organization_id -> widget id
};

export function createOutreachCache(): OutreachCache {
  return { agents: new Map(), knowledge: new Map(), widgets: new Map() };
}

async function getAgent(supabase: any, cache: OutreachCache, agentId: string) {
  if (cache.agents.has(agentId)) return cache.agents.get(agentId);
  const { data: agent } = await supabase
    .from("product_agents")
    .select("*")
    .eq("id", agentId)
    .single();
  cache.agents.set(agentId, agent);
  return agent;
}

async function getKnowledge(supabase: any, cache: OutreachCache, productId: string | null) {
  if (!productId) return "";
  if (cache.knowledge.has(productId)) return cache.knowledge.get(productId)!;
  const { data: rows } = await supabase
    .from("ai_knowledge_base")
    .select("title, content, category")
    .eq("product_id", productId)
    .eq("is_active", true)
    .limit(10);
  const ctx = (rows || [])
    .map((k: any) => `[${k.category}] ${k.title}: ${k.content}`)
    .join("\n\n");
  cache.knowledge.set(productId, ctx);
  return ctx;
}

async function getOutreachWidget(supabase: any, cache: OutreachCache, organizationId: string) {
  if (cache.widgets.has(organizationId)) return cache.widgets.get(organizationId) ?? null;
  const { data: existing } = await supabase
    .from("webchat_widgets")
    .select("id")
    .eq("organization_id", organizationId)
    .eq("is_active", true)
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  let widgetId: string | null = existing?.id ?? null;
  if (!widgetId) {
    const { data: created, error } = await supabase
      .from("webchat_widgets")
      .insert({ organization_id: organizationId, name: "Outreach (automático)", is_active: true })
      .select("id")
      .single();
    if (error) console.error("[outreach-core] Falha ao criar widget interno:", error);
    widgetId = created?.id ?? null;
  }
  cache.widgets.set(organizationId, widgetId);
  return widgetId;
}

async function logFailedMessage(
  supabase: any,
  conversationId: string | null,
  content: string,
  errorMsg: string,
  extra?: { error_code?: string; error_detail?: any; phone?: string | null },
) {
  if (!conversationId) return;
  try {
    await supabase.from("webchat_messages").insert({
      conversation_id: conversationId,
      content,
      sender_type: "bot",
      direction: "outbound",
      delivery_status: "failed",
      metadata: {
        error: errorMsg,
        source: "manual-outreach",
        error_code: extra?.error_code ?? null,
        error_detail: extra?.error_detail ?? null,
        phone_attempted: extra?.phone ?? null,
        failed_at: new Date().toISOString(),
      },
    });
  } catch (e) {
    console.error("[outreach-core] failed to log failed message:", e);
  }
}

/**
 * Notifica o vendedor responsável pelo lead quando uma mensagem falha em definitivo.
 * Silencioso em erro para nunca interromper o fluxo principal.
 */
async function notifySellerDeliveryFailed(
  supabase: any,
  params: {
    organization_id: string;
    lead_id: string;
    conversation_id: string | null;
    error_code: string | null;
    error_message: string;
  },
) {
  try {
    const { data: lead } = await supabase
      .from("leads")
      .select("assigned_to, name")
      .eq("id", params.lead_id)
      .maybeSingle();
    const userId = lead?.assigned_to;
    if (!userId) return;
    await supabase.from("notifications").insert({
      user_id: userId,
      organization_id: params.organization_id,
      type: "whatsapp_delivery_failed",
      title: "Mensagem não entregue no WhatsApp",
      message:
        params.error_code === "WHATSAPP_VALIDATION_UNRELIABLE"
          ? `Não conseguimos entregar mensagem para ${lead?.name ?? "o lead"} — a conexão WhatsApp não confirmou o número, mas há histórico com ele. Verifique/reconecte a instância.`
          : params.error_code === "PHONE_NOT_ON_WHATSAPP"
          ? `Não conseguimos entregar mensagem para ${lead?.name ?? "o lead"} — número não está no WhatsApp. Verifique o telefone.`
          : `Falha ao enviar mensagem para ${lead?.name ?? "o lead"}: ${params.error_message}`,
      metadata: {
        lead_id: params.lead_id,
        conversation_id: params.conversation_id,
        error_code: params.error_code,
      },
    });
  } catch (e) {
    console.warn("[outreach-core] notifySellerDeliveryFailed failed:", e);
  }
}

/**
 * Detecta se houve mensagem inbound do visitante nos últimos N dias — se sim,
 * um erro momentâneo PHONE_NOT_ON_WHATSAPP provavelmente é falso-negativo do Baileys.
 */
async function hadRecentInbound(
  supabase: any,
  conversationId: string | null,
  days = 30,
): Promise<boolean> {
  if (!conversationId) return false;
  try {
    const since = new Date(Date.now() - days * 86400_000).toISOString();
    const { count } = await supabase
      .from("webchat_messages")
      .select("id", { count: "exact", head: true })
      .eq("conversation_id", conversationId)
      .eq("direction", "inbound")
      .gt("created_at", since);
    return (count ?? 0) > 0;
  } catch {
    return false;
  }
}

const CIRCUIT_BREAKER_ENABLED = (Deno.env.get("CIRCUIT_BREAKER_ENABLED") ?? "true").toLowerCase() !== "false";

async function reportProviderOutcome(
  supabase: any,
  connectionType: "evolution" | "meta_whatsapp",
  connectionId: string | undefined,
  ok: boolean,
  reason?: string | null,
) {
  if (!CIRCUIT_BREAKER_ENABLED || !connectionId) return;
  try {
    if (ok) {
      await supabase.rpc("report_provider_success", {
        p_provider: connectionType,
        p_connection_id: connectionId,
      });
    } else {
      await supabase.rpc("report_provider_failure", {
        p_provider: connectionType,
        p_connection_id: connectionId,
        p_reason: (reason || "send_failed").slice(0, 500),
      });
    }
  } catch (e) {
    console.error("[outreach-core] reportProviderOutcome failed:", e);
  }
}

export async function processOutreachTarget(
  supabase: any,
  lovableApiKey: string,
  cache: OutreachCache,
  target: OutreachTarget,
): Promise<OutreachResult> {
  const {
    lead_id: leadId,
    agent_id,
    organization_id,
    objective,
    extra_context,
    event_context,
    template_config,
  } = target;
  const mode = target.mode ?? "direct";
  const force_when_human = !!target.force_when_human;
  const force_manual_followup = !!target.force_manual_followup;
  const revive_from_queue = !!target.revive_from_queue;

  let instance_id = target.instance_id;
  let connection_type: "evolution" | "meta_whatsapp" = target.connection_type ?? "evolution";

  try {
    const agent = await getAgent(supabase, cache, agent_id);
    if (!agent) return { leadId, error: "Agent not found" };

    if (!instance_id) {
      const resolved = await resolveAgentSendConnection(supabase, agent_id);
      if (!resolved) {
        return {
          leadId,
          error: "Agente sem conexão WhatsApp vinculada. Configure uma conexão (Evolution ou API Oficial) nas opções do agente.",
        };
      }
      instance_id = resolved.connection_id;
      connection_type = resolved.connection_type;
    }

    const outreachWidgetId = await getOutreachWidget(supabase, cache, organization_id);
    const knowledgeContext = await getKnowledge(supabase, cache, agent.product_id);

    const { data: lead } = await supabase
      .from("leads")
      .select("name, email, phone, metadata, temperature, deal_value, whatsapp_opt_in")
      .eq("id", leadId)
      .single();

    if ((lead as any)?.whatsapp_opt_in === false) {
      return { leadId, skipped: true, reason: "OPTED_OUT", code: "OPTED_OUT" };
    }

    try {
      const { data: botFlag } = await supabase
        .from("webchat_conversations")
        .select("id")
        .eq("lead_id", leadId)
        .not("bot_loop_detected_at", "is", null)
        .limit(1);
      if (botFlag && botFlag.length) {
        return { leadId, skipped: true, reason: "BOT_LOOP_DETECTED", code: "BOT_LOOP_DETECTED" };
      }
    } catch (_) { /* segue */ }

    const leadPhone = normalizePhoneBR(lead?.phone);
    if (!leadPhone) {
      return { leadId, skipped: true, reason: "invalid_phone", code: "INVALID_PHONE" };
    }

    // Conversa existente — escopada pela conexão atual
    let convQuery = supabase
      .from("webchat_conversations")
      .select("id, status, metadata, assigned_user_id")
      .eq("lead_id", leadId)
      .order("created_at", { ascending: false })
      .limit(1);
    if (connection_type === "meta_whatsapp" && instance_id) {
      convQuery = convQuery.eq("meta_connection_id", instance_id);
    } else if (instance_id) {
      convQuery = convQuery.eq("evolution_instance_id", instance_id).is("meta_connection_id", null);
    } else {
      convQuery = convQuery.is("meta_connection_id", null);
    }
    const { data: existingConv } = await convQuery.maybeSingle();

    // Dedupe outreach recente
    const { data: existingOutreach } = await supabase
      .from("ai_outreach_queue")
      .select("id, last_outreach_at, status")
      .eq("lead_id", leadId)
      .eq("agent_id", agent_id)
      .in("status", ["pending", "sent"])
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (existingOutreach && !force_when_human && !force_manual_followup) {
      const lastAt = existingOutreach.last_outreach_at ? new Date(existingOutreach.last_outreach_at).getTime() : 0;
      const hoursSince = (Date.now() - lastAt) / 3600000;
      if (hoursSince < 24) {
        let windowOpen = false;
        if (existingConv?.id) {
          const { data: ok } = await supabase.rpc("is_within_24h_window", { _conversation_id: existingConv.id });
          windowOpen = !!ok;
        }
        let lastMsgFailed = false;
        if (existingConv?.id) {
          const { data: lastMsg } = await supabase
            .from("webchat_messages")
            .select("delivery_status, sender_type")
            .eq("conversation_id", existingConv.id)
            .in("sender_type", ["agent", "ai", "system"])
            .order("created_at", { ascending: false })
            .limit(1)
            .maybeSingle();
          lastMsgFailed = lastMsg?.delivery_status === "failed";
        }
        if (windowOpen && !lastMsgFailed) {
          return { leadId, skipped: true, reason: "Outreach ativo recente para este agente" };
        }
      }
    }

    // Trava de fila absoluta: waiting_human só desbloqueia com revive_from_queue (ação admin)
    if (existingConv?.status === "waiting_human" && !revive_from_queue) {
      console.warn(`[outreach-core] 🔒 queue-lock: lead=${leadId} conv=${existingConv.id} blocked (status=waiting_human)`);
      return { leadId, skipped: true, reason: "Conversa em fila — aguardando atendente humano", code: "QUEUE_LOCK" };
    }
    if (existingConv && !force_when_human && existingConv.status === "human_active") {
      return { leadId, skipped: true, reason: `Conversation in ${existingConv.status}` };
    }

    // Se for revive_from_queue, libera a IA via RPC dedicada (escapa do trigger de banco)
    if (existingConv?.status === "waiting_human" && revive_from_queue) {
      try {
        await supabase.rpc("revive_ai_for_conversation", {
          p_conversation_id: existingConv.id,
          p_agent_id: agent_id,
        });
        console.log(`[outreach-core] 🔓 IA revived for conv=${existingConv.id} by manual admin action`);
      } catch (e: any) {
        console.error("[outreach-core] revive_ai_for_conversation failed:", e?.message || e);
        return { leadId, error: e?.message || "Falha ao reativar IA", code: "REVIVE_FAILED" };
      }
    }


    const useTemplate = !!(template_config?.template_id && connection_type === "meta_whatsapp");
    if (connection_type === "meta_whatsapp" && !useTemplate) {
      let withinWindow = false;
      if (existingConv?.id) {
        const { data: ok } = await supabase.rpc("is_within_24h_window", { _conversation_id: existingConv.id });
        withinWindow = !!ok;
      }
      if (!withinWindow) {
        return {
          leadId,
          error: "API Oficial fora da janela 24h. Selecione um template HSM aprovado para abrir conversa.",
          code: "OUT_OF_WINDOW_NEEDS_TEMPLATE",
        };
      }
    }

    // Conversa
    let conversationId: string | null = existingConv?.id ?? null;
    if (!conversationId) {
      const convMeta: Record<string, unknown> = {
        ai_outreach: true,
        manual_trigger: true,
        outreach_mode: useTemplate ? "template" : mode,
        created_via: "manual_outreach",
      };
      if (event_context && (event_context as any).campaign_id) {
        convMeta.campaign_id = (event_context as any).campaign_id;
      }
      if (mode === "conversational" && event_context && Object.keys(event_context).length > 0) {
        convMeta.pending_payment_data = event_context;
        convMeta.pending_payment_objective = objective || null;
      }
      const { data: newConv, error: convErr } = await supabase
        .from("webchat_conversations")
        .insert({
          organization_id,
          widget_id: outreachWidgetId,
          visitor_id: crypto.randomUUID(),
          visitor_name: lead?.name || "Lead",
          visitor_email: lead?.email,
          visitor_phone: leadPhone,
          channel: "whatsapp",
          status: "bot_active",
          lead_id: leadId,
          current_agent_id: agent_id,
          meta_connection_id: connection_type === "meta_whatsapp" ? instance_id : null,
          evolution_instance_id: connection_type === "evolution" ? instance_id : null,
          metadata: convMeta,
        })
        .select("id")
        .single();
      if (convErr || !newConv) {
        return { leadId, error: `conversation insert failed: ${convErr?.message || "unknown"}` };
      }
      conversationId = newConv.id;
    } else {
      const humanOwned = !!existingConv.assigned_user_id;
      const patch: Record<string, unknown> = {};
      if (!humanOwned) patch.current_agent_id = agent_id;
      if (connection_type === "meta_whatsapp") patch.meta_connection_id = instance_id;
      if (connection_type === "evolution") patch.evolution_instance_id = instance_id;
      const baseMeta = ((existingConv.metadata as any) || {});
      let mergedMeta: any = null;
      if (event_context && (event_context as any).campaign_id) {
        mergedMeta = { ...baseMeta, campaign_id: (event_context as any).campaign_id };
      }
      if (mode === "conversational" && event_context && Object.keys(event_context).length > 0) {
        mergedMeta = { ...(mergedMeta ?? baseMeta), pending_payment_data: event_context, pending_payment_objective: objective || null };
      }
      if (mergedMeta) patch.metadata = mergedMeta;
      if (Object.keys(patch).length > 0) {
        await supabase.from("webchat_conversations").update(patch).eq("id", conversationId);
      }
    }

    // Mensagem
    let bubbles: string[] = [];
    if (!useTemplate) {
      const eventCtxLines = event_context
        ? Object.entries(event_context).map(([k, v]) => `- ${k}: ${v}`).join("\n")
        : "";

      const modeRules = mode === "conversational"
        ? `MODO: CONVERSA INTENCIONAL
- Gere APENAS uma abertura curta (1–2 linhas, no máx. 25 palavras).
- Faça UMA pergunta provocativa referenciando o evento.
- NÃO entregue Pix, link, código ou dados do evento agora — só pergunte.`
        : `MODO: MENSAGEM DIRETA
- Gere uma mensagem completa em no máx. 2 parágrafos curtos.
- Se houver Pix/link, coloque cada um em linha própria.
- Termine com UMA pergunta ou CTA claro.`;

      const systemPrompt = `Você é ${agent.name}, um agente de ${agent.agent_type} da empresa.
MISSÃO: ${agent.primary_objective}
TOM DE VOZ: ${agent.tone_style || "Consultivo"}
ESTILO DE MENSAGEM: ${agent.message_style || "Curta e objetiva"}
${agent.can_do?.length ? `O QUE VOCÊ PODE FAZER:\n${agent.can_do.map((c: string) => `- ${c}`).join("\n")}` : ""}
${agent.cannot_do?.length ? `O QUE VOCÊ NÃO PODE FAZER:\n${agent.cannot_do.map((c: string) => `- ${c}`).join("\n")}` : ""}
${knowledgeContext ? `CONHECIMENTO DO PRODUTO:\n${knowledgeContext}` : ""}
${objective ? `OBJETIVO DESTA ABORDAGEM: ${objective}` : ""}
${extra_context ? `CONTEXTO ADICIONAL: ${extra_context}` : ""}
${eventCtxLines ? `CONTEXTO DO EVENTO:\n${eventCtxLines}` : ""}
${modeRules}
REGRAS GERAIS:
- Gere APENAS a mensagem, sem explicações ou prefixos.
- Seja natural e humano, sem clichês.
- WhatsApp: sem markdown, sem HTML.${buildTemporalPromptBlock()}`;

      const userPrompt = `Gere a mensagem de primeira abordagem via WhatsApp para este lead:
Nome: ${lead?.name || "Lead"}
Email: ${lead?.email || "Não informado"}
Telefone: ${leadPhone}
Temperatura: ${lead?.temperature || "indefinida"}`;

      const aiResponse = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
        method: "POST",
        headers: { Authorization: `Bearer ${lovableApiKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          model: "google/gemini-2.5-flash",
          messages: [
            { role: "system", content: systemPrompt },
            { role: "user", content: userPrompt },
          ],
        }),
      });

      if (!aiResponse.ok) {
        await logFailedMessage(supabase, conversationId, `[falha IA ${aiResponse.status}]`, `AI failed: ${aiResponse.status}`);
        return { leadId, error: `AI failed: ${aiResponse.status}`, conversationId };
      }

      const aiData = await aiResponse.json();
      await recordLovableUsage(supabase, organization_id, "agent_chat", "google/gemini-2.5-flash", aiData?.usage, "manual-outreach");
      const rawMessage = aiData.choices?.[0]?.message?.content?.trim();
      const sanitized = sanitizeAgentOutput(rawMessage);
      if (sanitized.leaked) {
        console.warn("[outreach-core] ⚠️ tool-call leak stripped:", sanitized.removed.slice(0, 3));
      }
      const generatedMessage = sanitized.text;
      if (!generatedMessage) {
        await logFailedMessage(supabase, conversationId, "[IA retornou vazio]", "AI returned empty message");
        return { leadId, error: "AI returned empty message", conversationId };
      }

      bubbles = mode === "conversational"
        ? [generatedMessage]
        : splitIntoBubbles(generatedMessage, { maxChunks: 2, targetCharsPerChunk: 280 });
    }

    // Envio
    let sent = false;
    let lastError: string | null = null;
    let lastErrorCode: string | null = null;

    if (useTemplate) {
      const r = await supabase.functions.invoke("meta-whatsapp-send", {
        body: {
          organization_id,
          connection_id: instance_id,
          conversation_id: conversationId,
          to: leadPhone,
          type: "template",
          template: {
            template_id: template_config!.template_id,
            variable_mapping: template_config!.variable_mapping ?? {},
            lead_id: leadId,
            context: [objective, extra_context].filter(Boolean).join("\n"),
          },
        },
      });
      const ok = !r.error && (r.data as any)?.ok !== false && !(r.data as any)?.error;
      if (!ok) lastError = r.error?.message || (r.data as any)?.error || "template send failed";
      else sent = true;
    } else if (connection_type === "meta_whatsapp") {
      for (let i = 0; i < bubbles.length; i++) {
        const r = await supabase.functions.invoke("meta-whatsapp-send", {
          body: {
            organization_id,
            connection_id: instance_id,
            conversation_id: conversationId,
            to: leadPhone,
            type: "text",
            text: bubbles[i],
          },
        });
        const ok = !r.error && (r.data as any)?.ok !== false && !(r.data as any)?.error;
        if (!ok) { lastError = r.error?.message || (r.data as any)?.error || "meta send failed"; break; }
        sent = true;
        if (i < bubbles.length - 1) await new Promise((res) => setTimeout(res, 800));
      }
    } else {
      // Helper local: um envio via evolution-send que extrai payload de erro rico.
      const invokeEvo = async (text: string) => {
        const r = await supabase.functions.invoke("evolution-send", {
          body: {
            organization_id,
            instance_id,
            conversation_id: conversationId,
            type: "text",
            to: leadPhone,
            payload: { text },
          },
        });
        const data: any = r.data;
        const ok = !r.error && data?.ok !== false && !data?.error;
        const errorCode: string | null = data?.code || (data?.error === "PHONE_NOT_ON_WHATSAPP" ? "PHONE_NOT_ON_WHATSAPP" : null);
        const errorMsg =
          r.error?.message ||
          data?.message ||
          (typeof data?.error === "string" ? data.error : null) ||
          "evolution send failed";
        return { ok, errorCode, errorMsg, data };
      };

      for (let i = 0; i < bubbles.length; i++) {
        let res = await invokeEvo(bubbles[i]);

        // Retry para falso negativo quando houve inbound recente na conversa:
        // provavelmente é falso-negativo momentâneo do Baileys. Um único retry após 6s.
        if (!res.ok && (res.errorCode === "PHONE_NOT_ON_WHATSAPP" || res.errorCode === "WHATSAPP_VALIDATION_UNRELIABLE")) {
          const recentInbound = await hadRecentInbound(supabase, conversationId ?? null, 30);
          if (recentInbound) {
            console.warn(`[outreach-core] ${res.errorCode} com inbound recente — retry em 6s (lead=${leadId})`);
            await new Promise((r) => setTimeout(r, 6000));
            res = await invokeEvo(bubbles[i]);
          }
        }

        if (!res.ok) {
          lastError = res.errorMsg;
          lastErrorCode = res.errorCode;
          await logFailedMessage(supabase, conversationId, bubbles[i], res.errorMsg, {
            error_code: res.errorCode ?? undefined,
            error_detail: res.data ?? undefined,
            phone: leadPhone,
          });
          break;
        }

        const evoBody: any = (res.data as any)?.body ?? res.data;
        const evoMsgId: string | null =
          evoBody?.data?.Info?.ID ||
          evoBody?.data?.Info?.Id ||
          evoBody?.data?.info?.id ||
          evoBody?.key?.id ||
          evoBody?.messageId ||
          null;
        await supabase.from("webchat_messages").insert({
          conversation_id: conversationId,
          content: bubbles[i],
          sender_type: "bot",
          direction: "outbound",
          delivery_status: "sent",
          metadata: { outreach_mode: mode, ...(evoMsgId ? { external_id: evoMsgId, provider: "evolution" } : {}) },
        });
        sent = true;
        if (i < bubbles.length - 1) await new Promise((res) => setTimeout(res, 800));
      }
    }

    if (!sent) {
      if (connection_type === "meta_whatsapp" && !useTemplate && bubbles[0]) {
        await logFailedMessage(supabase, conversationId, bubbles[0], lastError || "send failed");
      }
      await reportProviderOutcome(supabase, connection_type, instance_id, false, lastError);
      // Notifica vendedor responsável — 1x por falha definitiva.
      await notifySellerDeliveryFailed(supabase, {
        organization_id,
        lead_id: leadId,
        conversation_id: conversationId ?? null,
        error_code: lastErrorCode || (/not.*whatsapp|PHONE_NOT_ON_WHATSAPP/i.test(lastError || "") ? "PHONE_NOT_ON_WHATSAPP" : null),
        error_message: lastError || "WhatsApp send failed",
      });
      return { leadId, error: lastError || "WhatsApp send failed", conversationId };
    }

    await reportProviderOutcome(supabase, connection_type, instance_id, true);


    // Outreach queue
    if (existingOutreach) {
      await supabase.from("ai_outreach_queue").update({
        objective: objective || "Abordagem manual retroativa",
        extra_context: extra_context ?? undefined,
        last_outreach_at: new Date().toISOString(),
        next_followup_at: new Date(Date.now() + 24 * 3600000).toISOString(),
        status: "sent",
        conversation_id: conversationId,
      }).eq("id", existingOutreach.id);
    } else {
      await supabase.from("ai_outreach_queue").insert({
        organization_id,
        lead_id: leadId,
        conversation_id: conversationId,
        product_id: agent.product_id,
        agent_id,
        objective: objective || "Abordagem manual retroativa",
        extra_context: extra_context ?? null,
        lead_data: { name: lead?.name, email: lead?.email, phone: leadPhone },
        status: "sent",
        followup_enabled: !useTemplate,
        followup_interval_hours: 24,
        max_followups: 2,
        followup_steps: [{ delay_hours: 24 }, { delay_hours: 48 }],
        business_hours_start: "09:00",
        business_hours_end: "18:00",
        business_days: [1, 2, 3, 4, 5],
        followups_sent: 0,
        last_outreach_at: new Date().toISOString(),
        next_followup_at: new Date(Date.now() + 24 * 3600000).toISOString(),
      });
    }

    return { leadId, name: lead?.name, sent: true, conversationId, via: useTemplate ? "template" : connection_type };
  } catch (err) {
    return { leadId, error: String(err) };
  }
}
