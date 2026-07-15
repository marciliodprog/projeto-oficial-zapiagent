
CREATE TABLE IF NOT EXISTS public.mia_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  user_id uuid NOT NULL,
  pergunta text,
  resposta text,
  tool_utilizada text,
  latency_ms int,
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT ON public.mia_logs TO authenticated;
GRANT ALL ON public.mia_logs TO service_role;

ALTER TABLE public.mia_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "org members read own org logs"
  ON public.mia_logs FOR SELECT
  TO authenticated
  USING (organization_id = (SELECT p.organization_id FROM public.profiles p WHERE p.id = auth.uid()));

CREATE POLICY "authenticated insert own logs"
  ON public.mia_logs FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND organization_id = (SELECT p.organization_id FROM public.profiles p WHERE p.id = auth.uid())
  );

CREATE INDEX IF NOT EXISTS mia_logs_org_created_idx ON public.mia_logs (organization_id, created_at DESC);
