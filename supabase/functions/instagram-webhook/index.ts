// instagram-webhook — receiver público (Meta Instagram Messaging).
// URL: /functions/v1/instagram-webhook/{connection_id}
// GET handshake: ?hub.mode=subscribe&hub.verify_token=...&hub.challenge=...
// POST events: { object: "instagram", entry: [{ id: <ig_business_account_id>, messaging: [...] }] }
// HMAC SHA-256 validado com app_secret da conexão.
// verify_jwt = false.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { hmacSha256Hex, timingSafeEqual, GRAPH_BASE } from '../_shared/meta-graph.ts';
import { IG_GRAPH_BASE } from '../_shared/ig-graph.ts';
import { decryptSecret } from '../_shared/meta-crypto.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-hub-signature-256',
};

function supa() {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function extractConnectionIdFromPath(url: URL): string | null {
  const parts = url.pathname.split('/').filter(Boolean);
  const last = parts[parts.length - 1] ?? '';
  return UUID_RE.test(last) ? last : null;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const url = new URL(req.url);
  const pathConnectionId = extractConnectionIdFromPath(url);

  // ---------- GET handshake ----------
  if (req.method === 'GET') {
    const mode = url.searchParams.get('hub.mode');
    const token = url.searchParams.get('hub.verify_token');
    const challenge = url.searchParams.get('hub.challenge');
    // Compat: aceitar ?conn= como fallback caso o usuário tenha colado a URL antiga.
    const connId = pathConnectionId ?? url.searchParams.get('conn');
    if (mode !== 'subscribe' || !token || !challenge || !connId) {
      return new Response('bad request', { status: 400 });
    }
    const sb = supa();
    const { data: conn } = await sb
      .from('instagram_connections')
      .select('id, webhook_verify_token')
      .eq('id', connId)
      .maybeSingle();
    if (!conn || conn.webhook_verify_token !== token) {
      console.log('[ig-verify] reject', { has_path_id: !!pathConnectionId });
      return new Response('forbidden', { status: 403 });
    }
    await sb
      .from('instagram_connections')
      .update({ webhook_subscribed_at: new Date().toISOString() })
      .eq('id', conn.id);
    console.log('[ig-verify] ok', { connection_id: conn.id });
    return new Response(challenge, { status: 200, headers: { 'Content-Type': 'text/plain' } });
  }

  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });

  const rawBody = await req.text();
  let payload: any;
  try { payload = JSON.parse(rawBody); } catch { return new Response('invalid json', { status: 400 }); }

  if (payload?.object !== 'instagram') {
    return new Response('ok', { status: 200 });
  }

  const sb = supa();
  const sig = req.headers.get('x-hub-signature-256') ?? '';
  const entries = Array.isArray(payload.entry) ? payload.entry : [];

  // Resolver conexão: prioriza path; fallback resolve pelo entry.id (ig_business_account_id) entre conexões ativas.
  let resolvedConn: any = null;
  if (pathConnectionId) {
    const { data } = await sb
      .from('instagram_connections')
      .select('*')
      .eq('id', pathConnectionId)
      .maybeSingle();
    resolvedConn = data ?? null;
  }

  for (const entry of entries) {
    let conn = resolvedConn;
    if (!conn) {
      const entryId = String(entry?.id ?? '');
      if (!entryId) continue;
      const { data } = await sb
        .from('instagram_connections')
        .select('*')
        .eq('ig_business_account_id', entryId)
        .eq('status', 'active')
        .limit(1)
        .maybeSingle();
      conn = data ?? null;
    }
    if (!conn) {
      console.log('[ig-webhook] no connection match', { entry_id: entry?.id });
      continue;
    }

    // Valida HMAC
    let valid = false;
    let sigError: string | null = null;
    try {
      const appSecret = await decryptSecret(conn.app_secret_encrypted);
      if (!appSecret) {
        sigError = 'app_secret_missing';
      } else {
        const expected = 'sha256=' + (await hmacSha256Hex(appSecret, rawBody));
        valid = sig.length > 0 && timingSafeEqual(sig, expected);
      }
    } catch (e) {
      sigError = String((e as Error)?.message ?? e);
      console.error('[ig-webhook] sig check error', e);
    }
    if (!valid) {
      const summary = {
        reason: sigError ?? 'HMAC mismatch',
        entry_id: String(entry?.id ?? ''),
        sig_present: sig.length > 0,
        sig_prefix: sig ? sig.slice(0, 16) : null,
        has_messaging: Array.isArray(entry?.messaging) && entry.messaging.length > 0,
        has_changes: Array.isArray(entry?.changes) && entry.changes.length > 0,
        change_fields: Array.isArray(entry?.changes) ? entry.changes.map((c: any) => c?.field).filter(Boolean) : [],
      };
      await sb.from('instagram_webhook_logs').insert({
        connection_id: conn.id,
        organization_id: conn.organization_id,
        event_type: 'invalid_signature',
        payload: entry,
        payload_summary: summary,
        signature_valid: false,
        error: sigError ?? 'HMAC mismatch — App Secret salvo não bate com o do App da Meta',
      });
      if (sigError === 'app_secret_missing') {
        await sb.from('instagram_connections')
          .update({ status: 'error', last_error: 'app_secret ausente — reconfigure a integração' })
          .eq('id', conn.id);
      }
      return new Response('forbidden', { status: 403 });
    }

    // 1) DM events
    const messaging = Array.isArray(entry.messaging) ? entry.messaging : [];
    for (const m of messaging) {
      try {
        await handleEvent(sb, conn, m);
      } catch (e) {
        console.error('[ig-webhook] event error', e);
        await sb.from('instagram_webhook_logs').insert({
          connection_id: conn.id,
          organization_id: conn.organization_id,
          event_type: 'event_error',
          payload: m,
          signature_valid: true,
          error: String(e),
        });
      }
    }

    // 2) Comment / mention events (para automações ManyChat-style)
    const changes = Array.isArray(entry.changes) ? entry.changes : [];
    for (const ch of changes) {
      try {
        await handleChange(sb, conn, ch);
      } catch (e) {
        console.error('[ig-webhook] change error', e);
        await sb.from('instagram_webhook_logs').insert({
          connection_id: conn.id,
          organization_id: conn.organization_id,
          event_type: 'change_error',
          payload: ch,
          signature_valid: true,
          error: String(e),
        });
      }
    }
  }

  return new Response('ok', { status: 200, headers: { ...corsHeaders, 'Content-Type': 'text/plain' } });
});

async function handleEvent(sb: any, conn: any, evt: any) {
  if (evt?.message?.is_echo) return;

  const senderId = String(evt?.sender?.id ?? '');
  if (!senderId) return;

  const msg = evt.message ?? {};
  const mid = String(msg?.mid ?? '');
  if (!mid && !msg?.text && !msg?.attachments && !msg?.reaction) return;

  // 1) localizar conversa ATIVA desta caixa Instagram específica
  //    - filtra por instagram_connection_id (caixa isolada)
  //    - ignora conversas encerradas: nova msg após "Resolvido" abre conversa nova
  const { data: existing } = await sb
    .from('webchat_conversations')
    .select('id, status')
    .eq('organization_id', conn.organization_id)
    .eq('channel', 'instagram')
    .eq('instagram_connection_id', conn.id)
    .eq('ig_sender_id', senderId)
    .neq('status', 'closed')
    .order('last_message_at', { ascending: false, nullsFirst: false })
    .limit(1);

  let conversationId: string;
  let visitorName: string | null = null;

  try {
    if (conn.ig_auth_style === 'ig_user_token' && conn.ig_user_access_token_encrypted) {
      const token = await decryptSecret(conn.ig_user_access_token_encrypted);
      const prof = await fetch(`${IG_GRAPH_BASE}/${senderId}?fields=name,username&access_token=${encodeURIComponent(token)}`).then((r) => r.json());
      visitorName = prof?.name ?? prof?.username ?? null;
    } else if (conn.page_access_token_encrypted) {
      const token = await decryptSecret(conn.page_access_token_encrypted);
      const prof = await fetch(`${GRAPH_BASE}/${senderId}?fields=name,username&access_token=${encodeURIComponent(token)}`).then((r) => r.json());
      visitorName = prof?.name ?? prof?.username ?? null;
    }
  } catch { /* ignore */ }

  if (existing && existing.length > 0) {
    conversationId = existing[0].id;
    await sb.from('webchat_conversations').update({
      last_inbound_at: new Date().toISOString(),
      last_message_at: new Date().toISOString(),
      ...(visitorName ? { visitor_name: visitorName } : {}),
    }).eq('id', conversationId);

  } else {
    const { data: widget } = await sb
      .from('webchat_widgets')
      .select('id')
      .eq('organization_id', conn.organization_id)
      .eq('is_active', true)
      .limit(1)
      .maybeSingle();

    const { data: created, error: insErr } = await sb.from('webchat_conversations').insert({
      organization_id: conn.organization_id,
      widget_id: widget?.id ?? null,
      channel: 'instagram',
      status: 'bot_active',
      visitor_id: crypto.randomUUID(),
      visitor_name: visitorName ?? `Instagram ${senderId.slice(-4)}`,
      instagram_connection_id: conn.id,
      ig_sender_id: senderId,
      last_inbound_at: new Date().toISOString(),
      last_message_at: new Date().toISOString(),
    }).select('id').single();
    if (insErr) throw insErr;
    conversationId = created.id;
  }

  await sb.from('instagram_connections').update({ last_inbound_at: new Date().toISOString() }).eq('id', conn.id);

  // 2) extrair conteúdo
  const { content, contentType, metadata } = await extractContent(msg, conn);

  // 3) inserir mensagem (idempotente por ig_message_id)
  const { error: msgErr } = await sb.from('webchat_messages').insert({
    conversation_id: conversationId,
    direction: 'inbound',
    sender_type: 'visitor',
    content,
    content_type: contentType,
    message_type: contentType,
    ig_message_id: mid || null,
    metadata,
  });
  if (msgErr && (msgErr as any).code !== '23505') throw msgErr;

  await sb.from('instagram_webhook_logs').insert({
    connection_id: conn.id,
    organization_id: conn.organization_id,
    event_type: 'inbound',
    payload: evt,
    signature_valid: true,
  });

  // 4) Automações ManyChat-style: verifica fluxos ativos com trigger dm_keyword / story_reply
  const isStoryReply = !!(evt?.message?.reply_to?.story || (metadata as any)?.ig_type === 'story_mention');
  let flowMatched = false;
  try {
    const { data: flows } = await sb.from('instagram_flows')
      .select('*').eq('organization_id', conn.organization_id)
      .in('trigger_type', isStoryReply ? ['story_reply','dm_keyword'] : ['dm_keyword'])
      .eq('status', 'active');
    for (const flow of flows ?? []) {
      if (flow.connection_id && flow.connection_id !== conn.id) continue;
      if (!matchesDmTrigger(flow, content)) continue;
      flowMatched = true;
      await sb.functions.invoke('ig-flow-executor', {
        body: {
          flow_id: flow.id, connection_id: conn.id,
          trigger_source: isStoryReply ? 'story_reply' : 'dm',
          source_id: mid, sender_ig_id: senderId,
          conversation_id: conversationId, trigger_text: content, sender_name: visitorName,
        },
      });
    }
  } catch (fe) {
    console.error('[ig-webhook] flow trigger error', fe);
  }

  // 5) Se nenhum fluxo casou, cai no webchat-bot padrão
  if (!flowMatched) {
    try {
      const transcription = (metadata as any)?.transcription as string | undefined;
      const botMessage = transcription && transcription.trim().length > 0
        ? transcription
        : (content && content.trim().length > 0 ? content : '[mensagem]');
      const { data: botRes } = await sb.functions.invoke('webchat-bot', {
        body: {
          conversation_id: conversationId,
          message: botMessage,
          channel: 'instagram',
          trigger: 'inbound_instagram',
        },
      });
      const chunks: string[] = Array.isArray((botRes as any)?.chunks)
        ? (botRes as any).chunks
        : ((botRes as any)?.response ? [(botRes as any).response] : []);
      for (const chunk of chunks) {
        if (!chunk || typeof chunk !== 'string') continue;
        await sb.functions.invoke('instagram-send', {
          body: { connection_id: conn.id, conversation_id: conversationId, recipient_id: senderId, text: chunk },
        });
        await new Promise((r) => setTimeout(r, 800));
      }
    } catch (e) {
      console.error('[ig-webhook] webchat-bot invoke error', e);
    }
  }
}

function matchesDmTrigger(flow: any, text: string): boolean {
  const cfg = flow.trigger_config ?? {};
  const keywords: string[] = Array.isArray(cfg.keywords) ? cfg.keywords.filter(Boolean) : [];
  if (keywords.length === 0) return false; // dm_keyword sem keywords não dispara
  const match = cfg.match ?? 'any';
  const cs = !!cfg.case_sensitive;
  const t = cs ? text : text.toLowerCase();
  const ks = cs ? keywords : keywords.map(k => String(k).toLowerCase());
  if (match === 'exact') return ks.some(k => t.trim() === k.trim());
  if (match === 'all') return ks.every(k => t.includes(k));
  if (match === 'regex') {
    try { return ks.some(k => new RegExp(k, cs ? '' : 'i').test(text)); } catch { return false; }
  }
  return ks.some(k => t.includes(k));
}

async function extractContent(msg: any, conn: any): Promise<{ content: string; contentType: string; metadata: Record<string, any> }> {
  if (msg?.text) return { content: String(msg.text), contentType: 'text', metadata: { ig_type: 'text' } };

  const atts = Array.isArray(msg?.attachments) ? msg.attachments : [];
  if (atts.length > 0) {
    const a = atts[0];
    const t = a?.type ?? 'file';
    const url = a?.payload?.url ?? null;
    let stored: { url: string | null; path: string; mime: string; bytes: Uint8Array } | null = null;
    if (url && msg?.mid) {
      try { stored = await downloadAndStoreMedia(conn, msg.mid, url, t); } catch (e) { console.error('[ig-webhook] media err', e); }
    }
    const kindMap: Record<string, 'image' | 'audio' | 'video' | 'document' | 'sticker'> = {
      image: 'image', audio: 'audio', video: 'video', file: 'document', story_mention: 'image', ig_reel: 'video',
    };
    const ctMap: Record<string, string> = {
      image: 'image', audio: 'audio', video: 'video', file: 'file', story_mention: 'image', share: 'text', ig_reel: 'file',
    };
    const kind = kindMap[t] ?? 'document';
    const labelByKind: Record<string, string> = {
      audio: '[áudio]', image: '[imagem]', video: '[vídeo]', document: '[arquivo]', sticker: '[figurinha]',
    };
    const meta: Record<string, any> = {
      ig_type: t,
      attachments: atts,
      media: stored?.url ? {
        url: stored.url,
        kind,
        mime: stored.mime,
        storage_path: stored.path,
        size_bytes: stored.bytes?.byteLength ?? null,
      } : null,
    };

    if ((kind === 'audio' || kind === 'image') && stored?.bytes) {
      try {
        const b64 = bytesToBase64(stored.bytes);
        const sb = supa();
        const mediaKind: 'audio' | 'image' = kind === 'audio' ? 'audio' : 'image';
        const { data: tRes } = await sb.functions.invoke('process-media-message', {
          body: {
            kind: mediaKind,
            base64: b64,
            mime: stored.mime ?? (mediaKind === 'audio' ? 'audio/mp4' : 'image/jpeg'),
            organization_id: conn.organization_id,
          },
        });
        const txt = (tRes as any)?.text ? String((tRes as any).text).trim() : '';
        if (txt) {
          meta.transcription = mediaKind === 'audio'
            ? `🎙️ Áudio do cliente (transcrito): ${txt}`
            : `🖼️ Imagem do cliente: ${txt}`;
        } else {
          meta.transcription = mediaKind === 'audio'
            ? '🎙️ [Áudio recebido — não consegui transcrever. Peça ao cliente para reenviar ou descrever em texto.]'
            : '🖼️ [Imagem recebida — não consegui analisar o conteúdo. Peça para reenviar ou descrever.]';
          console.warn(`[ig-webhook] media NOT processed (${mediaKind}); fallback placeholder`);
        }
      } catch (tErr) {
        console.warn('[ig-webhook] media processing failed:', (tErr as any)?.message ?? tErr);
        meta.transcription = kind === 'audio'
          ? '🎙️ [Áudio recebido — não consegui transcrever.]'
          : '🖼️ [Imagem recebida — não consegui analisar.]';
      }
    }

    return {
      content: stored?.url ? (labelByKind[kind] ?? `[${t}]`) : (url ?? `[${t}]`),
      contentType: ctMap[t] ?? 'text',
      metadata: meta,
    };
  }

  if (msg?.reaction) return { content: String(msg.reaction.emoji ?? '❤️'), contentType: 'text', metadata: { ig_type: 'reaction', reaction: msg.reaction } };

  return { content: '[mensagem]', contentType: 'text', metadata: { ig_type: 'unknown', raw: msg } };
}

async function downloadAndStoreMedia(conn: any, mid: string, url: string, type: string): Promise<{ url: string | null; path: string; mime: string; bytes: Uint8Array }> {
  const bin = await fetch(url);
  if (!bin.ok) throw new Error(`download ${bin.status}`);
  const buf = new Uint8Array(await bin.arrayBuffer());
  const ct = bin.headers.get('content-type') ?? 'application/octet-stream';
  const ext = guessExt(ct, type);
  const path = `${conn.organization_id}/${conn.id}/${mid}${ext}`;
  const sb = supa();
  const { error } = await sb.storage.from('instagram-media').upload(path, buf, { contentType: ct, upsert: true });
  if (error) throw error;
  const { data: signed } = await sb.storage.from('instagram-media').createSignedUrl(path, 60 * 60 * 24 * 7);
  return { url: signed?.signedUrl ?? null, path, mime: ct, bytes: buf };
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, Array.from(bytes.subarray(i, i + chunk)) as any);
  }
  return btoa(binary);
}

function guessExt(mime: string, type: string): string {
  if (mime.includes('jpeg')) return '.jpg';
  if (mime.includes('png')) return '.png';
  if (mime.includes('webp')) return '.webp';
  if (mime.includes('mp4')) return '.mp4';
  if (mime.includes('ogg')) return '.ogg';
  if (mime.includes('mpeg')) return '.mp3';
  if (type === 'image') return '.jpg';
  if (type === 'video') return '.mp4';
  if (type === 'audio') return '.mp3';
  return '';
}

// ============================================================
// AUTOMAÇÕES ManyChat-style: comments / mentions
// ============================================================
async function handleChange(sb: any, conn: any, change: any) {
  const field = String(change?.field ?? '');
  const value = change?.value ?? {};

  await sb.from('instagram_webhook_logs').insert({
    connection_id: conn.id,
    organization_id: conn.organization_id,
    event_type: `change:${field}`,
    payload: change,
    signature_valid: true,
  });

  if (field === 'comments') {
    const commentId = String(value?.id ?? '');
    const fromId = String(value?.from?.id ?? '');
    const fromUser = String(value?.from?.username ?? '');
    const text = String(value?.text ?? '');
    const mediaId = String(value?.media?.id ?? '');
    if (!commentId || !text) return;
    // skip próprio: se from === ig_business_account_id
    if (fromId && fromId === String(conn.ig_business_account_id)) return;
    // dedup
    const { data: dup } = await sb.from('instagram_comment_replies')
      .select('id').eq('connection_id', conn.id).eq('comment_id', commentId).maybeSingle();
    if (dup) return;

    // buscar fluxos ativos com trigger comment_keyword para esta conexão (ou "qualquer conta")
    const { data: flows } = await sb.from('instagram_flows')
      .select('*')
      .eq('organization_id', conn.organization_id)
      .in('trigger_type', ['comment_keyword','mention'])
      .eq('status', 'active');

    for (const flow of flows ?? []) {
      if (flow.connection_id && flow.connection_id !== conn.id) continue;
      if (!matchesCommentTrigger(flow, text, mediaId)) continue;
      await sb.functions.invoke('ig-flow-executor', {
        body: {
          flow_id: flow.id,
          connection_id: conn.id,
          trigger_source: 'comment',
          source_id: commentId,
          comment_id: commentId,
          sender_ig_id: fromId || null,
          sender_name: fromUser || null,
          trigger_text: text,
        },
      });
    }
    return;
  }

  if (field === 'mentions') {
    const mediaId = String(value?.media_id ?? '');
    const commentId = String(value?.comment_id ?? '');
    const { data: flows } = await sb.from('instagram_flows')
      .select('*').eq('organization_id', conn.organization_id).eq('trigger_type', 'mention').eq('status', 'active');
    for (const flow of flows ?? []) {
      if (flow.connection_id && flow.connection_id !== conn.id) continue;
      await sb.functions.invoke('ig-flow-executor', {
        body: {
          flow_id: flow.id, connection_id: conn.id, trigger_source: 'mention',
          source_id: commentId || mediaId, comment_id: commentId || null,
        },
      });
    }
    return;
  }
}

function matchesCommentTrigger(flow: any, text: string, mediaId: string): boolean {
  const cfg = flow.trigger_config ?? {};
  // post filter
  const postIds: string[] = Array.isArray(cfg.post_ids) ? cfg.post_ids.filter(Boolean) : [];
  if (postIds.length > 0 && mediaId && !postIds.includes(mediaId)) return false;
  const keywords: string[] = Array.isArray(cfg.keywords) ? cfg.keywords.filter(Boolean) : [];
  if (keywords.length === 0) return true; // "qualquer comentário"
  const match = cfg.match ?? 'any';
  const cs = !!cfg.case_sensitive;
  const t = cs ? text : text.toLowerCase();
  const ks = cs ? keywords : keywords.map(k => String(k).toLowerCase());
  if (match === 'exact') return ks.some(k => t.trim() === k.trim());
  if (match === 'all') return ks.every(k => t.includes(k));
  if (match === 'regex') {
    try { return ks.some(k => new RegExp(k, cs ? '' : 'i').test(text)); } catch { return false; }
  }
  return ks.some(k => t.includes(k));
}

