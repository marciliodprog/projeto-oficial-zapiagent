ALTER TABLE public.platform_settings
  ADD COLUMN IF NOT EXISTS meta_oauth_scopes_override text;