
-- Etapa 1 Ligações IA: tools estruturadas + desfechos + medição mínima
ALTER TABLE public.voice_agents
  ADD COLUMN IF NOT EXISTS outcomes jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS tools_config jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE public.call_logs
  ADD COLUMN IF NOT EXISTS outcome text,
  ADD COLUMN IF NOT EXISTS outcome_data jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS public.call_tool_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  call_id uuid NOT NULL REFERENCES public.call_logs(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  tool_name text NOT NULL,
  direction text NOT NULL CHECK (direction IN ('call','result','click')),
  args jsonb NOT NULL DEFAULT '{}'::jsonb,
  result jsonb,
  ts_relative_ms integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_call_tool_events_call ON public.call_tool_events(call_id, created_at);
CREATE INDEX IF NOT EXISTS idx_call_tool_events_org ON public.call_tool_events(organization_id, created_at DESC);

GRANT SELECT, INSERT ON public.call_tool_events TO authenticated;
GRANT ALL ON public.call_tool_events TO service_role;

ALTER TABLE public.call_tool_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "call_tool_events_org_read" ON public.call_tool_events;
CREATE POLICY "call_tool_events_org_read" ON public.call_tool_events
  FOR SELECT TO authenticated
  USING (organization_id = get_user_organization(auth.uid()) OR is_super_admin(auth.uid()));

DROP POLICY IF EXISTS "call_tool_events_org_write" ON public.call_tool_events;
CREATE POLICY "call_tool_events_org_write" ON public.call_tool_events
  FOR INSERT TO authenticated
  WITH CHECK (organization_id = get_user_organization(auth.uid()) OR is_super_admin(auth.uid()));
