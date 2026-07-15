// instagram-connect
// Promove uma conexão Instagram em rascunho para ATIVA.
// Suporta 2 modos de auth (ig_auth_style):
//   - 'page_token' (legado): Facebook Login for Business — usa Page Access Token contra graph.facebook.com
//   - 'ig_user_token' (novo padrão "Instagram API with Instagram Login"): usa IG User Access Token
//     (System User funciona) contra graph.instagram.com, keyed por IG User ID (sem exigir Página FB).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { graphFetch, GraphError } from '../_shared/meta-graph.ts';
import { igGraphFetch, IgGraphError, igSubscribeWebhookFields } from '../_shared/ig-graph.ts';
import { encryptSecret } from '../_shared/meta-crypto.ts';
import { subscribeIgWebhookFields } from '../_shared/ig-subscribe.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Unauthorized' }, 401);

  const sbUser = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const sbAdmin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const { data: userData, error: userErr } = await sbUser.auth.getUser();
  if (userErr || !userData?.user) return json({ error: 'Unauthorized' }, 401);
  const userId = userData.user.id;

  const body = await req.json().catch(() => ({}));
  const {
    connection_id,
    organization_id,
    display_name,
    app_id,
    app_secret,
    // legado
    fb_page_id,
    page_access_token,
    // novo
    ig_user_access_token,
    // comum
    ig_business_account_id,
    ig_auth_style: rawAuthStyle,
  } = body ?? {};

  const ig_auth_style: 'page_token' | 'ig_user_token' =
    rawAuthStyle === 'ig_user_token' ? 'ig_user_token' : 'page_token';

  if (!connection_id || !organization_id || !app_id || !ig_business_account_id) {
    return json({ error: 'campos obrigatórios ausentes' }, 400);
  }
  if (ig_auth_style === 'page_token' && (!fb_page_id || !page_access_token)) {
    return json({ error: 'fb_page_id e page_access_token são obrigatórios no modo Página do Facebook' }, 400);
  }
  if (ig_auth_style === 'ig_user_token' && !ig_user_access_token) {
    return json({ error: 'ig_user_access_token é obrigatório no modo Instagram Business Login' }, 400);
  }

  const { data: belongs, error: belongsErr } = await sbAdmin.rpc('user_belongs_to_organization', {
    _user_id: userId,
    _org_id: organization_id,
  });
  if (belongsErr) return json({ error: belongsErr.message }, 500);
  if (!belongs) return json({ error: 'forbidden' }, 403);

  const { data: existing } = await sbAdmin
    .from('instagram_connections')
    .select('id, status, app_secret_encrypted')
    .eq('id', connection_id)
    .eq('organization_id', organization_id)
    .maybeSingle();
  if (!existing) return json({ error: 'connection not found' }, 404);

  const updates: Record<string, any> = {
    display_name: display_name ?? undefined,
    app_id: String(app_id),
    ig_business_account_id: String(ig_business_account_id),
    ig_auth_style,
  };

  let subscribed_granted: string[] = [];
  let subscribed_failed: any[] = [];
  let subscribed_missing_scopes: string[] = [];
  let subscribe_error_summary: string | null = null;
  let ig_username: string | null = null;
  let fb_page_name: string | null = null;

  if (ig_auth_style === 'page_token') {
    // ------------------ Modo legado ------------------
    let pageInfo: any, igInfo: any;
    try {
      pageInfo = await graphFetch(`/${fb_page_id}?fields=name,id,instagram_business_account`, page_access_token);
    } catch (e) {
      const ge = e as GraphError;
      console.error('[ig-connect] page fetch failed', { fb_page_id, code: ge.graph?.code, message: ge.graph?.message });
      return json({ error: 'Facebook Page ID ou Page Access Token inválido', detail: ge.graph?.message ?? String(e) }, 400);
    }
    if (pageInfo?.instagram_business_account?.id && String(pageInfo.instagram_business_account.id) !== String(ig_business_account_id)) {
      return json({ error: `A conta IG da página é ${pageInfo.instagram_business_account.id}, não ${ig_business_account_id}` }, 400);
    }
    if (!pageInfo?.instagram_business_account?.id) {
      return json({ error: 'Esta Página do Facebook não tem uma conta Instagram Business vinculada.' }, 400);
    }
    try {
      igInfo = await graphFetch(`/${ig_business_account_id}?fields=username,name`, page_access_token);
    } catch (e) {
      const ge = e as GraphError;
      return json({ error: 'Instagram Business Account ID inválido', detail: ge.graph?.message ?? String(e) }, 400);
    }

    const subscribeResult = await subscribeIgWebhookFields({
      fb_page_id: String(fb_page_id),
      page_access_token: String(page_access_token),
      app_id: String(app_id),
      app_secret: app_secret ? String(app_secret) : undefined,
    });
    subscribed_granted = subscribeResult.granted;
    subscribed_failed = subscribeResult.failed;
    subscribed_missing_scopes = subscribeResult.missing_scopes;
    subscribe_error_summary = subscribeResult.error_summary;

    ig_username = igInfo?.username ?? null;
    fb_page_name = pageInfo?.name ?? null;

    updates.fb_page_id = String(fb_page_id);
    updates.fb_page_name = fb_page_name;
    updates.ig_username = ig_username;
    updates.page_access_token_encrypted = await encryptSecret(String(page_access_token));
  } else {
    // ------------------ Modo novo (Instagram Business Login) ------------------
    // Valida token: GET /me?fields=user_id,username no graph.instagram.com deve retornar o mesmo IG User ID.
    let me: any;
    try {
      me = await igGraphFetch<any>(`/me?fields=user_id,username,name`, String(ig_user_access_token));
    } catch (e) {
      const ge = e as IgGraphError;
      console.error('[ig-connect] ig /me failed', { code: ge.graph?.code, message: ge.graph?.message });
      return json({ error: 'IG User Access Token inválido', detail: ge.graph?.message ?? String(e) }, 400);
    }
    // graph.instagram.com pode retornar `id` (IG user id) e `user_id` (App-scoped ID). Aceitamos qualquer um.
    const meId = String(me?.user_id ?? me?.id ?? '');
    if (meId && String(ig_business_account_id) !== meId) {
      console.warn('[ig-connect] token /me id !== ig_business_account_id', { meId, provided: ig_business_account_id });
      // Não bloqueia: a Meta às vezes devolve id diferente do IGBA quando o token é do IG User da conta profissional.
    }
    ig_username = me?.username ?? null;

    const sub = await igSubscribeWebhookFields({
      ig_user_id: String(ig_business_account_id),
      ig_user_token: String(ig_user_access_token),
    });
    subscribed_granted = sub.granted;
    subscribed_failed = sub.failed;
    subscribe_error_summary = sub.error_summary;

    updates.ig_username = ig_username;
    updates.ig_user_access_token_encrypted = await encryptSecret(String(ig_user_access_token));
    // limpa Page-token no novo modo
    updates.page_access_token_encrypted = null;
  }

  updates.status = subscribed_failed.length === 0 ? 'active' : 'error';
  updates.last_error = subscribe_error_summary;
  updates.subscribed_fields = subscribed_granted;
  updates.webhook_subscribed_at = new Date().toISOString();

  if (app_secret) updates.app_secret_encrypted = await encryptSecret(String(app_secret));
  else if (!existing.app_secret_encrypted) {
    return json({ error: 'app_secret é obrigatório na primeira ativação (usado para validar HMAC do webhook)' }, 400);
  }

  const { error: updErr } = await sbAdmin
    .from('instagram_connections')
    .update(updates)
    .eq('id', connection_id);
  if (updErr) return json({ error: updErr.message }, 500);

  return json({
    ok: true,
    connection_id,
    ig_auth_style,
    ig_username,
    fb_page_name,
    subscribed: subscribed_failed.length === 0,
    granted: subscribed_granted,
    failed: subscribed_failed,
    missing_scopes: subscribed_missing_scopes,
  });
});
