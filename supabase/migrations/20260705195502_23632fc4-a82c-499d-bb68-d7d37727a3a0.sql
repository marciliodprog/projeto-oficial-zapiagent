-- Storage RLS for voice-samples (path: {org_id}/{clone_id}/{filename})
CREATE POLICY "voice_samples_select_org" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'voice-samples'
    AND (storage.foldername(name))[1] IN (
      SELECT organization_id::text FROM public.profiles WHERE id = auth.uid()
    )
  );

CREATE POLICY "voice_samples_insert_admin" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'voice-samples'
    AND (storage.foldername(name))[1] IN (
      SELECT organization_id::text FROM public.profiles WHERE id = auth.uid()
    )
    AND (public.has_role(auth.uid(), 'admin'::app_role) OR public.has_role(auth.uid(), 'super_admin'::app_role))
  );

CREATE POLICY "voice_samples_delete_admin" ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'voice-samples'
    AND (storage.foldername(name))[1] IN (
      SELECT organization_id::text FROM public.profiles WHERE id = auth.uid()
    )
    AND (public.has_role(auth.uid(), 'admin'::app_role) OR public.has_role(auth.uid(), 'super_admin'::app_role))
  );