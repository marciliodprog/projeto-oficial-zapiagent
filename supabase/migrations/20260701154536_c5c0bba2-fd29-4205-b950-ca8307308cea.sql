
-- 1) chat-media: org-prefixed writes
DROP POLICY IF EXISTS "chat-media authenticated upload" ON storage.objects;
DROP POLICY IF EXISTS "chat-media authenticated update" ON storage.objects;
DROP POLICY IF EXISTS "chat-media authenticated delete" ON storage.objects;

CREATE POLICY "chat-media org upload" ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'chat-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);
CREATE POLICY "chat-media org update" ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'chat-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
)
WITH CHECK (
  bucket_id = 'chat-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);
CREATE POLICY "chat-media org delete" ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'chat-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);

-- 2) catalog-media
DROP POLICY IF EXISTS catalog_media_auth_insert ON storage.objects;
DROP POLICY IF EXISTS catalog_media_auth_update ON storage.objects;
DROP POLICY IF EXISTS catalog_media_auth_delete ON storage.objects;

CREATE POLICY catalog_media_org_insert ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'catalog-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);
CREATE POLICY catalog_media_org_update ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'catalog-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
)
WITH CHECK (
  bucket_id = 'catalog-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);
CREATE POLICY catalog_media_org_delete ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'catalog-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);

-- 3) whatsapp-media (all four ops isolated; bucket is private)
DROP POLICY IF EXISTS whatsapp_media_read_auth ON storage.objects;
DROP POLICY IF EXISTS whatsapp_media_write_auth ON storage.objects;
DROP POLICY IF EXISTS whatsapp_media_update_auth ON storage.objects;
DROP POLICY IF EXISTS whatsapp_media_delete_auth ON storage.objects;

CREATE POLICY whatsapp_media_org_read ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'whatsapp-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);
CREATE POLICY whatsapp_media_org_write ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'whatsapp-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);
CREATE POLICY whatsapp_media_org_update ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'whatsapp-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
)
WITH CHECK (
  bucket_id = 'whatsapp-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);
CREATE POLICY whatsapp_media_org_delete ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'whatsapp-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);

-- 4) cadence-media
DROP POLICY IF EXISTS "Authenticated users can upload cadence media" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can delete cadence media" ON storage.objects;

CREATE POLICY "cadence-media org upload" ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'cadence-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);
CREATE POLICY "cadence-media org delete" ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'cadence-media'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);

-- 5) materials
DROP POLICY IF EXISTS "Authenticated users can upload materials" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can delete materials" ON storage.objects;

CREATE POLICY "materials org upload" ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'materials'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);
CREATE POLICY "materials org delete" ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'materials'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);

-- 6) product-documents (all ops org-scoped)
DROP POLICY IF EXISTS "Users can upload product documents" ON storage.objects;
DROP POLICY IF EXISTS "Users can view their org product documents" ON storage.objects;
DROP POLICY IF EXISTS "Users can delete their org product documents" ON storage.objects;

CREATE POLICY "product-documents org read" ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'product-documents'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);
CREATE POLICY "product-documents org upload" ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'product-documents'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);
CREATE POLICY "product-documents org delete" ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'product-documents'
  AND (storage.foldername(name))[1] = public.get_user_organization(auth.uid())::text
);

-- 7) user_organizations: prevent privilege escalation to super_admin
DROP POLICY IF EXISTS "Admin updates memberships in own org" ON public.user_organizations;
CREATE POLICY "Admin updates memberships in own org"
ON public.user_organizations
FOR UPDATE
USING (
  has_role(auth.uid(), 'admin'::app_role)
  AND organization_id = get_user_organization(auth.uid())
  AND role <> 'super_admin'::app_role
)
WITH CHECK (
  organization_id = get_user_organization(auth.uid())
  AND role <> 'super_admin'::app_role
);

-- 8) platform_branding_public: switch to security_invoker + expose only branding columns to anon
ALTER VIEW public.platform_branding_public SET (security_invoker = true);

CREATE POLICY "Anyone can read branding row"
ON public.platform_settings
FOR SELECT
USING (true);

REVOKE SELECT ON public.platform_settings FROM anon, authenticated;
GRANT SELECT (
  id, logo_url, logo_dark_url, favicon_url, platform_name, support_email,
  primary_color, accent_color, gradient_style, gradient_custom, border_radius,
  default_theme, font_family, font_url, base_font_size, footer_text,
  terms_url, privacy_url, login_headline, login_subheadline, login_stats_enabled,
  login_bg_image_url, login_bg_layout, login_logo_position, hide_widget_branding,
  widget_accent_color, powered_by_text, browser_title, meta_description,
  og_image_url, twitter_handle, default_language, created_at, updated_at, public_app_url
) ON public.platform_settings TO anon, authenticated;
GRANT SELECT ON public.platform_branding_public TO anon, authenticated;

-- 9) docs_touch_updated_at: fix mutable search_path
CREATE OR REPLACE FUNCTION public.docs_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $function$ BEGIN NEW.updated_at = now(); RETURN NEW; END $function$;
