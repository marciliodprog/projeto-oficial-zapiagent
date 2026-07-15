// instagram-flow-generate-ai
// Gera um instagram_flow completo a partir de descrição em linguagem natural.
// Usa ai-router (respeita plano/pool/chave própria).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { aiChat, describeAIError } from '../_shared/ai-call.ts';
import { recordAIUsage } from '../_shared/ai-router.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const j = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

const BLOCK_CATALOG = `
Blocos disponíveis (types válidos):
- ig_reply_comment       { text: string }                                 → responde publicamente no comentário
- ig_private_reply       { text: string }                                 → envia DM privada ao autor do comentário (janela 7d, 1× por comentário)
- ig_like_comment        {}                                                → curte o comentário
- ig_send_dm             { text: string }                                 → envia mensagem na DM
- ai_takeover            { prompt?: string }                              → passa a conversa para o agente IA
- wait                   { seconds: number }                              → aguarda N segundos (1-30)
- apply_tag              { tag_name: string }                             → aplica etiqueta ao lead pelo NOME (o backend resolve)
- condition_text         { keywords: string[], match: 'any'|'all'|'exact' } → ramificação por texto do gatilho
- enroll_cadence         { cadence_name: string }                          → inscreve o lead numa cadência (backend resolve nome→id)
- assign_lead            { sector_name?: string, user_name?: string }      → atribui o lead a um setor ou vendedor pelo nome
`;

const TRIGGER_TYPES = ['comment_keyword','dm_keyword','story_reply','mention','manual','new_follower'];

const SYSTEM_PROMPT = `Você é um construtor de automações do Instagram estilo ManyChat.
A partir da descrição do usuário, gere UM fluxo pronto para publicar.

REGRAS:
- Responda APENAS em JSON, sem markdown, sem texto extra.
- trigger_type deve ser um destes: ${TRIGGER_TYPES.join(', ')}.
- Para "story_reply" ou "dm_keyword" ou "comment_keyword" inclua trigger_config.keywords (array) e trigger_config.match ('any'|'all'|'exact'|'regex').
- Blocos rodam LINEARMENTE (o backend faz o rewire de next_block_id). Não invente ids.
- Regras Meta: ig_private_reply só funciona se o gatilho for comment_keyword/mention (janela 7d).
- Textos em português-BR, tom da empresa, sem clichês. Máx 2 linhas por bloco de mensagem.
- Se o usuário pedir para "IA responder"/"IA conversar", use ai_takeover (com prompt curto contextualizando).
- Se precisar aguardar antes da DM (evitar flood), use wait com 2-5 segundos.
- Se algo estiver ambíguo, adicione uma string em "warnings" (ex: "Selecione o post-alvo na aba Gatilho").

${BLOCK_CATALOG}

FORMATO EXATO:
{
  "name": "string curto",
  "description": "string curta",
  "trigger_type": "comment_keyword",
  "trigger_config": { "keywords": ["..."], "match": "any" },
  "blocks": [ { "type": "ig_reply_comment", "data": { "text": "..." } }, ... ],
  "warnings": ["..."]
}`;

function newBlockId() {
  return `blk_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`;
}

function rewireChain(blocks: any[]): any[] {
  return blocks.map((b, i) => ({ ...b, next_block_id: blocks[i + 1]?.id ?? null }));
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return j({ error: 'method not allowed' }, 405);

  const auth = req.headers.get('Authorization');
  if (!auth) return j({ error: 'unauthorized' }, 401);

  const sbUser = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: auth } },
  });
  const sbAdmin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  const { data: userData } = await sbUser.auth.getUser();
  if (!userData?.user) return j({ error: 'unauthorized' }, 401);

  const { prompt, organization_id, connection_id, existing_flow_id } = await req.json().catch(() => ({}));
  if (!prompt || typeof prompt !== 'string') return j({ error: 'prompt required' }, 400);

  // Resolve org id (do profile se não veio)
  let orgId: string | null = organization_id ?? null;
  if (!orgId) {
    const { data: prof } = await sbAdmin.from('profiles').select('organization_id').eq('id', userData.user.id).maybeSingle();
    orgId = prof?.organization_id ?? null;
  }
  if (!orgId) return j({ error: 'org não encontrada' }, 400);

  // Se refinando fluxo existente, passa contexto atual
  let refineContext = '';
  if (existing_flow_id) {
    const { data: cur } = await sbAdmin.from('instagram_flows').select('name, trigger_type, trigger_config, flow_blocks').eq('id', existing_flow_id).maybeSingle();
    if (cur) refineContext = `\n\nFluxo atual (para refinar):\n${JSON.stringify(cur).slice(0, 2000)}`;
  }

  // Contexto (tags, cadências ativas, setores) para o modelo
  const [{ data: tags }, { data: cads }, { data: secs }] = await Promise.all([
    sbAdmin.from('lead_tags').select('name').eq('organization_id', orgId).limit(30),
    sbAdmin.from('cadences').select('name').eq('organization_id', orgId).eq('status', 'active').limit(30),
    sbAdmin.from('sectors').select('name').eq('organization_id', orgId).limit(30),
  ]);
  const tagList = (tags ?? []).map(t => t.name).join(', ') || '(sem tags cadastradas)';
  const cadList = (cads ?? []).map(c => c.name).join(', ') || '(sem cadências ativas)';
  const secList = (secs ?? []).map(s => s.name).join(', ') || '(sem setores)';

  let response: Response, config: any;
  try {
    const r = await aiChat({
      organizationId: orgId,
      capability: 'content_generation',
      model: 'google/gemini-3-flash-preview',
      supabase: sbAdmin,
      label: 'ig-flow-generate-ai',
      body: {
        messages: [
          { role: 'system', content: SYSTEM_PROMPT + `\n\nTags disponíveis para apply_tag: ${tagList}\nCadências ativas para enroll_cadence: ${cadList}\nSetores para assign_lead: ${secList}` + refineContext },
          { role: 'user', content: prompt },
        ],
        response_format: { type: 'json_object' },
        temperature: 0.4,
      },
    });
    response = r.response; config = r.config;
  } catch (e: any) {
    return j({ error: e?.message ?? String(e), code: e?.code }, 400);
  }

  if (!response.ok) {
    const msg = await describeAIError(response, config.provider);
    return j({ error: msg }, response.status);
  }

  const data = await response.json();
  const raw = data?.choices?.[0]?.message?.content ?? '{}';
  let parsed: any;
  try { parsed = JSON.parse(raw); } catch {
    return j({ error: 'Resposta da IA não é JSON válido', raw: raw.slice(0, 500) }, 502);
  }

  // Validação leve + normalização
  const blocks = Array.isArray(parsed?.blocks) ? parsed.blocks : [];
  const rewired = rewireChain(
    blocks.map((b: any) => ({
      id: newBlockId(),
      type: String(b?.type ?? 'ig_send_dm'),
      position: { x: 0, y: 0 },
      data: b?.data ?? {},
      next_block_id: null,
    })),
  );

  // Resolve apply_tag por nome → tag_id
  if (rewired.some(b => b.type === 'apply_tag')) {
    const { data: allTags } = await sbAdmin.from('lead_tags').select('id,name').eq('organization_id', orgId);
    const byName = new Map((allTags ?? []).map((t: any) => [String(t.name).toLowerCase(), t.id]));
    for (const b of rewired) {
      if (b.type !== 'apply_tag') continue;
      const wanted = String(b.data?.tag_name ?? '').toLowerCase();
      const found = byName.get(wanted);
      if (found) b.data.tag_id = found;
      else b.data.tag_id_pending = b.data.tag_name;
    }
  }

  // Resolve enroll_cadence por nome → cadence_id
  if (rewired.some(b => b.type === 'enroll_cadence')) {
    const { data: cads } = await sbAdmin.from('cadences').select('id,name').eq('organization_id', orgId).eq('status', 'active');
    const byName = new Map((cads ?? []).map((c: any) => [String(c.name).toLowerCase(), c.id]));
    for (const b of rewired) {
      if (b.type !== 'enroll_cadence') continue;
      const wanted = String(b.data?.cadence_name ?? '').toLowerCase();
      const found = byName.get(wanted);
      if (found) b.data.cadence_id = found;
      else b.data.cadence_id_pending = b.data.cadence_name;
    }
  }

  // Resolve assign_lead sector_name/user_name → ids
  if (rewired.some(b => b.type === 'assign_lead')) {
    const [{ data: sectors }, { data: users }] = await Promise.all([
      sbAdmin.from('sectors').select('id,name').eq('organization_id', orgId),
      sbAdmin.from('profiles').select('id,full_name').eq('organization_id', orgId),
    ]);
    const bySector = new Map((sectors ?? []).map((s: any) => [String(s.name).toLowerCase(), s.id]));
    const byUser = new Map((users ?? []).map((u: any) => [String(u.full_name ?? '').toLowerCase(), u.id]));
    for (const b of rewired) {
      if (b.type !== 'assign_lead') continue;
      const sw = String(b.data?.sector_name ?? '').toLowerCase();
      const uw = String(b.data?.user_name ?? '').toLowerCase();
      if (sw) { const s = bySector.get(sw); if (s) b.data.sector_id = s; else b.data.sector_id_pending = b.data.sector_name; }
      if (uw) { const u = byUser.get(uw); if (u) b.data.user_id = u; else b.data.user_id_pending = b.data.user_name; }
    }
  }


  const flowPayload = {
    organization_id: orgId,
    created_by: userData.user.id,
    connection_id: connection_id ?? null,
    name: String(parsed?.name ?? 'Automação gerada por IA').slice(0, 120),
    description: String(parsed?.description ?? '').slice(0, 500) || null,
    status: 'draft' as const,
    trigger_type: TRIGGER_TYPES.includes(parsed?.trigger_type) ? parsed.trigger_type : 'comment_keyword',
    trigger_config: parsed?.trigger_config ?? {},
    flow_blocks: rewired,
    start_block_id: rewired[0]?.id ?? null,
  };

  let flowId: string;
  if (existing_flow_id) {
    const { error } = await sbAdmin.from('instagram_flows').update({
      name: flowPayload.name, description: flowPayload.description,
      trigger_type: flowPayload.trigger_type, trigger_config: flowPayload.trigger_config,
      flow_blocks: rewired, start_block_id: flowPayload.start_block_id,
    }).eq('id', existing_flow_id).eq('organization_id', orgId);
    if (error) return j({ error: error.message }, 500);
    flowId = existing_flow_id;
  } else {
    const { data: created, error } = await sbAdmin.from('instagram_flows').insert(flowPayload as any).select('id').single();
    if (error) return j({ error: error.message }, 500);
    flowId = created.id;
  }

  await recordAIUsage(sbAdmin, orgId, config, 'content_generation', data?.usage ?? null, 'instagram-flow-generate-ai').catch(() => {});

  return j({
    ok: true,
    flow_id: flowId,
    name: flowPayload.name,
    trigger_type: flowPayload.trigger_type,
    blocks: rewired,
    warnings: Array.isArray(parsed?.warnings) ? parsed.warnings : [],
  });
});
