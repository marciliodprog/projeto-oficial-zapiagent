ALTER TABLE public.voice_agents DROP COLUMN IF EXISTS appearance;

ALTER TABLE public.voice_calls
  ADD COLUMN IF NOT EXISTS post_cadence_id uuid REFERENCES public.cadences(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_voice_calls_post_cadence ON public.voice_calls(post_cadence_id) WHERE post_cadence_id IS NOT NULL;