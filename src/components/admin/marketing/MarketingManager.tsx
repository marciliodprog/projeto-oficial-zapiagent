import { useEffect, useMemo, useState } from 'react';
import { supabase } from '@/integrations/supabase/client';
import { FunctionsHttpError } from '@supabase/supabase-js';
import { useAuth } from '@/hooks/useAuth';
import { toast } from 'sonner';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Loader2, RefreshCw, CheckCircle2, XCircle, AlertTriangle } from 'lucide-react';
import { MetaAdsWizard } from '@/components/admin/integrations/MetaAdsWizard';
import { MetaOAuthConnectButton } from '@/components/admin/integrations/MetaOAuthConnectButton';


async function extractFnError(error: any): Promise<string> {
  if (error instanceof FunctionsHttpError) {
    try {
      const body = await error.context.json();
      return body?.details || body?.error || error.message;
    } catch {
      try { return await error.context.text(); } catch { /* ignore */ }
    }
  }
  return error?.message ?? String(error);
}

type Credential = {
  id: string;
  organization_id: string;
  provider: string;
  ad_account_id: string | null;
  business_id: string | null;
  account_name: string | null;
  is_active: boolean;
  last_sync_at: string | null;
  last_sync_status: string | null;
  last_sync_error: string | null;
};

type Campaign = { id: string; external_id: string; name: string | null; status: string | null; objective: string | null; daily_budget: number | null };
type Ad = { id: string; external_id: string; name: string | null; status: string | null; adset_external_id: string | null; campaign_external_id: string | null };
type Insight = {
  entity_type: string; entity_external_id: string; date: string;
  spend: number; impressions: number; clicks: number; ctwa_clicks: number;
  purchases: number; revenue: number;
};

function currency(n: number | null | undefined) {
  if (n == null) return '—';
  return new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(n);
}
function int(n: number | null | undefined) {
  if (n == null) return '—';
  return new Intl.NumberFormat('pt-BR').format(n);
}
function rel(dt: string | null) {
  if (!dt) return 'nunca';
  const diff = Date.now() - new Date(dt).getTime();
  const m = Math.floor(diff / 60000);
  if (m < 1) return 'agora';
  if (m < 60) return `${m} min atrás`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h} h atrás`;
  return `${Math.floor(h / 24)} d atrás`;
}

export function MarketingManager() {
  const { profile } = useAuth();
  const orgId = profile?.organization_id ?? null;

  const [loading, setLoading] = useState(true);
  const [cred, setCred] = useState<Credential | null>(null);

  // Data
  const [campaigns, setCampaigns] = useState<Campaign[]>([]);
  const [ads, setAds] = useState<Ad[]>([]);
  const [insights, setInsights] = useState<Insight[]>([]);
  const [syncing, setSyncing] = useState(false);

  const loadCredential = async () => {
    if (!orgId) return;
    setLoading(true);
    const { data } = await supabase
      .from('org_marketing_credentials')
      .select('id, organization_id, provider, ad_account_id, business_id, account_name, is_active, last_sync_at, last_sync_status, last_sync_error')
      .eq('organization_id', orgId)
      .eq('provider', 'meta')
      .eq('is_active', true)
      .maybeSingle();
    setCred((data as Credential | null) ?? null);
    setLoading(false);
  };

  const loadData = async () => {
    if (!orgId) return;
    const [{ data: c }, { data: a }, { data: i }] = await Promise.all([
      supabase.from('marketing_campaigns')
        .select('id, external_id, name, status, objective, daily_budget')
        .eq('organization_id', orgId).eq('provider', 'meta')
        .order('name').limit(200),
      supabase.from('marketing_ads')
        .select('id, external_id, name, status, adset_external_id, campaign_external_id')
        .eq('organization_id', orgId).eq('provider', 'meta')
        .order('name').limit(200),
      supabase.from('marketing_insights_daily')
        .select('entity_type, entity_external_id, date, spend, impressions, clicks, ctwa_clicks, purchases, revenue')
        .eq('organization_id', orgId).eq('provider', 'meta')
        .gte('date', new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10))
        .order('date', { ascending: false }).limit(2000),
    ]);
    setCampaigns((c ?? []) as Campaign[]);
    setAds((a ?? []) as Ad[]);
    setInsights((i ?? []) as Insight[]);
  };

  useEffect(() => { loadCredential(); }, [orgId]);
  useEffect(() => { if (cred) loadData(); }, [cred?.id]);

  // Conexão é feita via <MetaAdsWizard /> quando não há credencial.

  const handleSync = async (silent = false) => {
    if (!orgId) return;
    setSyncing(true);
    try {
      const { data, error } = await supabase.functions.invoke('marketing-sync', {
        body: { organization_id: orgId, provider: 'meta' },
      });
      if (error) throw new Error(await extractFnError(error));
      if ((data as any)?.error) throw new Error((data as any).details || (data as any).error);
      if (!silent) toast.success('Sincronização concluída');
      await Promise.all([loadCredential(), loadData()]);
    } catch (e: any) {
      toast.error(`Falha no sync: ${e?.message ?? e}`);
    } finally {
      setSyncing(false);
    }
  };

  const handleDisconnect = async () => {
    if (!cred) return;
    if (!confirm('Desconectar esta conta do Meta Ads? O catálogo permanece salvo mas a sincronização para.')) return;
    const { error } = await supabase
      .from('org_marketing_credentials')
      .update({ is_active: false })
      .eq('id', cred.id);
    if (error) { toast.error(error.message); return; }
    toast.success('Conta desconectada');
    setCred(null);
    setCampaigns([]); setAds([]); setInsights([]);
  };

  // Agregações por campanha (30d)
  const campaignInsights = useMemo(() => {
    const byAd: Record<string, { spend: number; imp: number; clicks: number; ctwa: number; purchases: number; revenue: number }> = {};
    insights.filter((i) => i.entity_type === 'ad').forEach((i) => {
      const k = i.entity_external_id;
      byAd[k] = byAd[k] || { spend: 0, imp: 0, clicks: 0, ctwa: 0, purchases: 0, revenue: 0 };
      byAd[k].spend += Number(i.spend || 0);
      byAd[k].imp += Number(i.impressions || 0);
      byAd[k].clicks += Number(i.clicks || 0);
      byAd[k].ctwa += Number(i.ctwa_clicks || 0);
      byAd[k].purchases += Number(i.purchases || 0);
      byAd[k].revenue += Number(i.revenue || 0);
    });
    // Rollup ad → campanha via ads
    const adToCampaign: Record<string, string> = {};
    ads.forEach((a) => { if (a.campaign_external_id) adToCampaign[a.external_id] = a.campaign_external_id; });
    const byCampaign: Record<string, typeof byAd[string]> = {};
    Object.entries(byAd).forEach(([adId, m]) => {
      const camp = adToCampaign[adId];
      if (!camp) return;
      byCampaign[camp] = byCampaign[camp] || { spend: 0, imp: 0, clicks: 0, ctwa: 0, purchases: 0, revenue: 0 };
      byCampaign[camp].spend += m.spend;
      byCampaign[camp].imp += m.imp;
      byCampaign[camp].clicks += m.clicks;
      byCampaign[camp].ctwa += m.ctwa;
      byCampaign[camp].purchases += m.purchases;
      byCampaign[camp].revenue += m.revenue;
    });
    return byCampaign;
  }, [insights, ads]);

  const totals = useMemo(() => {
    return insights.filter((i) => i.entity_type === 'ad').reduce(
      (acc, i) => ({
        spend: acc.spend + Number(i.spend || 0),
        clicks: acc.clicks + Number(i.clicks || 0),
        ctwa: acc.ctwa + Number(i.ctwa_clicks || 0),
        purchases: acc.purchases + Number(i.purchases || 0),
        revenue: acc.revenue + Number(i.revenue || 0),
      }),
      { spend: 0, clicks: 0, ctwa: 0, purchases: 0, revenue: 0 },
    );
  }, [insights]);

  if (loading) {
    return (
      <div className="flex items-center justify-center py-24 text-muted-foreground">
        <Loader2 className="h-5 w-5 animate-spin mr-2" /> Carregando…
      </div>
    );
  }

  if (!cred) {
    return (
      <div className="p-6 max-w-3xl mx-auto space-y-6">
        <div>
          <h1 className="text-2xl font-semibold">Marketing · Meta Ads</h1>
          <p className="text-muted-foreground text-sm mt-1">
            Conecte sua conta do Facebook/Instagram Ads para trazer campanhas, criativos, gastos e atribuição CTWA (click-to-WhatsApp) para dentro da Jornada do Lead.
          </p>
        </div>

        <Card>
          <CardContent className="p-6 space-y-4">
            <div>
              <h3 className="font-semibold">Conectar em 1 clique</h3>
              <p className="text-sm text-muted-foreground">Autorize com sua conta do Facebook. Nós escolhemos as permissões corretas.</p>
            </div>
            {orgId && (
              <MetaOAuthConnectButton
                organizationId={orgId}
                purpose="ads"
                label="Conectar com Facebook"
                onConnected={loadCredential}
              />
            )}
          </CardContent>
        </Card>

        <details className="rounded-lg border p-4">
          <summary className="cursor-pointer text-sm font-medium text-muted-foreground">Usar meu próprio Meta App (avançado)</summary>
          <div className="mt-4">
            <MetaAdsWizard />
          </div>
        </details>
      </div>
    );
  }


  return (
    <div className="p-6 max-w-7xl mx-auto space-y-6">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Marketing · Meta Ads</h1>
          <p className="text-muted-foreground text-sm mt-1">
            {cred.account_name || cred.ad_account_id} ·
            <span className="ml-2 inline-flex items-center gap-1">
              {cred.last_sync_status === 'ok' ? (
                <CheckCircle2 className="h-3.5 w-3.5 text-emerald-500" />
              ) : cred.last_sync_status ? (
                <XCircle className="h-3.5 w-3.5 text-destructive" />
              ) : null}
              Última sync: {rel(cred.last_sync_at)}
            </span>
          </p>
          {cred.last_sync_error && (
            <p className="text-xs text-destructive mt-1 flex items-center gap-1">
              <AlertTriangle className="h-3.5 w-3.5" /> {cred.last_sync_error}
            </p>
          )}
        </div>
        <div className="flex gap-2">
          <Button variant="outline" size="sm" onClick={() => handleSync()} disabled={syncing}>
            {syncing ? <Loader2 className="h-4 w-4 mr-2 animate-spin" /> : <RefreshCw className="h-4 w-4 mr-2" />}
            Sincronizar
          </Button>
          <Button variant="ghost" size="sm" onClick={handleDisconnect}>Desconectar</Button>
        </div>
      </div>

      {/* KPIs 30d */}
      <div className="grid grid-cols-2 md:grid-cols-5 gap-3">
        <Card><CardContent className="pt-6"><div className="text-xs text-muted-foreground">Investimento 30d</div><div className="text-2xl font-semibold">{currency(totals.spend)}</div></CardContent></Card>
        <Card><CardContent className="pt-6"><div className="text-xs text-muted-foreground">Cliques</div><div className="text-2xl font-semibold">{int(totals.clicks)}</div></CardContent></Card>
        <Card><CardContent className="pt-6"><div className="text-xs text-muted-foreground">Cliques CTWA</div><div className="text-2xl font-semibold">{int(totals.ctwa)}</div></CardContent></Card>
        <Card><CardContent className="pt-6"><div className="text-xs text-muted-foreground">Compras</div><div className="text-2xl font-semibold">{int(totals.purchases)}</div></CardContent></Card>
        <Card>
          <CardContent className="pt-6">
            <div className="text-xs text-muted-foreground">ROAS</div>
            <div className="text-2xl font-semibold">
              {totals.spend > 0 ? (totals.revenue / totals.spend).toFixed(2) + '×' : '—'}
            </div>
          </CardContent>
        </Card>
      </div>

      <Tabs defaultValue="campaigns">
        <TabsList>
          <TabsTrigger value="campaigns">Campanhas ({campaigns.length})</TabsTrigger>
          <TabsTrigger value="ads">Anúncios ({ads.length})</TabsTrigger>
        </TabsList>

        <TabsContent value="campaigns" className="mt-4">
          <Card>
            <CardContent className="p-0">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Nome</TableHead>
                    <TableHead>Status</TableHead>
                    <TableHead>Objetivo</TableHead>
                    <TableHead className="text-right">Investimento 30d</TableHead>
                    <TableHead className="text-right">CTWA</TableHead>
                    <TableHead className="text-right">Compras</TableHead>
                    <TableHead className="text-right">Receita</TableHead>
                    <TableHead className="text-right">ROAS</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {campaigns.length === 0 && (
                    <TableRow><TableCell colSpan={8} className="text-center text-muted-foreground py-8">Nenhuma campanha sincronizada ainda.</TableCell></TableRow>
                  )}
                  {campaigns.map((c) => {
                    const m = campaignInsights[c.external_id];
                    return (
                      <TableRow key={c.id}>
                        <TableCell className="font-medium">{c.name || c.external_id}</TableCell>
                        <TableCell><Badge variant={c.status === 'ACTIVE' ? 'default' : 'outline'}>{c.status ?? '—'}</Badge></TableCell>
                        <TableCell className="text-xs text-muted-foreground">{c.objective ?? '—'}</TableCell>
                        <TableCell className="text-right">{currency(m?.spend ?? 0)}</TableCell>
                        <TableCell className="text-right">{int(m?.ctwa ?? 0)}</TableCell>
                        <TableCell className="text-right">{int(m?.purchases ?? 0)}</TableCell>
                        <TableCell className="text-right">{currency(m?.revenue ?? 0)}</TableCell>
                        <TableCell className="text-right">{m && m.spend > 0 ? (m.revenue / m.spend).toFixed(2) + '×' : '—'}</TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="ads" className="mt-4">
          <Card>
            <CardContent className="p-0">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Anúncio</TableHead>
                    <TableHead>Campanha</TableHead>
                    <TableHead>Status</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {ads.length === 0 && (
                    <TableRow><TableCell colSpan={3} className="text-center text-muted-foreground py-8">Nenhum anúncio sincronizado.</TableCell></TableRow>
                  )}
                  {ads.map((a) => {
                    const camp = campaigns.find((c) => c.external_id === a.campaign_external_id);
                    return (
                      <TableRow key={a.id}>
                        <TableCell className="font-medium">{a.name || a.external_id}</TableCell>
                        <TableCell className="text-muted-foreground text-sm">{camp?.name ?? a.campaign_external_id ?? '—'}</TableCell>
                        <TableCell><Badge variant={a.status === 'ACTIVE' ? 'default' : 'outline'}>{a.status ?? '—'}</Badge></TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>
    </div>
  );
}
