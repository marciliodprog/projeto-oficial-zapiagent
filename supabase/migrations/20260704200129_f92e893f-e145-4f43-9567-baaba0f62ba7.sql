
-- Instagram Automations (ManyChat-style) — MVP
-- 1) instagram_flows: fluxos visuais com gatilho + blocos
CREATE TABLE public.instagram_flows (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  connection_id UUID REFERENCES public.instagram_connections(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','paused','archived')),
  trigger_type TEXT NOT NULL CHECK (trigger_type IN ('comment_keyword','dm_keyword','story_reply','mention','manual','new_follower')),
  trigger_config JSONB NOT NULL DEFAULT '{}'::jsonb,
  -- trigger_config exemplos:
  --   comment_keyword: { post_ids?: string[] (empty = any post), keywords: string[], match: 'any'|'all'|'exact'|'regex', case_sensitive?: bool, also_private_reply?: bool, also_like_comment?: bool }
  --   dm_keyword:      { keywords: string[], match: 'any'|'all'|'exact'|'regex' }
  --   story_reply:     { keywords?: string[], match?: 'any'|'exact' }
  --   mention:         { in: 'comment'|'caption'|'both' }
  flow_blocks JSONB NOT NULL DEFAULT '[]'::jsonb,
  start_block_id TEXT,
  stats JSONB NOT NULL DEFAULT '{}'::jsonb,
  throttle_per_sender_hours INTEGER NOT NULL DEFAULT 24,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_ig_flows_org ON public.instagram_flows(organization_id);
CREATE INDEX idx_ig_flows_conn ON public.instagram_flows(connection_id) WHERE connection_id IS NOT NULL;
CREATE INDEX idx_ig_flows_active ON public.instagram_flows(organization_id, trigger_type) WHERE status = 'active';

GRANT SELECT, INSERT, UPDATE, DELETE ON public.instagram_flows TO authenticated;
GRANT ALL ON public.instagram_flows TO service_role;
ALTER TABLE public.instagram_flows ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Members can view org IG flows"
  ON public.instagram_flows FOR SELECT TO authenticated
  USING (public.user_belongs_to_organization(auth.uid(), organization_id) OR public.has_role(auth.uid(),'super_admin'));

CREATE POLICY "Admins can manage IG flows"
  ON public.instagram_flows FOR ALL TO authenticated
  USING (
    public.has_role(auth.uid(),'super_admin')
    OR (public.user_belongs_to_organization(auth.uid(), organization_id)
        AND (public.has_role(auth.uid(),'admin') OR public.user_has_permission(auth.uid(),'manage_integrations')))
  )
  WITH CHECK (
    public.has_role(auth.uid(),'super_admin')
    OR (public.user_belongs_to_organization(auth.uid(), organization_id)
        AND (public.has_role(auth.uid(),'admin') OR public.user_has_permission(auth.uid(),'manage_integrations')))
  );

CREATE TRIGGER trg_ig_flows_updated_at
  BEFORE UPDATE ON public.instagram_flows
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 2) instagram_flow_runs: auditoria de execuções
CREATE TABLE public.instagram_flow_runs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  flow_id UUID NOT NULL REFERENCES public.instagram_flows(id) ON DELETE CASCADE,
  connection_id UUID REFERENCES public.instagram_connections(id) ON DELETE SET NULL,
  trigger_source TEXT NOT NULL CHECK (trigger_source IN ('comment','dm','story_reply','mention','manual','new_follower','postback')),
  source_id TEXT,                -- comment_id / message id / etc
  sender_ig_id TEXT,
  conversation_id UUID REFERENCES public.webchat_conversations(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'running' CHECK (status IN ('running','completed','failed','skipped')),
  error TEXT,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ
);

CREATE INDEX idx_ig_flow_runs_flow ON public.instagram_flow_runs(flow_id, started_at DESC);
CREATE INDEX idx_ig_flow_runs_org ON public.instagram_flow_runs(organization_id, started_at DESC);
CREATE INDEX idx_ig_flow_runs_conv ON public.instagram_flow_runs(conversation_id) WHERE conversation_id IS NOT NULL;

GRANT SELECT ON public.instagram_flow_runs TO authenticated;
GRANT ALL ON public.instagram_flow_runs TO service_role;
ALTER TABLE public.instagram_flow_runs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Members can view org IG flow runs"
  ON public.instagram_flow_runs FOR SELECT TO authenticated
  USING (public.user_belongs_to_organization(auth.uid(), organization_id) OR public.has_role(auth.uid(),'super_admin'));

-- 3) instagram_comment_replies: dedup por comentário
CREATE TABLE public.instagram_comment_replies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  connection_id UUID NOT NULL REFERENCES public.instagram_connections(id) ON DELETE CASCADE,
  comment_id TEXT NOT NULL,
  flow_id UUID REFERENCES public.instagram_flows(id) ON DELETE SET NULL,
  replied_public BOOLEAN NOT NULL DEFAULT false,
  replied_private BOOLEAN NOT NULL DEFAULT false,
  liked BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (connection_id, comment_id)
);

CREATE INDEX idx_ig_comment_replies_conn ON public.instagram_comment_replies(connection_id, created_at DESC);

GRANT SELECT ON public.instagram_comment_replies TO authenticated;
GRANT ALL ON public.instagram_comment_replies TO service_role;
ALTER TABLE public.instagram_comment_replies ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Members can view org comment reply dedup"
  ON public.instagram_comment_replies FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.instagram_connections c
      WHERE c.id = instagram_comment_replies.connection_id
        AND (public.user_belongs_to_organization(auth.uid(), c.organization_id) OR public.has_role(auth.uid(),'super_admin'))
    )
  );

-- 4) Coluna extra em instagram_connections para exibir fields inscritos
ALTER TABLE public.instagram_connections
  ADD COLUMN IF NOT EXISTS subscribed_fields TEXT[] NOT NULL DEFAULT ARRAY['messages','messaging_postbacks','message_reactions']::text[];
