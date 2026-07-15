
-- Fix 1: FKs user_id → profiles.id para permitir embed `profiles!fk(...)` no PostgREST
ALTER TABLE public.conversation_notes
  ADD CONSTRAINT conversation_notes_user_id_profiles_fkey
  FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.sector_members
  ADD CONSTRAINT sector_members_user_id_profiles_fkey
  FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_user_id_profiles_fkey
  FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.user_product_assignments
  ADD CONSTRAINT user_product_assignments_user_id_profiles_fkey
  FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE public.calendar_events
  ADD CONSTRAINT calendar_events_user_id_profiles_fkey
  FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

-- Fix 3: colunas ausentes em leads (usadas pelo webchat-bot)
ALTER TABLE public.leads
  ADD COLUMN IF NOT EXISTS tags text[] NOT NULL DEFAULT '{}'::text[];

ALTER TABLE public.leads
  ADD COLUMN IF NOT EXISTS custom_fields jsonb NOT NULL DEFAULT '{}'::jsonb;
