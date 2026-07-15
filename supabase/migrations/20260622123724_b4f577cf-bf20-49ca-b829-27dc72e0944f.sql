DROP POLICY IF EXISTS "Users can create transfers for conversations they have access t" ON public.conversation_transfers;
DROP POLICY IF EXISTS "Users can view transfers for conversations they have access to" ON public.conversation_transfers;

CREATE POLICY "transfers_insert_same_org"
ON public.conversation_transfers
FOR INSERT TO authenticated
WITH CHECK (
  created_by = auth.uid()
  AND conversation_id IN (
    SELECT id FROM public.webchat_conversations
    WHERE organization_id = public.get_user_organization(auth.uid())
  )
);

CREATE POLICY "transfers_select_same_org"
ON public.conversation_transfers
FOR SELECT TO authenticated
USING (
  conversation_id IN (
    SELECT id FROM public.webchat_conversations
    WHERE organization_id = public.get_user_organization(auth.uid())
  )
);