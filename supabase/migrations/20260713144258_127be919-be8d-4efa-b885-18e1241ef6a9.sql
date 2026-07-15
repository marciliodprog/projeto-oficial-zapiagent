
ALTER TABLE public.instagram_connections
  ADD COLUMN IF NOT EXISTS ig_user_access_token_encrypted bytea,
  ADD COLUMN IF NOT EXISTS ig_auth_style text NOT NULL DEFAULT 'page_token';

ALTER TABLE public.instagram_connections
  DROP CONSTRAINT IF EXISTS instagram_connections_ig_auth_style_check;
ALTER TABLE public.instagram_connections
  ADD CONSTRAINT instagram_connections_ig_auth_style_check
  CHECK (ig_auth_style IN ('page_token','ig_user_token'));

ALTER TABLE public.instagram_connections
  ALTER COLUMN fb_page_id DROP NOT NULL;
