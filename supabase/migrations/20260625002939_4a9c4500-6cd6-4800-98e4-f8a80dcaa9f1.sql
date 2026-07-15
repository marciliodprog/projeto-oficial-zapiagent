CREATE TABLE public.campaign_preparation_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','running','completed','failed')),
  total_contacts int NOT NULL DEFAULT 0,
  processed_contacts int NOT NULL DEFAULT 0,
  batch_size int NOT NULL DEFAULT 500,
  cursor int NOT NULL DEFAULT 0,
  lead_ids uuid[] NOT NULL DEFAULT '{}',
  campaign_snapshot jsonb,
  error text,
  attempts int NOT NULL DEFAULT 0,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_cpj_pending ON public.campaign_preparation_jobs (created_at)
  WHERE status IN ('pending','running');
CREATE INDEX idx_cpj_org ON public.campaign_preparation_jobs (organization_id, status);
CREATE INDEX idx_cpj_campaign ON public.campaign_preparation_jobs (campaign_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.campaign_preparation_jobs TO authenticated;
GRANT ALL ON public.campaign_preparation_jobs TO service_role;

ALTER TABLE public.campaign_preparation_jobs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members can view their preparation jobs"
  ON public.campaign_preparation_jobs FOR SELECT
  TO authenticated
  USING (
    public.has_role(auth.uid(), 'super_admin')
    OR organization_id IN (
      SELECT organization_id FROM public.profiles WHERE id = auth.uid()
    )
  );

CREATE POLICY "Org members can manage their preparation jobs"
  ON public.campaign_preparation_jobs FOR ALL
  TO authenticated
  USING (
    public.has_role(auth.uid(), 'super_admin')
    OR organization_id IN (
      SELECT organization_id FROM public.profiles WHERE id = auth.uid()
    )
  )
  WITH CHECK (
    public.has_role(auth.uid(), 'super_admin')
    OR organization_id IN (
      SELECT organization_id FROM public.profiles WHERE id = auth.uid()
    )
  );

CREATE TRIGGER update_campaign_preparation_jobs_updated_at
  BEFORE UPDATE ON public.campaign_preparation_jobs
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
