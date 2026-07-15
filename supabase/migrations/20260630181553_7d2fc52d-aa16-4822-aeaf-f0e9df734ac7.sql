CREATE POLICY "Users can view linked org profiles"
ON public.profiles
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_organizations uo_target
    JOIN public.user_organizations uo_viewer
      ON uo_viewer.organization_id = uo_target.organization_id
    WHERE uo_target.user_id = profiles.id
      AND uo_viewer.user_id = auth.uid()
  )
);