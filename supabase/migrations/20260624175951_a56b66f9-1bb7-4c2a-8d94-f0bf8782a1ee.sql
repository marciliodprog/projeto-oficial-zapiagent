ALTER TABLE public.organizations ADD COLUMN IF NOT EXISTS signature_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE public.user_permissions ADD COLUMN IF NOT EXISTS signature_enabled boolean NOT NULL DEFAULT true;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS signature_display_name text;