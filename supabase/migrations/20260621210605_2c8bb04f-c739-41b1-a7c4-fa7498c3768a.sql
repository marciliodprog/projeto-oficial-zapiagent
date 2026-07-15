
CREATE TABLE IF NOT EXISTS public.mia_daily_summaries (
  organization_id uuid NOT NULL,
  summary_date date NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, summary_date)
);

GRANT SELECT ON public.mia_daily_summaries TO authenticated;
GRANT ALL ON public.mia_daily_summaries TO service_role;

ALTER TABLE public.mia_daily_summaries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins/managers leem briefing da própria org"
ON public.mia_daily_summaries FOR SELECT
TO authenticated
USING (
  organization_id IN (SELECT organization_id FROM public.profiles WHERE id = auth.uid())
  AND (
    public.has_role(auth.uid(), 'super_admin')
    OR public.has_role(auth.uid(), 'admin')
    OR public.has_role(auth.uid(), 'manager')
  )
);

ALTER TABLE public.conversation_notes
  ADD COLUMN IF NOT EXISTS ai_summary jsonb,
  ADD COLUMN IF NOT EXISTS ai_summary_updated_at timestamptz;
