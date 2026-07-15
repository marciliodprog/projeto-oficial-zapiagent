CREATE POLICY "Admins can update profiles in their org"
ON public.profiles
FOR UPDATE
TO authenticated
USING (
  organization_id = get_user_organization(auth.uid())
  AND has_role(auth.uid(), 'admin'::app_role)
)
WITH CHECK (
  organization_id = get_user_organization(auth.uid())
  AND has_role(auth.uid(), 'admin'::app_role)
);