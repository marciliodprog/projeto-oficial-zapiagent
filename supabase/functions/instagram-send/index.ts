// instagram-send
// Envia DM/comment reply/like. Suporta 2 modos:
//   - page_token (legado): POST graph.facebook.com/{page_id}/messages
//   - ig_user_token (novo): POST graph.instagram.com/{ig_user_id}/messages
// recipient.id = ig_sender_id (PSID/IG-scoped id).
// Detecta janela 24h via RPC is_within_24h_window.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { graphFetch, GraphError } from '../_shared/meta-graph.ts';
import { igGraphFetch, IgGraphError } from '../_shared/ig-graph.ts';
import { decryptSecret } from '../_shared/meta-crypto.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

type IgFetcher = <T = unknown>(path: string, init?: RequestInit) => Promise<T>;

/** Retorna um fetcher que já embute o token e o base URL correto do modo da conexão. */
async function buildFetcher(conn: any): Promise<{ fetcher: IgFetcher; ownerId: string; mode: 'page_token' | 'ig_user_token' }> {
  if (conn.ig_auth_style === 'ig_user_token') {
    if (!conn.ig_user_access_token_encrypted) throw new Error('conexão sem IG User Access Token');
    const token = await decryptSecret(conn.ig_user_access_token_encrypted);
    const fetcher: IgFetcher = (path, init = {}) => igGraphFetch(path, token, init);
    return { fetcher, ownerId: String(conn.ig_business_account_id), mode: 'ig_user_token' };
  }
  if (!conn.page_access_token_encrypted || !conn.fb_page_id) throw new Error('conexão sem Page Token/Page ID');
  const token = await decryptSecret(conn.page_access_token_encrypted);
  const fetcher: IgFetcher = (path, init = {}) => graphFetch(path, token, init);
  return { fetcher, ownerId: String(conn.fb_page_id), mode: 'page_token' };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Unauthorized' }, 401);

  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const body = await req.json().catch(() => ({}));
  const {
    connection_id,
    organization_id,
    conversation_id,
    recipient_id,
    text,
    media,
    tag,
    type,
    comment_id,
    quick_replies,
    buttons,
    sender_ig_id,
    sender_name,
  } = body ?? {};

  const sendType: string = type || 'dm';

  // --- COMMENT REPLY (público) ---
  if (sendType === 'comment_reply') {
    if (!connection_id || !comment_id || !text) return json({ error: 'connection_id, comment_id e text são obrigatórios' }, 400);
    const { data: conn } = await sb.from('instagram_connections').select('*').eq('id', connection_id).maybeSingle();
    if (!conn) return json({ error: 'connection not found' }, 404);
    try {
      const { fetcher } = await buildFetcher(conn);
      const res = await fetcher<any>(`/${comment_id}/replies?message=${encodeURIComponent(String(text))}`, { method: 'POST' });
      await sb.from('instagram_comment_replies').upsert({
        connection_id, comment_id, replied_public: true,
      }, { onConflict: 'connection_id,comment_id' });
      return json({ ok: true, comment_reply_id: (res as any)?.id ?? null });
    } catch (e) {
      const ge = e as GraphError | IgGraphError;
      return json({ error: (ge as any).graph?.message ?? String(e) }, (ge as any).status ?? 500);
    }
  }

  // --- LIKE COMMENT ---
  if (sendType === 'like_comment') {
    if (!connection_id || !comment_id) return json({ error: 'connection_id e comment_id são obrigatórios' }, 400);
    const { data: conn } = await sb.from('instagram_connections').select('*').eq('id', connection_id).maybeSingle();
    if (!conn) return json({ error: 'connection not found' }, 404);
    try {
      const { fetcher, ownerId, mode } = await buildFetcher(conn);
      if (mode !== 'ig_user_token') {
        return json({
          error: 'LIKE_COMMENT_UNSUPPORTED_AUTH_MODE',
          message: 'Curtir comentário exige a API nova do Instagram Login. Reconecte usando Instagram Business Login com a permissão instagram_manage_engagement.',
        }, 422);
      }
      // Doc oficial atual: Like Media and Comments API
      // POST /<IG_USER_ID>/likes com comment_id=<IG_COMMENT_ID>
      await fetcher(`/${ownerId}/likes?comment_id=${encodeURIComponent(String(comment_id))}`, { method: 'POST' });
      await sb.from('instagram_comment_replies').upsert({
        connection_id, comment_id, liked: true,
      }, { onConflict: 'connection_id,comment_id' });
      return json({ ok: true });
    } catch (e) {
      const ge = e as GraphError | IgGraphError;
      const graph = (ge as any).graph;
      const message = graph?.message ?? String(e);
      return json({
        error: message,
        code: graph?.code,
        subcode: graph?.error_subcode,
        hint: message.includes('permission') || message.includes('Permissions')
          ? 'Confirme se o token possui a permissão instagram_manage_engagement e se ela foi aprovada no App Review.'
          : undefined,
      }, (ge as any).status ?? 500);
    }
  }

  let connId = connection_id;
  let toId = recipient_id;

  if (conversation_id && (!connId || !toId)) {
    const { data: conv } = await sb
      .from('webchat_conversations')
      .select('instagram_connection_id, ig_sender_id, organization_id')
      .eq('id', conversation_id)
      .maybeSingle();
    if (!conv) return json({ error: 'conversation not found' }, 404);
    connId = connId ?? conv.instagram_connection_id;
    toId = toId ?? conv.ig_sender_id;
  }

  if (!connId) return json({ error: 'missing connection_id' }, 400);
  if (sendType !== 'private_reply' && !toId) return json({ error: 'missing recipient_id' }, 400);
  if (sendType === 'private_reply' && !comment_id) return json({ error: 'private_reply requer comment_id' }, 400);

  const { data: conn, error: connErr } = await sb
    .from('instagram_connections')
    .select('*')
    .eq('id', connId)
    .maybeSingle();
  if (connErr || !conn) return json({ error: 'connection not found' }, 404);
  if (organization_id && conn.organization_id !== organization_id) return json({ error: 'org mismatch' }, 403);
  {
    const { assertOrgActive } = await import('../_shared/org-status.ts');
    const guard = await assertOrgActive(sb, conn.organization_id);
    if (!guard.ok) return json(guard.body, guard.status);
  }
  if (conn.status !== 'active') return json({ error: `connection inactive` }, 422);

  if (sendType === 'dm' && conversation_id && !tag) {
    const { data: ok } = await sb.rpc('is_within_24h_window', { _conversation_id: conversation_id });
    if (ok === false) {
      return json({
        error: 'OUT_OF_WINDOW',
        message: 'Fora da janela 24h do Instagram. Para responder, use uma message tag (ex: HUMAN_AGENT) ou aguarde o usuário enviar nova mensagem.',
      }, 422);
    }
  }

  let fetcherBundle: { fetcher: IgFetcher; ownerId: string; mode: string };
  try {
    fetcherBundle = await buildFetcher(conn);
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
  const { fetcher, ownerId } = fetcherBundle;

  const payload: any = sendType === 'private_reply'
    ? { recipient: { comment_id: String(comment_id) } }
    : { recipient: { id: String(toId) }, messaging_type: tag ? 'MESSAGE_TAG' : 'RESPONSE', ...(tag ? { tag } : {}) };

  const message: any = {};
  if (media?.url) {
    message.attachment = { type: media.type ?? 'image', payload: { url: media.url, is_reusable: false } };
  } else {
    message.text = String(text ?? '');
  }
  if (Array.isArray(quick_replies) && quick_replies.length > 0) {
    message.quick_replies = quick_replies.slice(0, 13).map((q: any) => ({
      content_type: 'text',
      title: String(q.title ?? q.label ?? '').slice(0, 20),
      payload: String(q.payload ?? q.title ?? ''),
    }));
  }
  if (Array.isArray(buttons) && buttons.length > 0) {
    message.attachment = {
      type: 'template',
      payload: {
        template_type: 'button',
        text: String(text ?? '').slice(0, 640) || '.',
        buttons: buttons.slice(0, 3).map((b: any) => ({
          type: 'postback',
          title: String(b.title ?? b.label ?? '').slice(0, 20),
          payload: String(b.payload ?? b.title ?? ''),
        })),
      },
    };
    delete message.text;
  }
  payload.message = message;

  let res: any;
  try {
    res = await fetcher(`/${ownerId}/messages`, {
      method: 'POST',
      body: JSON.stringify(payload),
    });
  } catch (e) {
    const ge = e as GraphError | IgGraphError;
    const msg = (ge as any).graph?.message ?? String(e);
    if (conversation_id) {
      await sb.from('webchat_messages').insert({
        conversation_id,
        direction: 'outbound',
        sender_type: 'agent',
        content: text ?? '[mídia]',
        content_type: 'text',
        metadata: { delivery_status: 'failed', error: msg, payload },
      });
    }
    return json({ error: msg }, (ge as any).status ?? 500);
  }

  const mid = res?.message_id ?? null;

  // Se private_reply e temos sender_ig_id, resolvemos/creamos a conversa para
  // registrar a mensagem enviada no inbox Conversas.
  let effectiveConvId: string | null = conversation_id ?? null;
  if (sendType === 'private_reply') {
    await sb.from('instagram_comment_replies').upsert({
      connection_id: connId, comment_id, replied_private: true,
    }, { onConflict: 'connection_id,comment_id' });

    if (!effectiveConvId && sender_ig_id) {
      try {
        effectiveConvId = await upsertConversationForSender(sb, conn, String(sender_ig_id), sender_name ?? null);
      } catch (e) {
        console.error('[instagram-send] upsert conv for private_reply failed', e);
      }
    }
  }

  if (effectiveConvId) {
    await sb.from('webchat_messages').insert({
      conversation_id: effectiveConvId,
      direction: 'outbound',
      sender_type: 'agent',
      content: text ?? (media?.url ?? '[mídia]'),
      content_type: media?.url ? (media.type === 'image' ? 'image' : media.type === 'audio' ? 'audio' : 'file') : 'text',
      message_type: media?.type ?? 'text',
      ig_message_id: mid,
      metadata: {
        delivery_status: 'sent',
        send_type: sendType,
        ...(sendType === 'private_reply' ? { trigger_comment_id: comment_id } : {}),
        ...(media ? { media } : {}),
      },
    });
    await sb.from('webchat_conversations').update({ last_message_at: new Date().toISOString() }).eq('id', effectiveConvId);
  }

  return json({ ok: true, ig_message_id: mid, conversation_id: effectiveConvId });
});

async function upsertConversationForSender(sb: any, conn: any, senderIgId: string, senderName: string | null): Promise<string> {
  const { data: existing } = await sb
    .from('webchat_conversations')
    .select('id')
    .eq('organization_id', conn.organization_id)
    .eq('channel', 'instagram')
    .eq('instagram_connection_id', conn.id)
    .eq('ig_sender_id', senderIgId)
    .neq('status', 'closed')
    .order('last_message_at', { ascending: false, nullsFirst: false })
    .limit(1)
    .maybeSingle();
  if (existing?.id) return existing.id;

  const { data: widget } = await sb
    .from('webchat_widgets')
    .select('id')
    .eq('organization_id', conn.organization_id)
    .eq('is_active', true)
    .limit(1)
    .maybeSingle();

  const { data: created, error } = await sb.from('webchat_conversations').insert({
    organization_id: conn.organization_id,
    widget_id: widget?.id ?? null,
    channel: 'instagram',
    status: 'bot_active',
    visitor_id: crypto.randomUUID(),
    visitor_name: senderName || `Instagram ${senderIgId.slice(-4)}`,
    instagram_connection_id: conn.id,
    ig_sender_id: senderIgId,
    last_message_at: new Date().toISOString(),
  }).select('id').single();
  if (error) throw error;
  return created.id;
}


function json(b: unknown, status = 200) {
  return new Response(JSON.stringify(b), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
}
