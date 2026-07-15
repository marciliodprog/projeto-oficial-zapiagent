ALTER TABLE public.voice_call_sessions
  ADD COLUMN IF NOT EXISTS ai_analysis jsonb,
  ADD COLUMN IF NOT EXISTS ai_analysis_at timestamptz;