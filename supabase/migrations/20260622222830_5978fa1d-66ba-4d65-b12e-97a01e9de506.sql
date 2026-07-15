
ALTER TABLE public.whatsapp_meta_templates
  ADD COLUMN IF NOT EXISTS header_media_url TEXT,
  ADD COLUMN IF NOT EXISTS header_media_id TEXT,
  ADD COLUMN IF NOT EXISTS header_media_uploaded_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS header_media_mime TEXT,
  ADD COLUMN IF NOT EXISTS header_media_storage_path TEXT,
  ADD COLUMN IF NOT EXISTS header_media_filename TEXT;

-- Policies de Storage para bucket whatsapp-media
DROP POLICY IF EXISTS "whatsapp_media_read_auth" ON storage.objects;
DROP POLICY IF EXISTS "whatsapp_media_write_auth" ON storage.objects;
DROP POLICY IF EXISTS "whatsapp_media_update_auth" ON storage.objects;
DROP POLICY IF EXISTS "whatsapp_media_delete_auth" ON storage.objects;

CREATE POLICY "whatsapp_media_read_auth"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (bucket_id = 'whatsapp-media');

CREATE POLICY "whatsapp_media_write_auth"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (bucket_id = 'whatsapp-media');

CREATE POLICY "whatsapp_media_update_auth"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (bucket_id = 'whatsapp-media');

CREATE POLICY "whatsapp_media_delete_auth"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (bucket_id = 'whatsapp-media');
