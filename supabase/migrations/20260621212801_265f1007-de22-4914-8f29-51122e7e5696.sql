
CREATE TABLE IF NOT EXISTS public.mia_communications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  requested_by uuid NOT NULL,
  action_id uuid REFERENCES public.mia_actions(id) ON DELETE SET NULL,
  channel text NOT NULL,
  recipient_type text,
  recipient_id uuid,
  recipient_label text,
  draft jsonb NOT NULL DEFAULT '{}'::jsonb,
  final_message jsonb NOT NULL DEFAULT '{}'::jsonb,
  risk_level text NOT NULL DEFAULT 'medium',
  status text NOT NULL DEFAULT 'sent',
  provider_message_id text,
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz
);

GRANT SELECT, INSERT, UPDATE ON public.mia_communications TO authenticated;
GRANT ALL ON public.mia_communications TO service_role;

ALTER TABLE public.mia_communications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "org members read mia_communications"
  ON public.mia_communications FOR SELECT TO authenticated
  USING (organization_id IN (SELECT organization_id FROM public.profiles WHERE id = auth.uid()));

CREATE POLICY "service writes mia_communications"
  ON public.mia_communications FOR ALL TO service_role
  USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_mia_comm_org_created
  ON public.mia_communications(organization_id, created_at DESC);

-- Adiciona risk_level em mia_actions se não existir
ALTER TABLE public.mia_actions
  ADD COLUMN IF NOT EXISTS risk_level text NOT NULL DEFAULT 'medium';
