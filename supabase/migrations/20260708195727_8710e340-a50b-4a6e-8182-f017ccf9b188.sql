
-- 1. platform_settings: OAuth Meta global
ALTER TABLE public.platform_settings
  ADD COLUMN IF NOT EXISTS meta_oauth_app_id text,
  ADD COLUMN IF NOT EXISTS meta_oauth_app_secret_encrypted text,
  ADD COLUMN IF NOT EXISTS meta_oauth_graph_version text DEFAULT 'v21.0',
  ADD COLUMN IF NOT EXISTS meta_oauth_enabled boolean NOT NULL DEFAULT false;

-- 2. instagram_connections: modo OAuth
ALTER TABLE public.instagram_connections
  ADD COLUMN IF NOT EXISTS auth_mode text NOT NULL DEFAULT 'byo',
  ADD COLUMN IF NOT EXISTS user_access_token_encrypted text,
  ADD COLUMN IF NOT EXISTS token_expires_at timestamptz;

ALTER TABLE public.instagram_connections
  DROP CONSTRAINT IF EXISTS instagram_connections_auth_mode_check;
ALTER TABLE public.instagram_connections
  ADD CONSTRAINT instagram_connections_auth_mode_check
  CHECK (auth_mode IN ('byo','platform_oauth'));

-- 3. org_marketing_credentials: modo OAuth
ALTER TABLE public.org_marketing_credentials
  ADD COLUMN IF NOT EXISTS auth_mode text NOT NULL DEFAULT 'byo';

ALTER TABLE public.org_marketing_credentials
  DROP CONSTRAINT IF EXISTS org_marketing_credentials_auth_mode_check;
ALTER TABLE public.org_marketing_credentials
  ADD CONSTRAINT org_marketing_credentials_auth_mode_check
  CHECK (auth_mode IN ('byo','platform_oauth'));

-- 4. Sessions table para o handshake OAuth
CREATE TABLE IF NOT EXISTS public.meta_oauth_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  state text NOT NULL UNIQUE,
  organization_id uuid NOT NULL,
  user_id uuid NOT NULL,
  purpose text NOT NULL DEFAULT 'both',
  status text NOT NULL DEFAULT 'pending',
  user_access_token_encrypted text,
  token_expires_at timestamptz,
  discovered jsonb,
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  consumed_at timestamptz,
  CONSTRAINT meta_oauth_sessions_purpose_check CHECK (purpose IN ('instagram','ads','both')),
  CONSTRAINT meta_oauth_sessions_status_check CHECK (status IN ('pending','ready','consumed','error'))
);

GRANT SELECT ON public.meta_oauth_sessions TO authenticated;
GRANT ALL ON public.meta_oauth_sessions TO service_role;

ALTER TABLE public.meta_oauth_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own meta_oauth_sessions"
  ON public.meta_oauth_sessions FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

CREATE INDEX IF NOT EXISTS idx_meta_oauth_sessions_state ON public.meta_oauth_sessions(state);
CREATE INDEX IF NOT EXISTS idx_meta_oauth_sessions_user ON public.meta_oauth_sessions(user_id, created_at DESC);
