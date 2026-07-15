// meta-oauth-start
// Gera state, cria sessão pendente e redireciona o usuário para o Facebook Login.
// verify_jwt=false porque o usuário chega direto pelo browser; validamos via token de acesso no query string.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeaders } from 'npm:@supabase/supabase-js@2/cors';
import { loadPlatformMetaApp, buildAuthorizeUrl, resolveScopes } from '../_shared/meta-oauth.ts';

function html(body: string, status = 200) {
  return new Response(`<!doctype html><meta charset="utf-8"><body style="font-family:system-ui;padding:24px;color:#111">${body}</body>`, {
    status,
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    const url = new URL(req.url);
    const organization_id = url.searchParams.get('org_id');
    const purpose = (url.searchParams.get('purpose') || 'both') as 'instagram' | 'ads' | 'both';
    const sbToken = url.searchParams.get('sb_token');
    if (!organization_id || !sbToken) return html('Parâmetros inválidos.', 400);

    const sbUser = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: `Bearer ${sbToken}` } } },
    );
    const { data: userData, error: userErr } = await sbUser.auth.getUser();
    if (userErr || !userData?.user) return html('Sessão inválida. Faça login e tente novamente.', 401);

    const sbAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { data: belongs } = await sbAdmin.rpc('user_belongs_to_organization', {
      _user_id: userData.user.id,
      _org_id: organization_id,
    });
    if (!belongs) return html('Sem permissão para esta organização.', 403);

    const app = await loadPlatformMetaApp().catch((e) => {
      throw new Error(`Meta OAuth não configurado: ${e.message}`);
    });
    if (!app.enabled) return html('Meta OAuth está desativado no Super Admin.', 400);

    const state = crypto.randomUUID().replace(/-/g, '') + crypto.randomUUID().replace(/-/g, '');
    const { error: insErr } = await sbAdmin.from('meta_oauth_sessions').insert({
      state,
      organization_id,
      user_id: userData.user.id,
      purpose,
      status: 'pending',
    });
    if (insErr) return html(`Erro ao iniciar sessão: ${insErr.message}`, 500);

    const redirect_uri = `${Deno.env.get('SUPABASE_URL')}/functions/v1/meta-oauth-callback`;
    const scope = resolveScopes(purpose, app.scopes_override);
    const authUrl = buildAuthorizeUrl(app, { redirect_uri, state, scope });
    return Response.redirect(authUrl, 302);
  } catch (e) {
    console.error('[meta-oauth-start]', e);
    return html(`Erro: ${(e as Error).message}`, 500);
  }
});
