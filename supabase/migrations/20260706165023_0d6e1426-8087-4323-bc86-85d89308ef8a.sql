ALTER TABLE public.voice_agents
  ADD COLUMN IF NOT EXISTS public_slug text UNIQUE,
  ADD COLUMN IF NOT EXISTS public_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS public_config jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS idx_voice_agents_public_slug
  ON public.voice_agents(public_slug)
  WHERE public_enabled = true;

GRANT SELECT ON public.voice_agents TO anon;

DROP POLICY IF EXISTS "voice_agents_public_read" ON public.voice_agents;
CREATE POLICY "voice_agents_public_read" ON public.voice_agents
  FOR SELECT TO anon
  USING (public_enabled = true AND public_slug IS NOT NULL);