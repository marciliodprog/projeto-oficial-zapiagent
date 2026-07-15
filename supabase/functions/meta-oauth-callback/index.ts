// meta-oauth-callback
// Facebook chama esta URL com ?code&state. Trocamos code -> token, exchange para long-lived,
// descobrimos páginas/ad accounts e marcamos a sessão como 'ready'. Renderiza HTML que
// dispara postMessage para a janela pai (front do Lovable) com o session_id.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { encryptSecret } from '../_shared/meta-crypto.ts';
import {
  loadPlatformMetaApp,
  exchangeCodeForToken,
  exchangeForLongLivedToken,
  discoverAssets,
} from '../_shared/meta-oauth.ts';

function html(body: string, status = 200) {
  return new Response(body, {
    status,
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
}

function renderPostMessage(payload: Record<string, unknown>) {
  const json = JSON.stringify({ source: 'meta-oauth', ...payload });
  return `<!doctype html><meta charset="utf-8"><body style="font-family:system-ui;padding:24px;color:#111">
  <h3>Conectado. Você pode fechar esta janela.</h3>
  <p>Voltando para a plataforma…</p>
  <script>
    try { window.opener && window.opener.postMessage(${json}, '*'); } catch(e){}
    setTimeout(function(){ try { window.close(); } catch(e){} }, 1200);
  </script>
  </body>`;
}

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    const code = url.searchParams.get('code');
    const state = url.searchParams.get('state');
    const err = url.searchParams.get('error') || url.searchParams.get('error_description');
    if (err) return html(renderPostMessage({ status: 'error', error: err }));
    if (!code || !state) return html(renderPostMessage({ status: 'error', error: 'missing code/state' }), 400);

    const sbAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { data: session, error: selErr } = await sbAdmin
      .from('meta_oauth_sessions')
      .select('*')
      .eq('state', state)
      .maybeSingle();
    if (selErr || !session) return html(renderPostMessage({ status: 'error', error: 'sessão inválida' }), 400);
    if (session.status !== 'pending') return html(renderPostMessage({ status: 'error', error: 'sessão já usada' }), 400);

    const app = await loadPlatformMetaApp();
    const redirect_uri = `${Deno.env.get('SUPABASE_URL')}/functions/v1/meta-oauth-callback`;

    try {
      const short = await exchangeCodeForToken(app, code, redirect_uri);
      const long = await exchangeForLongLivedToken(app, short.access_token).catch(() => short);
      const expiresAt = long.expires_in
        ? new Date(Date.now() + long.expires_in * 1000).toISOString()
        : null;
      const assets = await discoverAssets(app, long.access_token);

      await sbAdmin.from('meta_oauth_sessions').update({
        status: 'ready',
        user_access_token_encrypted: await encryptSecret(long.access_token),
        token_expires_at: expiresAt,
        discovered: assets,
      }).eq('id', session.id);

      return html(renderPostMessage({ status: 'ready', session_id: session.id }));
    } catch (e) {
      await sbAdmin.from('meta_oauth_sessions').update({
        status: 'error',
        error: (e as Error).message,
      }).eq('id', session.id);
      return html(renderPostMessage({ status: 'error', error: (e as Error).message }));
    }
  } catch (e) {
    console.error('[meta-oauth-callback]', e);
    return html(renderPostMessage({ status: 'error', error: (e as Error).message }), 500);
  }
});
