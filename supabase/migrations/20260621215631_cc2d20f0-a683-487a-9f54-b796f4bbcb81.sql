CREATE TABLE public.mia_user_memory (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL,
  display_name text,
  role_label text,
  timezone text DEFAULT 'America/Sao_Paulo',
  locale text DEFAULT 'pt-BR',
  preferences jsonb NOT NULL DEFAULT '{}'::jsonb,
  facts jsonb NOT NULL DEFAULT '[]'::jsonb,
  last_active_entities jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, organization_id)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.mia_user_memory TO authenticated;
GRANT ALL ON public.mia_user_memory TO service_role;

ALTER TABLE public.mia_user_memory ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own mia memory"
  ON public.mia_user_memory
  FOR ALL
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE TRIGGER update_mia_user_memory_updated_at
  BEFORE UPDATE ON public.mia_user_memory
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE INDEX idx_mia_user_memory_user_org ON public.mia_user_memory(user_id, organization_id);