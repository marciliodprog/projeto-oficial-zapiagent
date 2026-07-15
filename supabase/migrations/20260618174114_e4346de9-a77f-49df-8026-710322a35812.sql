
-- Tabela de anexos de chamados de suporte
CREATE TABLE public.support_attachments (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  ticket_id UUID NOT NULL REFERENCES public.support_tickets(id) ON DELETE CASCADE,
  message_id UUID REFERENCES public.support_messages(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  uploaded_by UUID NOT NULL,
  storage_path TEXT NOT NULL,
  file_name TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  size_bytes INT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT support_attachments_mime_chk CHECK (mime_type IN ('image/jpeg','image/png','image/webp','application/pdf')),
  CONSTRAINT support_attachments_size_chk CHECK (size_bytes > 0 AND size_bytes <= 2097152)
);

CREATE INDEX idx_support_attachments_ticket ON public.support_attachments(ticket_id);
CREATE INDEX idx_support_attachments_message ON public.support_attachments(message_id);

GRANT SELECT, INSERT, DELETE ON public.support_attachments TO authenticated;
GRANT ALL ON public.support_attachments TO service_role;

ALTER TABLE public.support_attachments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "support_attachments_select" ON public.support_attachments
  FOR SELECT TO authenticated
  USING (
    public.is_super_admin(auth.uid())
    OR public.user_belongs_to_organization(auth.uid(), organization_id)
  );

CREATE POLICY "support_attachments_insert" ON public.support_attachments
  FOR INSERT TO authenticated
  WITH CHECK (
    uploaded_by = auth.uid()
    AND (
      public.is_super_admin(auth.uid())
      OR public.user_belongs_to_organization(auth.uid(), organization_id)
    )
  );

CREATE POLICY "support_attachments_delete" ON public.support_attachments
  FOR DELETE TO authenticated
  USING (
    uploaded_by = auth.uid() OR public.is_super_admin(auth.uid())
  );

-- Storage policies para bucket 'support-attachments'
-- Caminho: {organization_id}/{ticket_id}/{message_id_or_pending}/{uuid}.{ext}
CREATE POLICY "support_attachments_storage_select" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'support-attachments'
    AND (
      public.is_super_admin(auth.uid())
      OR public.user_belongs_to_organization(auth.uid(), (split_part(name, '/', 1))::uuid)
    )
  );

CREATE POLICY "support_attachments_storage_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'support-attachments'
    AND (
      public.is_super_admin(auth.uid())
      OR public.user_belongs_to_organization(auth.uid(), (split_part(name, '/', 1))::uuid)
    )
  );

CREATE POLICY "support_attachments_storage_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'support-attachments'
    AND (
      public.is_super_admin(auth.uid())
      OR owner = auth.uid()
    )
  );
