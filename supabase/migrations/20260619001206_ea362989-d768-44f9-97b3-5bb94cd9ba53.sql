
-- Policies para o bucket privado onboarding-uploads
-- Primeira pasta do path = organization_id

DROP POLICY IF EXISTS "onboarding_uploads_read_own_org" ON storage.objects;
DROP POLICY IF EXISTS "onboarding_uploads_insert_own_org" ON storage.objects;
DROP POLICY IF EXISTS "onboarding_uploads_update_own_org" ON storage.objects;
DROP POLICY IF EXISTS "onboarding_uploads_delete_own_org" ON storage.objects;

CREATE POLICY "onboarding_uploads_read_own_org"
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'onboarding-uploads'
    AND (storage.foldername(name))[1] = (
      SELECT organization_id::text FROM public.profiles WHERE id = auth.uid()
    )
  );

CREATE POLICY "onboarding_uploads_insert_own_org"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'onboarding-uploads'
    AND (storage.foldername(name))[1] = (
      SELECT organization_id::text FROM public.profiles WHERE id = auth.uid()
    )
  );

CREATE POLICY "onboarding_uploads_update_own_org"
  ON storage.objects FOR UPDATE TO authenticated
  USING (
    bucket_id = 'onboarding-uploads'
    AND (storage.foldername(name))[1] = (
      SELECT organization_id::text FROM public.profiles WHERE id = auth.uid()
    )
  );

CREATE POLICY "onboarding_uploads_delete_own_org"
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'onboarding-uploads'
    AND (storage.foldername(name))[1] = (
      SELECT organization_id::text FROM public.profiles WHERE id = auth.uid()
    )
  );
