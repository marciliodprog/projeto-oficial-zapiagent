
CREATE TABLE public.mia_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  user_id uuid NOT NULL,
  action_type text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  preview text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'waiting_confirmation',
  result jsonb,
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  executed_at timestamptz,
  cancelled_at timestamptz,
  CONSTRAINT mia_actions_status_check CHECK (status IN ('draft','waiting_confirmation','approved','executed','cancelled','failed')),
  CONSTRAINT mia_actions_type_check CHECK (action_type IN (
    'create_task','schedule_followup','notify_seller',
    'open_conversation','open_lead','open_calendar','open_tasks','open_report'
  ))
);

CREATE INDEX idx_mia_actions_org_status ON public.mia_actions (organization_id, status, created_at DESC);
CREATE INDEX idx_mia_actions_user ON public.mia_actions (user_id, created_at DESC);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.mia_actions TO authenticated;
GRANT ALL ON public.mia_actions TO service_role;

ALTER TABLE public.mia_actions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users see own mia actions"
ON public.mia_actions FOR SELECT TO authenticated
USING (
  user_id = auth.uid()
  OR public.has_role(auth.uid(), 'admin')
  OR public.has_role(auth.uid(), 'super_admin')
);

CREATE POLICY "Users insert own mia actions"
ON public.mia_actions FOR INSERT TO authenticated
WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users update own mia actions"
ON public.mia_actions FOR UPDATE TO authenticated
USING (
  user_id = auth.uid()
  OR public.has_role(auth.uid(), 'admin')
  OR public.has_role(auth.uid(), 'super_admin')
);

CREATE POLICY "Users delete own mia actions"
ON public.mia_actions FOR DELETE TO authenticated
USING (
  user_id = auth.uid()
  OR public.has_role(auth.uid(), 'admin')
  OR public.has_role(auth.uid(), 'super_admin')
);

CREATE TRIGGER trg_mia_actions_updated_at
BEFORE UPDATE ON public.mia_actions
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

ALTER PUBLICATION supabase_realtime ADD TABLE public.mia_actions;
