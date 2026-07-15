-- A view platform_branding_public expõe apenas colunas de marca (logos, cores,
-- headlines, SEO). Ela precisa ser legível por usuários anônimos para que a
-- tela /login, formulários públicos e páginas de agendamento reflitam a
-- Identidade Visual configurada no Super Admin.
--
-- Uma migration anterior (linter fix) marcou esta view com security_invoker=true,
-- o que a fez respeitar a RLS de platform_settings (restrita a super admin) e
-- retornar 0 linhas para anon — travando o login no visual hardcoded.
ALTER VIEW public.platform_branding_public SET (security_invoker = false);
ALTER VIEW public.platform_branding_public OWNER TO postgres;
GRANT SELECT ON public.platform_branding_public TO anon, authenticated;

COMMENT ON VIEW public.platform_branding_public IS
  'Branding público da plataforma — DEVE rodar como owner (security_invoker=false) para servir anon na tela de login. Só projeta colunas visuais; nenhum segredo.';