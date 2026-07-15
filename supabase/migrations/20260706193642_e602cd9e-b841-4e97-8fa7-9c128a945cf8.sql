
ALTER TABLE public.voice_agents
  ADD COLUMN IF NOT EXISTS photo_url text,
  ADD COLUMN IF NOT EXISTS display_name text,
  ADD COLUMN IF NOT EXISTS role_title text,
  ADD COLUMN IF NOT EXISTS theme text NOT NULL DEFAULT 'phone';

-- unique slug case-insensitive quando publicado
CREATE UNIQUE INDEX IF NOT EXISTS voice_agents_public_slug_uniq
  ON public.voice_agents (lower(public_slug))
  WHERE public_slug IS NOT NULL;
