// marketing-sync — sincroniza catálogo Meta Ads (campanhas/adsets/ads/creativos/insights)
// e resolve atribuições pendentes de CTWA.
//
// POST { organization_id?: string, provider?: 'meta' }
// - Sem organization_id: roda para todas empresas com credenciais ativas.
// - Provider default: 'meta' (Facebook + Instagram Ads).
//
// verify_jwt = false (chamável via cron interno)

import { createClient } from 'npm:@supabase/supabase-js@2';
import { decryptSecret } from '../_shared/meta-crypto.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function supa() {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );
}

const GRAPH = 'https://graph.facebook.com/v20.0';

async function graphGet(path: string, token: string, params: Record<string, string> = {}) {
  const url = new URL(`${GRAPH}${path}`);
  url.searchParams.set('access_token', token);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const res = await fetch(url.toString());
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = body?.error?.message || res.statusText;
    throw new Error(`Meta Graph ${path}: ${err}`);
  }
  return body;
}

async function syncMetaForOrg(sb: any, cred: any): Promise<{ ok: boolean; error?: string; counts?: any }> {
  const token = await decryptSecret(cred.access_token_encrypted).catch(() => null);
  if (!token) return { ok: false, error: 'missing_or_invalid_token' };
  const adAcct = cred.ad_account_id;
  if (!adAcct) return { ok: false, error: 'missing_ad_account_id' };
  const acctPath = adAcct.startsWith('act_') ? `/${adAcct}` : `/act_${adAcct}`;
  const counts = { campaigns: 0, adsets: 0, ads: 0, creatives: 0, insights: 0 };

  // Campanhas
  const campRes = await graphGet(`${acctPath}/campaigns`, token, {
    fields: 'id,name,objective,status,daily_budget,lifetime_budget,start_time,stop_time',
    limit: '200',
  });
  for (const c of campRes.data ?? []) {
    await sb.from('marketing_campaigns').upsert({
      organization_id: cred.organization_id,
      provider: 'meta',
      external_id: c.id,
      ad_account_id: adAcct,
      name: c.name, objective: c.objective, status: c.status,
      daily_budget: c.daily_budget ? Number(c.daily_budget) / 100 : null,
      lifetime_budget: c.lifetime_budget ? Number(c.lifetime_budget) / 100 : null,
      start_time: c.start_time ?? null, stop_time: c.stop_time ?? null,
      metadata: c, synced_at: new Date().toISOString(),
    }, { onConflict: 'organization_id,provider,external_id' });
    counts.campaigns++;
  }

  // Adsets
  const asetRes = await graphGet(`${acctPath}/adsets`, token, {
    fields: 'id,name,status,campaign_id,targeting,daily_budget,lifetime_budget',
    limit: '200',
  });
  for (const a of asetRes.data ?? []) {
    const { data: camp } = await sb.from('marketing_campaigns')
      .select('id').eq('organization_id', cred.organization_id).eq('provider', 'meta')
      .eq('external_id', a.campaign_id).maybeSingle();
    await sb.from('marketing_adsets').upsert({
      organization_id: cred.organization_id,
      provider: 'meta', external_id: a.id,
      campaign_id: camp?.id ?? null, campaign_external_id: a.campaign_id ?? null,
      name: a.name, status: a.status, targeting: a.targeting ?? {},
      daily_budget: a.daily_budget ? Number(a.daily_budget) / 100 : null,
      lifetime_budget: a.lifetime_budget ? Number(a.lifetime_budget) / 100 : null,
      metadata: a, synced_at: new Date().toISOString(),
    }, { onConflict: 'organization_id,provider,external_id' });
    counts.adsets++;
  }

  // Ads + creatives
  const adRes = await graphGet(`${acctPath}/ads`, token, {
    fields: 'id,name,status,campaign_id,adset_id,creative{id,name,title,body,call_to_action_type,thumbnail_url,image_url},preview_shareable_link',
    limit: '200',
  });
  for (const ad of adRes.data ?? []) {
    let creativeUuid: string | null = null;
    if (ad.creative?.id) {
      const cr = ad.creative;
      const { data: creRow } = await sb.from('marketing_creatives').upsert({
        organization_id: cred.organization_id,
        provider: 'meta', external_id: cr.id,
        name: cr.name, headline: cr.title, body: cr.body,
        cta_type: cr.call_to_action_type,
        thumbnail_url: cr.thumbnail_url, media_url: cr.image_url,
        metadata: cr, synced_at: new Date().toISOString(),
      }, { onConflict: 'organization_id,provider,external_id' }).select('id').maybeSingle();
      creativeUuid = creRow?.id ?? null;
      counts.creatives++;
    }
    const { data: camp } = await sb.from('marketing_campaigns')
      .select('id').eq('organization_id', cred.organization_id).eq('provider', 'meta')
      .eq('external_id', ad.campaign_id).maybeSingle();
    const { data: aset } = await sb.from('marketing_adsets')
      .select('id').eq('organization_id', cred.organization_id).eq('provider', 'meta')
      .eq('external_id', ad.adset_id).maybeSingle();

    await sb.from('marketing_ads').upsert({
      organization_id: cred.organization_id,
      provider: 'meta', external_id: ad.id,
      campaign_id: camp?.id ?? null, campaign_external_id: ad.campaign_id ?? null,
      adset_id: aset?.id ?? null, adset_external_id: ad.adset_id ?? null,
      creative_id: creativeUuid, creative_external_id: ad.creative?.id ?? null,
      name: ad.name, status: ad.status, preview_url: ad.preview_shareable_link ?? null,
      metadata: ad, synced_at: new Date().toISOString(),
    }, { onConflict: 'organization_id,provider,external_id' });
    counts.ads++;
  }

  // Insights (últimos 7 dias, nível ad)
  try {
    const insRes = await graphGet(`${acctPath}/insights`, token, {
      level: 'ad',
      fields: 'ad_id,adset_id,campaign_id,spend,impressions,clicks,ctr,cpc,cpm,reach,frequency,actions',
      date_preset: 'last_7d',
      time_increment: '1',
      limit: '500',
    });
    for (const row of insRes.data ?? []) {
      const actions = Array.isArray(row.actions) ? row.actions : [];
      const purchases = Number(actions.find((a: any) => a.action_type === 'purchase')?.value ?? 0);
      const revenue = Number(actions.find((a: any) => a.action_type === 'purchase_value')?.value ?? 0);
      const ctwa = Number(actions.find((a: any) => a.action_type === 'onsite_conversion.messaging_conversation_started_7d')?.value ?? 0);
      await sb.from('marketing_insights_daily').upsert({
        organization_id: cred.organization_id,
        provider: 'meta', entity_type: 'ad', entity_external_id: row.ad_id,
        date: row.date_start,
        spend: Number(row.spend ?? 0),
        impressions: Number(row.impressions ?? 0),
        clicks: Number(row.clicks ?? 0),
        ctr: row.ctr ? Number(row.ctr) : null,
        cpc: row.cpc ? Number(row.cpc) : null,
        cpm: row.cpm ? Number(row.cpm) : null,
        reach: row.reach ? Number(row.reach) : null,
        frequency: row.frequency ? Number(row.frequency) : null,
        ctwa_clicks: ctwa, purchases, revenue,
        raw: row, synced_at: new Date().toISOString(),
      }, { onConflict: 'organization_id,provider,entity_type,entity_external_id,date' });
      counts.insights++;
    }
  } catch (e) {
    console.warn('[marketing-sync] insights error:', (e as Error).message);
  }

  return { ok: true, counts };
}

async function resolvePendingAttributions(sb: any, organization_id?: string): Promise<number> {
  // Leads com ctwa_clid/fbclid ainda sem evento campaign_identified
  let q = sb.from('leads')
    .select('id')
    .not('ctwa_clid', 'is', null)
    .limit(500);
  if (organization_id) q = q.eq('organization_id', organization_id);
  const { data } = await q;
  let n = 0;
  for (const l of data ?? []) {
    try {
      await sb.rpc('resolve_click_attribution', { p_lead_id: l.id });
      n++;
    } catch (_) {}
  }
  return n;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const sb = supa();
  let body: any = {};
  try { body = await req.json(); } catch (_) {}
  const organization_id: string | undefined = body?.organization_id;
  const provider: string = body?.provider ?? 'meta';

  let credsQ = sb.from('org_marketing_credentials')
    .select('*').eq('is_active', true).eq('provider', provider);
  if (organization_id) credsQ = credsQ.eq('organization_id', organization_id);
  const { data: creds, error } = await credsQ;
  if (error) {
    return new Response(JSON.stringify({ ok: false, error: error.message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const results: any[] = [];
  for (const cred of creds ?? []) {
    let result: any;
    try {
      result = await syncMetaForOrg(sb, cred);
    } catch (e) {
      result = { ok: false, error: (e as Error).message };
    }
    const resolved = await resolvePendingAttributions(sb, cred.organization_id);
    await sb.from('org_marketing_credentials').update({
      last_sync_at: new Date().toISOString(),
      last_sync_status: result.ok ? 'ok' : 'error',
      last_sync_error: result.ok ? null : String(result.error ?? ''),
    }).eq('id', cred.id);
    results.push({ organization_id: cred.organization_id, ad_account_id: cred.ad_account_id, resolved, ...result });
  }

  return new Response(JSON.stringify({ ok: true, results }), {
    status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
});
