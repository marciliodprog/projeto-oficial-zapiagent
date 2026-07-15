// ig-flow-executor — executa blocos de um instagram_flow linearmente.
// Contexto: { flow_id, connection_id, trigger_source, source_id?, sender_ig_id?, comment_id?, conversation_id?, trigger_text?, dry_run? }

import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(b: unknown, status = 200) {
  return new Response(JSON.stringify(b), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
}

function supa() {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
}

type StepResult = { block_id: string; type: string; ok: boolean; error?: string; info?: any; duration_ms?: number };

const BLOCK_TIMEOUT_MS = 25_000;

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const sb = supa();
  const ctx: any = await req.json().catch(() => ({}));
  const { flow_id, connection_id, trigger_source, source_id, sender_ig_id, comment_id, conversation_id, trigger_text, dry_run } = ctx ?? {};

  if (!flow_id) return json({ error: 'flow_id required' }, 400);

  const { data: flow } = await sb.from('instagram_flows').select('*').eq('id', flow_id).maybeSingle();
  if (!flow) return json({ error: 'flow not found' }, 404);
  if (!dry_run && flow.status !== 'active') return json({ ok: true, skipped: 'flow not active' });

  const connId = connection_id ?? flow.connection_id;

  // Dedup por comentário
  if (!dry_run && comment_id && connId) {
    const { error: dedupErr } = await sb.from('instagram_comment_replies')
      .insert({ connection_id: connId, comment_id, flow_id });
    if (dedupErr && (dedupErr as any).code === '23505') {
      return json({ ok: true, skipped: 'duplicate_comment' });
    }
  }

  // throttle por sender — grava run visível como 'skipped' em vez de sumir
  if (!dry_run && sender_ig_id && flow.throttle_per_sender_hours > 0) {
    const cutoff = new Date(Date.now() - flow.throttle_per_sender_hours * 3600 * 1000).toISOString();
    const { data: recent } = await sb.from('instagram_flow_runs')
      .select('id, started_at').eq('flow_id', flow_id).eq('sender_ig_id', sender_ig_id)
      .in('status', ['completed', 'partial', 'running'])
      .gte('started_at', cutoff).order('started_at', { ascending: false }).limit(1);
    if (recent && recent.length > 0) {
      const now = new Date().toISOString();
      const nextAllowedAt = new Date(
        new Date(recent[0].started_at).getTime() + flow.throttle_per_sender_hours * 3600 * 1000,
      ).toISOString();
      await sb.from('instagram_flow_runs').insert({
        organization_id: flow.organization_id,
        flow_id,
        connection_id: connId,
        trigger_source: trigger_source || 'manual',
        source_id: source_id ?? comment_id ?? null,
        sender_ig_id,
        conversation_id: conversation_id ?? null,
        status: 'skipped',
        error: 'throttled_by_sender',
        started_at: now,
        finished_at: now,
        payload: {
          trigger_text,
          ctx,
          skip_reason: 'throttled_by_sender',
          throttle_hours: flow.throttle_per_sender_hours,
          previous_run_id: recent[0].id,
          previous_run_at: recent[0].started_at,
          next_allowed_at: nextAllowedAt,
        },
      });
      return json({ ok: true, skipped: 'throttled', throttle_hours: flow.throttle_per_sender_hours, next_allowed_at: nextAllowedAt });
    }
  }


  const blocks: any[] = Array.isArray(flow.flow_blocks) ? flow.flow_blocks : [];
  const startId: string | null = flow.start_block_id || blocks[0]?.id || null;
  if (!startId) return json({ ok: true, skipped: 'empty flow' });

  // Para comment triggers: resolver eagerly conversa + lead pelo sender_ig_id.
  // Assim os blocos apply_tag / assign_lead / enroll_cadence funcionam mesmo sem DM prévia,
  // e o private_reply enviado depois aparece no Conversas.
  if (!dry_run && trigger_source === 'comment' && sender_ig_id && connId && !conversation_id) {
    try {
      const resolved = await ensureConversationAndLead(sb, flow, connId, sender_ig_id, ctx.sender_name);
      if (resolved.conversation_id) ctx.conversation_id = resolved.conversation_id;
      if (resolved.lead_id) ctx.lead_id = resolved.lead_id;
    } catch (e) {
      console.error('[ig-flow-executor] resolve conversation error', e);
    }
  }

  let runId: string | null = null;
  if (!dry_run) {
    const { data: run } = await sb.from('instagram_flow_runs').insert({
      organization_id: flow.organization_id,
      flow_id,
      connection_id: connId,
      trigger_source: trigger_source || 'manual',
      source_id: source_id ?? comment_id ?? null,
      sender_ig_id: sender_ig_id ?? null,
      conversation_id: ctx.conversation_id ?? null,
      status: 'running',
      payload: { trigger_text, ctx },
    }).select('id').single();
    runId = run?.id ?? null;
  }

  const executed: string[] = [];
  const stepResults: StepResult[] = [];
  const dryPlan: Array<{ block_id: string; type: string; action: string; preview?: string }> = [];

  try {
    const byId = new Map(blocks.map(b => [b.id, b]));
    let currentId: string | null = startId;
    let safety = 50;
    while (currentId && safety-- > 0) {
      const block = byId.get(currentId);
      if (!block) break;
      executed.push(block.id);
      let nextOverride: string | null = null;
      if (dry_run) {
        nextOverride = simulateBlock(block, ctx, dryPlan);
      } else {
        const started = Date.now();
        const res = await executeBlockWithTimeout(sb, flow, block, ctx);
        stepResults.push({
          block_id: block.id,
          type: block.type,
          ok: res.ok,
          error: res.error,
          info: res.info,
          duration_ms: Date.now() - started,
        });
        nextOverride = res.next ?? null;
      }
      currentId = nextOverride ?? (block.next_block_id || block.data?.next_block_id || null);
    }
    if (dry_run) return json({ ok: true, dry_run: true, plan: dryPlan, executed });

    const anyFailed = stepResults.some(s => !s.ok);
    const finalStatus = anyFailed ? 'partial' : 'completed';
    await sb.from('instagram_flow_runs').update({
      status: finalStatus,
      finished_at: new Date().toISOString(),
      conversation_id: ctx.conversation_id ?? null,
      error: anyFailed ? stepResults.filter(s => !s.ok).map(s => `${s.type}: ${s.error}`).join(' | ').slice(0, 500) : null,
      payload: { trigger_text, ctx, executed, step_results: stepResults },
    }).eq('id', runId);
    return json({ ok: true, run_id: runId, executed, step_results: stepResults, status: finalStatus });
  } catch (e) {
    console.error('[ig-flow-executor] fatal', e);
    if (!dry_run) {
      await sb.from('instagram_flow_runs').update({
        status: 'failed', finished_at: new Date().toISOString(), error: String((e as Error).message ?? e),
        payload: { trigger_text, ctx, executed, step_results: stepResults },
      }).eq('id', runId);
    }
    return json({ error: String(e) }, 500);
  }
});

async function ensureConversationAndLead(
  sb: any,
  flow: any,
  connId: string,
  senderIgId: string,
  senderName?: string | null,
): Promise<{ conversation_id: string | null; lead_id: string | null }> {
  // 1) Conversa
  const { data: existing } = await sb
    .from('webchat_conversations')
    .select('id, lead_id')
    .eq('organization_id', flow.organization_id)
    .eq('channel', 'instagram')
    .eq('instagram_connection_id', connId)
    .eq('ig_sender_id', senderIgId)
    .neq('status', 'closed')
    .order('last_message_at', { ascending: false, nullsFirst: false })
    .limit(1)
    .maybeSingle();

  let convId: string | null = existing?.id ?? null;
  let leadId: string | null = existing?.lead_id ?? null;

  if (!convId) {
    const { data: widget } = await sb
      .from('webchat_widgets')
      .select('id')
      .eq('organization_id', flow.organization_id)
      .eq('is_active', true)
      .limit(1)
      .maybeSingle();

    const { data: created, error: convErr } = await sb.from('webchat_conversations').insert({
      organization_id: flow.organization_id,
      widget_id: widget?.id ?? null,
      channel: 'instagram',
      status: 'bot_active',
      visitor_id: crypto.randomUUID(),
      visitor_name: senderName || `Instagram ${senderIgId.slice(-4)}`,
      instagram_connection_id: connId,
      ig_sender_id: senderIgId,
      last_message_at: new Date().toISOString(),
    }).select('id').single();
    if (convErr) throw convErr;
    convId = created.id;
  }

  // 2) Lead — auto-create se não existir
  if (!leadId && convId) {
    const leadName = senderName || `Instagram ${senderIgId.slice(-4)}`;
    const { data: createdLead, error: leadErr } = await sb.from('leads').insert({
      organization_id: flow.organization_id,
      name: leadName,
      source: 'instagram',
      notes: `Instagram: @${senderName ?? ''} (id ${senderIgId})`,
    }).select('id').single();
    if (!leadErr && createdLead?.id) {
      leadId = createdLead.id;
      await sb.from('webchat_conversations').update({ lead_id: leadId }).eq('id', convId);
    } else if (leadErr) {
      console.error('[ig-flow-executor] auto-create lead failed', leadErr);
    }
  }

  return { conversation_id: convId, lead_id: leadId };
}

function simulateBlock(block: any, ctx: any, plan: any[]): string | null {
  const d = block.data ?? {};
  const type = block.type;
  const preview = renderTemplate(d.text ?? d.prompt ?? '', ctx).slice(0, 200);
  switch (type) {
    case 'ig_reply_comment': plan.push({ block_id: block.id, type, action: 'Responder comentário publicamente', preview }); return null;
    case 'ig_private_reply': plan.push({ block_id: block.id, type, action: 'Enviar DM privada ao autor do comentário', preview }); return null;
    case 'ig_like_comment': plan.push({ block_id: block.id, type, action: 'Curtir comentário' }); return null;
    case 'ig_send_dm': case 'message': case 'text':
      plan.push({ block_id: block.id, type, action: 'Enviar mensagem no DM', preview }); return null;
    case 'wait': plan.push({ block_id: block.id, type, action: `Aguardar ${d.seconds ?? 1}s` }); return null;
    case 'apply_tag': plan.push({ block_id: block.id, type, action: `Aplicar tag ${d.tag_name ?? d.tag_id ?? '?'}` }); return null;
    case 'ai_takeover': plan.push({ block_id: block.id, type, action: 'IA assume a conversa', preview }); return null;
    case 'enroll_cadence': plan.push({ block_id: block.id, type, action: `Inscrever lead na cadência ${d.cadence_name ?? d.cadence_id ?? '?'}` }); return null;
    case 'assign_lead': plan.push({ block_id: block.id, type, action: `Atribuir lead` }); return null;
    case 'condition_text': case 'condition': {
      const keywords: string[] = Array.isArray(d.keywords) ? d.keywords : [];
      const match = d.match ?? 'any';
      const text = String(ctx.trigger_text ?? '').toLowerCase();
      let ok = false;
      if (keywords.length === 0) ok = true;
      else if (match === 'all') ok = keywords.every(k => text.includes(String(k).toLowerCase()));
      else if (match === 'exact') ok = keywords.some(k => text.trim() === String(k).toLowerCase().trim());
      else ok = keywords.some(k => text.includes(String(k).toLowerCase()));
      plan.push({ block_id: block.id, type, action: `Condição: ${ok ? 'verdadeiro' : 'falso'}` });
      return ok ? (d.true_next_block_id ?? null) : (d.false_next_block_id ?? null);
    }
  }
  return null;
}

async function safeInvoke(sb: any, fn: string, body: any): Promise<{ ok: boolean; data?: any; error?: string }> {
  try {
    const { data, error } = await sb.functions.invoke(fn, { body });
    if (error) {
      let details = '';
      try {
        const ctx = (error as any)?.context;
        if (ctx?.text) details = await ctx.text();
      } catch { /* ignore */ }
      return { ok: false, error: details || (error as any)?.message || String(error), data };
    }
    // instagram-send retorna { error } com status !=2xx — mas o SDK sobe error acima.
    // Se por acaso a função respondeu 200 com { error }, capturamos aqui.
    if (data && typeof data === 'object' && (data as any).error) {
      return { ok: false, error: String((data as any).error), data };
    }
    return { ok: true, data };
  } catch (e) {
    return { ok: false, error: (e as Error)?.message ?? String(e) };
  }
}

async function executeBlockWithTimeout(
  sb: any,
  flow: any,
  block: any,
  ctx: any,
): Promise<{ ok: boolean; error?: string; info?: any; next?: string | null }> {
  let timer: number | undefined;
  try {
    return await Promise.race([
      executeBlock(sb, flow, block, ctx),
      new Promise<{ ok: boolean; error: string }>((resolve) => {
        timer = setTimeout(() => resolve({
          ok: false,
          error: `timeout_${Math.round(BLOCK_TIMEOUT_MS / 1000)}s`,
        }), BLOCK_TIMEOUT_MS) as unknown as number;
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function executeBlock(
  sb: any,
  flow: any,
  block: any,
  ctx: any,
): Promise<{ ok: boolean; error?: string; info?: any; next?: string | null }> {
  const d = block.data ?? {};
  const type = block.type;
  const connId = ctx.connection_id ?? flow.connection_id;

  switch (type) {
    case 'ig_reply_comment': {
      if (!ctx.comment_id || !d.text) return { ok: false, error: 'faltam comment_id/text' };
      const r = await safeInvoke(sb, 'instagram-send', {
        type: 'comment_reply', connection_id: connId, comment_id: ctx.comment_id, text: renderTemplate(d.text, ctx),
      });
      return { ok: r.ok, error: r.error };
    }
    case 'ig_private_reply': {
      if (!ctx.comment_id || !d.text) return { ok: false, error: 'faltam comment_id/text' };
      const r = await safeInvoke(sb, 'instagram-send', {
        type: 'private_reply',
        connection_id: connId,
        comment_id: ctx.comment_id,
        sender_ig_id: ctx.sender_ig_id ?? null,
        sender_name: ctx.sender_name ?? null,
        text: renderTemplate(d.text, ctx),
        quick_replies: d.quick_replies,
        buttons: d.buttons,
      });
      // Se instagram-send criou/retornou conversation_id, usa daqui pra frente
      if (r.ok && r.data?.conversation_id) ctx.conversation_id = r.data.conversation_id;
      return { ok: r.ok, error: r.error, info: r.data };
    }
    case 'ig_like_comment': {
      if (!ctx.comment_id) return { ok: false, error: 'falta comment_id' };
      const r = await safeInvoke(sb, 'instagram-send', {
        type: 'like_comment', connection_id: connId, comment_id: ctx.comment_id,
      });
      return { ok: r.ok, error: r.error };
    }
    case 'ig_send_dm': case 'message': case 'text': {
      if (!ctx.sender_ig_id && !ctx.conversation_id) return { ok: false, error: 'sem destinatário' };
      const r = await safeInvoke(sb, 'instagram-send', {
        type: 'dm',
        connection_id: connId,
        conversation_id: ctx.conversation_id,
        recipient_id: ctx.sender_ig_id,
        text: renderTemplate(d.text ?? d.content ?? '', ctx),
        media: d.media,
        quick_replies: d.quick_replies,
        buttons: d.buttons,
      });
      if (r.ok && r.data?.conversation_id) ctx.conversation_id = r.data.conversation_id;
      return { ok: r.ok, error: r.error };
    }
    case 'wait': case 'delay': {
      const secs = Math.min(30, Number(d.seconds ?? d.delay_seconds ?? 1));
      await new Promise((r) => setTimeout(r, secs * 1000));
      return { ok: true };
    }
    case 'apply_tag': {
      if (!d.tag_id) return { ok: false, error: 'tag_id ausente no bloco' };
      // Resolver lead_id em cascata: ctx.lead_id → conv.lead_id → criar
      let leadId: string | null = ctx.lead_id ?? null;
      if (!leadId && ctx.conversation_id) {
        const { data: conv } = await sb.from('webchat_conversations').select('lead_id').eq('id', ctx.conversation_id).maybeSingle();
        leadId = conv?.lead_id ?? null;
      }
      if (!leadId && ctx.sender_ig_id) {
        try {
          const resolved = await ensureConversationAndLead(sb, flow, connId, ctx.sender_ig_id, ctx.sender_name);
          if (resolved.conversation_id) ctx.conversation_id = resolved.conversation_id;
          if (resolved.lead_id) { leadId = resolved.lead_id; ctx.lead_id = leadId; }
        } catch (e) {
          return { ok: false, error: `resolve lead: ${(e as Error).message}` };
        }
      }
      if (!leadId) return { ok: false, error: 'sem lead para aplicar tag' };
      const { error: tagErr } = await sb.from('lead_tag_assignments').upsert(
        { lead_id: leadId, tag_id: d.tag_id, source: 'automation' },
        { onConflict: 'lead_id,tag_id' },
      );
      if (tagErr) return { ok: false, error: tagErr.message };
      return { ok: true, info: { lead_id: leadId, tag_id: d.tag_id } };
    }
    case 'ai_takeover': {
      if (!ctx.conversation_id) return { ok: false, error: 'sem conversation_id' };
      const msg = ctx.trigger_text || d.prompt || '[iniciar atendimento]';
      const r = await safeInvoke(sb, 'webchat-bot', {
        conversation_id: ctx.conversation_id, message: msg, channel: 'instagram',
        trigger: 'ig_flow_ai_takeover', override_agent_id: d.agent_id,
      });
      if (!r.ok) return { ok: false, error: r.error };
      const chunks: string[] = Array.isArray(r.data?.chunks) ? r.data.chunks : (r.data?.response ? [r.data.response] : []);
      for (const chunk of chunks) {
        if (!chunk) continue;
        await safeInvoke(sb, 'instagram-send', {
          type: 'dm', connection_id: connId, conversation_id: ctx.conversation_id, recipient_id: ctx.sender_ig_id, text: chunk,
        });
        await new Promise((r) => setTimeout(r, 800));
      }
      return { ok: true };
    }
    case 'enroll_cadence': {
      if (!d.cadence_id) return { ok: false, error: 'cadence_id ausente' };
      let leadId: string | null = ctx.lead_id ?? null;
      if (!leadId && ctx.conversation_id) {
        const { data: conv } = await sb.from('webchat_conversations').select('lead_id').eq('id', ctx.conversation_id).maybeSingle();
        leadId = conv?.lead_id ?? null;
      }
      if (!leadId) return { ok: false, error: 'sem lead para cadência' };
      const r = await safeInvoke(sb, 'cadence-enroll', {
        cadence_id: d.cadence_id, lead_ids: [leadId], source: 'instagram_flow', source_ref: { flow_id: flow.id },
      });
      return { ok: r.ok, error: r.error };
    }
    case 'assign_lead': {
      let leadId: string | null = ctx.lead_id ?? null;
      if (!leadId && ctx.conversation_id) {
        const { data: conv } = await sb.from('webchat_conversations').select('lead_id').eq('id', ctx.conversation_id).maybeSingle();
        leadId = conv?.lead_id ?? null;
      }
      if (!leadId) return { ok: false, error: 'sem lead para atribuir' };
      const patch: any = {};
      if (d.sector_id) patch.sector_id = d.sector_id;
      if (d.user_id) { patch.assigned_seller_id = d.user_id; patch.closer_id = d.user_id; }
      if (Object.keys(patch).length) {
        const { error: upErr } = await sb.from('leads').update(patch).eq('id', leadId);
        if (upErr) return { ok: false, error: upErr.message };
        if (ctx.conversation_id) {
          if (d.sector_id) await sb.from('webchat_conversations').update({ sector_id: d.sector_id }).eq('id', ctx.conversation_id);
          if (d.user_id) await sb.from('webchat_conversations').update({ assigned_to: d.user_id }).eq('id', ctx.conversation_id);
        }
      }
      return { ok: true };
    }
    case 'condition_text': case 'condition': {
      const keywords: string[] = Array.isArray(d.keywords) ? d.keywords : [];
      const match = d.match ?? 'any';
      const text = String(ctx.trigger_text ?? '').toLowerCase();
      let ok = false;
      if (keywords.length === 0) ok = true;
      else if (match === 'all') ok = keywords.every(k => text.includes(String(k).toLowerCase()));
      else if (match === 'exact') ok = keywords.some(k => text.trim() === String(k).toLowerCase().trim());
      else ok = keywords.some(k => text.includes(String(k).toLowerCase()));
      return { ok: true, next: ok ? (d.true_next_block_id ?? null) : (d.false_next_block_id ?? null) };
    }
    default:
      console.warn('[ig-flow-executor] unknown block type', type);
      return { ok: false, error: `bloco desconhecido: ${type}` };
  }
}

function renderTemplate(t: string, ctx: any): string {
  return String(t ?? '').replace(/\{\{\s*(\w+)\s*\}\}/g, (_, k) => {
    if (k === 'text' || k === 'trigger_text') return String(ctx.trigger_text ?? '');
    if (k === 'sender') return String(ctx.sender_name ?? '');
    return '';
  });
}
