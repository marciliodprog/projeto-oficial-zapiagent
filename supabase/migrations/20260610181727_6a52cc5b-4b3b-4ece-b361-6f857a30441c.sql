-- Documentação editável (substitui Central de Ajuda e Atualizações)

CREATE TABLE IF NOT EXISTS public.docs_tracks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  label text NOT NULL,
  short_label text NOT NULL,
  description text,
  icon text DEFAULT 'BookOpen',
  accent text DEFAULT 'text-primary',
  display_order int NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.docs_sections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid NOT NULL REFERENCES public.docs_tracks(id) ON DELETE CASCADE,
  label text NOT NULL,
  display_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (track_id, label)
);

CREATE TABLE IF NOT EXISTS public.docs_pages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id uuid NOT NULL REFERENCES public.docs_tracks(id) ON DELETE CASCADE,
  section_id uuid REFERENCES public.docs_sections(id) ON DELETE SET NULL,
  slug text NOT NULL,
  title text NOT NULL,
  description text,
  content_json jsonb,
  content_html text,
  display_order int NOT NULL DEFAULT 0,
  updated_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (track_id, slug)
);

CREATE TABLE IF NOT EXISTS public.docs_change_proposals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  page_id uuid REFERENCES public.docs_pages(id) ON DELETE CASCADE,
  track_slug text NOT NULL,
  page_slug text NOT NULL,
  proposed_title text,
  proposed_description text,
  proposed_content_json jsonb,
  proposed_content_html text,
  source_signal jsonb,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  reviewed_by uuid,
  reviewed_at timestamptz
);

-- Grants
GRANT SELECT ON public.docs_tracks TO authenticated, anon;
GRANT INSERT, UPDATE, DELETE ON public.docs_tracks TO authenticated;
GRANT ALL ON public.docs_tracks TO service_role;

GRANT SELECT ON public.docs_sections TO authenticated, anon;
GRANT INSERT, UPDATE, DELETE ON public.docs_sections TO authenticated;
GRANT ALL ON public.docs_sections TO service_role;

GRANT SELECT ON public.docs_pages TO authenticated, anon;
GRANT INSERT, UPDATE, DELETE ON public.docs_pages TO authenticated;
GRANT ALL ON public.docs_pages TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.docs_change_proposals TO authenticated;
GRANT ALL ON public.docs_change_proposals TO service_role;

-- RLS
ALTER TABLE public.docs_tracks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.docs_sections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.docs_pages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.docs_change_proposals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "docs_tracks_public_read" ON public.docs_tracks FOR SELECT USING (true);
CREATE POLICY "docs_tracks_super_admin_write" ON public.docs_tracks FOR ALL USING (public.has_role(auth.uid(), 'super_admin')) WITH CHECK (public.has_role(auth.uid(), 'super_admin'));

CREATE POLICY "docs_sections_public_read" ON public.docs_sections FOR SELECT USING (true);
CREATE POLICY "docs_sections_super_admin_write" ON public.docs_sections FOR ALL USING (public.has_role(auth.uid(), 'super_admin')) WITH CHECK (public.has_role(auth.uid(), 'super_admin'));

CREATE POLICY "docs_pages_public_read" ON public.docs_pages FOR SELECT USING (true);
CREATE POLICY "docs_pages_super_admin_write" ON public.docs_pages FOR ALL USING (public.has_role(auth.uid(), 'super_admin')) WITH CHECK (public.has_role(auth.uid(), 'super_admin'));

CREATE POLICY "docs_proposals_super_admin_all" ON public.docs_change_proposals FOR ALL USING (public.has_role(auth.uid(), 'super_admin')) WITH CHECK (public.has_role(auth.uid(), 'super_admin'));

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.docs_touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

CREATE TRIGGER docs_tracks_touch BEFORE UPDATE ON public.docs_tracks FOR EACH ROW EXECUTE FUNCTION public.docs_touch_updated_at();
CREATE TRIGGER docs_sections_touch BEFORE UPDATE ON public.docs_sections FOR EACH ROW EXECUTE FUNCTION public.docs_touch_updated_at();
CREATE TRIGGER docs_pages_touch BEFORE UPDATE ON public.docs_pages FOR EACH ROW EXECUTE FUNCTION public.docs_touch_updated_at();

-- Apply proposal RPC
CREATE OR REPLACE FUNCTION public.apply_docs_proposal(_proposal_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  p record;
  _track_id uuid;
  _section_id uuid;
  _page_id uuid;
BEGIN
  IF NOT public.has_role(auth.uid(), 'super_admin'::app_role) THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  SELECT * INTO p FROM public.docs_change_proposals WHERE id = _proposal_id AND status = 'pending';
  IF p.id IS NULL THEN RAISE EXCEPTION 'proposal not found or not pending'; END IF;

  SELECT id INTO _track_id FROM public.docs_tracks WHERE slug = p.track_slug;
  IF _track_id IS NULL THEN RAISE EXCEPTION 'track not found: %', p.track_slug; END IF;

  IF p.page_id IS NOT NULL THEN
    UPDATE public.docs_pages SET
      title = COALESCE(p.proposed_title, title),
      description = COALESCE(p.proposed_description, description),
      content_json = COALESCE(p.proposed_content_json, content_json),
      content_html = COALESCE(p.proposed_content_html, content_html),
      updated_by = auth.uid()
    WHERE id = p.page_id
    RETURNING id INTO _page_id;
  ELSE
    SELECT id INTO _section_id FROM public.docs_sections WHERE track_id = _track_id ORDER BY display_order LIMIT 1;
    INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, content_json, content_html, updated_by)
    VALUES (_track_id, _section_id, p.page_slug, COALESCE(p.proposed_title, p.page_slug), p.proposed_description, p.proposed_content_json, p.proposed_content_html, auth.uid())
    RETURNING id INTO _page_id;
  END IF;

  UPDATE public.docs_change_proposals SET status='approved', reviewed_by=auth.uid(), reviewed_at=now() WHERE id=_proposal_id;
  RETURN _page_id;
END $$;

REVOKE ALL ON FUNCTION public.apply_docs_proposal(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.apply_docs_proposal(uuid) TO authenticated;

-- Seed tracks
INSERT INTO public.docs_tracks (slug, label, short_label, description, icon, accent, display_order, is_active) VALUES ('vendedor','Trilha do Vendedor','Vendedor','Para SDRs, closers e atendentes que usam o sistema no dia a dia.','Headphones','text-emerald-500',1,true) ON CONFLICT (slug) DO NOTHING;
INSERT INTO public.docs_tracks (slug, label, short_label, description, icon, accent, display_order, is_active) VALUES ('admin','Trilha do Admin','Admin','Para gestores que configuram a empresa, equipe, IA e integrações.','Settings','text-sky-500',2,true) ON CONFLICT (slug) DO NOTHING;
INSERT INTO public.docs_tracks (slug, label, short_label, description, icon, accent, display_order, is_active) VALUES ('super-admin','Trilha do Super Admin','Super Admin','Para donos da plataforma white label que gerenciam empresas e planos.','Crown','text-amber-500',3,true) ON CONFLICT (slug) DO NOTHING;
INSERT INTO public.docs_tracks (slug, label, short_label, description, icon, accent, display_order, is_active) VALUES ('desenvolvedor','Trilha do Desenvolvedor','Desenvolvedor','API, webhooks, edge functions e integrações técnicas.','Code2','text-violet-500',4,true) ON CONFLICT (slug) DO NOTHING;
INSERT INTO public.docs_tracks (slug, label, short_label, description, icon, accent, display_order, is_active) VALUES ('conceitos','Conceitos do Sistema','Conceitos','Glossário profundo dos conceitos principais.','BookMarked','text-rose-500',5,true) ON CONFLICT (slug) DO NOTHING;

-- Seed sections + pages (vendedor)
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Começando', 1 FROM public.docs_tracks WHERE slug='vendedor' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Atendimento', 2 FROM public.docs_tracks WHERE slug='vendedor' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'CRM', 3 FROM public.docs_tracks WHERE slug='vendedor' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'IA', 4 FROM public.docs_tracks WHERE slug='vendedor' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Automação', 5 FROM public.docs_tracks WHERE slug='vendedor' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Performance', 6 FROM public.docs_tracks WHERE slug='vendedor' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'primeiros-passos', 'Primeiros passos', 'Login, status online/pausa, troca de senha e o que esperar no primeiro dia.', 1 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Começando' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'inbox', 'Inbox: a central de conversas', 'Como funciona a caixa de entrada omnichannel, abas, filtros por setor e aceitar conversas.', 2 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Atendimento' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'conversa', 'Trabalhando uma conversa', 'Enviar texto, áudio, mídia, item do catálogo, transferir e encerrar.', 3 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Atendimento' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'whatsapp', 'Particularidades do WhatsApp', 'Debounce de 4s, chunking de mensagens, troca de instância e DDI 55.', 4 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Atendimento' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'lead', 'Lead: visão 360°', 'Resumo, BANT, Tarefas, Jornada, Origem, Carteira, Cadências e Formulários.', 5 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='CRM' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'deals', 'Pipeline e Deals', 'Criar oportunidade, valor automático por produto, Kanban e estágios.', 6 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='CRM' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'tarefas', 'Tarefas e follow-ups', 'Criar manualmente, gerar em lote por IA, alertas de atraso.', 7 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='CRM' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'agendamentos', 'Agendamentos', 'Ver agenda, criar evento e como a IA agenda sozinha.', 8 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='CRM' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'copiloto', 'Copiloto de Vendas', 'IA assistente que sugere mensagens, trata objeções e transcreve áudios.', 9 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='IA' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'cadencias', 'Cadências inteligentes', 'Sequências automáticas de toques para nutrir e recuperar leads.', 10 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Automação' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'bant', 'Qualificação BANT', 'Framework Budget/Authority/Need/Timing em 17 perguntas, score 0-100.', 11 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='CRM' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'relatorios', 'Metas, comissões e leaderboard', 'Acompanhe seus números, batidas de meta e ranking do time.', 12 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Performance' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'atalhos', 'Atalhos e dicas', 'Atalhos de teclado e hábitos que economizam tempo.', 13 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Performance' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'mobile', 'No celular (PWA)', 'Instalar como app, usar offline e receber notificações push.', 14 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Performance' WHERE t.slug='vendedor' ON CONFLICT (track_id, slug) DO NOTHING;

-- admin sections
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Começando', 1 FROM public.docs_tracks WHERE slug='admin' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Gestão', 2 FROM public.docs_tracks WHERE slug='admin' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Catálogo', 3 FROM public.docs_tracks WHERE slug='admin' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'IA', 4 FROM public.docs_tracks WHERE slug='admin' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Captura', 5 FROM public.docs_tracks WHERE slug='admin' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Automação', 6 FROM public.docs_tracks WHERE slug='admin' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Integrações', 7 FROM public.docs_tracks WHERE slug='admin' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Comunicação', 8 FROM public.docs_tracks WHERE slug='admin' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Performance', 9 FROM public.docs_tracks WHERE slug='admin' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'conceitos', 'Conceitos rápidos', 'Organização, setor, squad, produto e papel — antes de mergulhar.', 1 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Começando' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'equipe', 'Equipe: convidar e gerenciar', 'Convites por e-mail, papéis, squads, setores e exclusão segura.', 2 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Gestão' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'permissoes', 'Permissões granulares', 'Matriz completa de visibilidade da Inbox por setor.', 3 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Gestão' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'produtos', 'Produtos', 'Pitch, ICP, planos, preços, CTAs e otimização por IA.', 4 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Catálogo' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'brain', 'Brain: base de conhecimento', 'PDFs, URLs, FAQs, YouTube, .docx. Health Score e otimização.', 5 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Catálogo' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'catalogo', 'Catálogo de itens', 'Importar CSV, busca semântica e envio na conversa.', 6 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Catálogo' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'agentes', 'Agentes de IA', 'Persona, prompt, modelo, canais, hierarquia de seleção, ferramentas nativas.', 7 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='IA' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'funis', 'Funis visuais', 'Editor no-code com blocos, geração por IA, 4 temas independentes.', 8 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Captura' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'formularios', 'Formulários públicos', 'Wizard estilo Typeform em /f/:slug, captura UTMs e calcula score.', 9 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Captura' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'quizzes', 'Quizzes', 'Templates de qualificação com regras condicionais.', 10 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Captura' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'widget', 'Widget de site', 'Instalar funnel-widget.js em qualquer site externo.', 11 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Captura' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'cadencias', 'Cadências inteligentes', 'Sequências automáticas com tom contextual, business hours, gerador por IA.', 12 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Automação' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'agendamentos', 'Configurar agendamentos', 'Tipos de evento, Google Calendar, horário comercial.', 13 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Automação' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'auto-dispatch', 'Auto Dispatch', 'Distribuição automática de leads novos por capacidade e status.', 14 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Automação' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'tags', 'Tags e automações', 'Apply/remove, pós-venda, exclusões automáticas.', 15 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Automação' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'integracoes', 'Integrações', 'Hotmart, Cakto, Doppus, Sankhya, Facebook, Google, Firecrawl, ElevenLabs, Resend, Twilio.', 16 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Integrações' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'webhooks', 'Webhooks', 'Receiver genérico de entrada + dispatch de saída por produto/squad.', 17 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Integrações' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'email-massa', 'E-mail em massa', 'Templates com variáveis, segmentação, supressão e unsubscribe.', 18 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Comunicação' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'notificacoes', 'Notificações automáticas', 'Multicanal (in-app, e-mail, push) com regras configuráveis.', 19 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Comunicação' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'radar', 'Radar de IA', 'Escaneia leads e conversas, identifica oportunidades esquecidas.', 20 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='IA' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'relatorios', 'Relatórios', 'Funil, conversão, TMA/TMR/SLA, qualidade de conversa.', 21 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Performance' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'configuracoes', 'Configurações da empresa', 'Dados gerais, fuso, moeda, business hours, customização.', 22 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Performance' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'playbook', 'Boas práticas (playbook)', 'BANT, tratamento de objeções, biblioteca de materiais.', 23 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Performance' WHERE t.slug='admin' ON CONFLICT (track_id, slug) DO NOTHING;

-- super-admin
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Visão geral', 1 FROM public.docs_tracks WHERE slug='super-admin' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Marca', 2 FROM public.docs_tracks WHERE slug='super-admin' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Operação', 3 FROM public.docs_tracks WHERE slug='super-admin' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'visao-geral', 'O que é o modo white label', 'Você dono da plataforma, várias empresas como clientes, sua marca em tudo.', 1 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Visão geral' WHERE t.slug='super-admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'identidade', 'Identidade visual', 'Logo, cores HSL, nome, favicon e textos do login.', 2 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Marca' WHERE t.slug='super-admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'planos', 'Planos da plataforma', 'Criar planos com limites de leads, usuários, mensagens IA e integrações.', 3 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Marca' WHERE t.slug='super-admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'empresas', 'Empresas (organizações)', 'Criar, suspender, mover e auditar empresas-cliente.', 4 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Operação' WHERE t.slug='super-admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'whatsapp-server', 'Servidor Evolution global', 'Crie instâncias e atrele a empresas. Empresa escaneia o QR.', 5 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Operação' WHERE t.slug='super-admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'credenciais', 'Credenciais globais', 'Resend, Firecrawl, OpenAI override e outras chaves compartilhadas.', 6 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Operação' WHERE t.slug='super-admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'templates', 'Templates globais', 'E-mail, agentes, funis e cadências reutilizáveis por todas as empresas.', 7 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Operação' WHERE t.slug='super-admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'auditoria', 'Auditoria global', 'platform_audit_logs: tudo que aconteceu, quem fez, quando.', 8 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Operação' WHERE t.slug='super-admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'notificacoes', 'Notificações administrativas', 'Alertas multicanal para você, dono da plataforma.', 9 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Operação' WHERE t.slug='super-admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'dominio', 'Domínio próprio', 'CNAME, SSL automático e e-mails do seu domínio.', 10 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Operação' WHERE t.slug='super-admin' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'suporte', 'Suporte e Central de Ajuda', 'Tickets, base de conhecimento e SLAs.', 11 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Operação' WHERE t.slug='super-admin' ON CONFLICT (track_id, slug) DO NOTHING;

-- desenvolvedor
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Básico', 1 FROM public.docs_tracks WHERE slug='desenvolvedor' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Webhooks', 2 FROM public.docs_tracks WHERE slug='desenvolvedor' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Canais', 3 FROM public.docs_tracks WHERE slug='desenvolvedor' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Pagamentos', 4 FROM public.docs_tracks WHERE slug='desenvolvedor' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Widget', 5 FROM public.docs_tracks WHERE slug='desenvolvedor' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Avançado', 6 FROM public.docs_tracks WHERE slug='desenvolvedor' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'autenticacao', 'Autenticação', 'Bearer JWT, anon key, RLS e quando usar service role.', 1 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Básico' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'modelo-dados', 'Modelo de dados', 'Tabelas principais e relações.', 2 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Básico' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'webhook-entrada', 'Webhook de entrada (receiver)', 'Endpoint genérico para receber leads de qualquer sistema.', 3 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Webhooks' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'webhook-saida', 'Webhooks de saída', 'Eventos da plataforma que sua aplicação recebe.', 4 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Webhooks' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'edge-functions', 'Edge Functions', 'Catálogo das funções serverless da plataforma.', 5 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Webhooks' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'whatsapp-cloud', 'WhatsApp Cloud API (Meta)', 'Webhook payload e fluxo de configuração com Meta.', 6 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Canais' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'evolution', 'Evolution API', 'QR, status e envio multi-instância.', 7 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Canais' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'facebook-leads', 'Facebook Lead Ads', 'Integração nativa Graph API direto no CRM.', 8 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Canais' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'hotmart', 'Hotmart', 'Postback (validação hottok) + OAuth para sync de vendas.', 9 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Pagamentos' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'cakto-doppus', 'Cakto e Doppus', 'Webhooks de pedidos, recuperação de checkout abandonado.', 10 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Pagamentos' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'google-calendar', 'Google Calendar', 'OAuth, refresh token e sync bidirecional.', 11 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Pagamentos' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'widget-js', 'Widget JS embedável', 'funnel-widget.js sem dependências, instala em qualquer site.', 12 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Widget' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'realtime', 'Realtime', 'Supabase Realtime para Inbox, presença e notificações.', 13 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Avançado' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'limites', 'Limites e quotas', 'Safety limits da IA, rate limits da API, paginação.', 14 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Avançado' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'erros', 'Erros comuns e códigos', 'Como diagnosticar problemas de RLS, permissões e payload.', 15 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Avançado' WHERE t.slug='desenvolvedor' ON CONFLICT (track_id, slug) DO NOTHING;

-- conceitos
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'CRM', 1 FROM public.docs_tracks WHERE slug='conceitos' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Atendimento', 2 FROM public.docs_tracks WHERE slug='conceitos' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Catálogo', 3 FROM public.docs_tracks WHERE slug='conceitos' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'IA', 4 FROM public.docs_tracks WHERE slug='conceitos' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Automação', 5 FROM public.docs_tracks WHERE slug='conceitos' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Captura', 6 FROM public.docs_tracks WHERE slug='conceitos' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Segurança', 7 FROM public.docs_tracks WHERE slug='conceitos' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_sections (track_id, label, display_order) SELECT id, 'Plataforma', 8 FROM public.docs_tracks WHERE slug='conceitos' ON CONFLICT (track_id, label) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'lead', 'Lead', 'Conceito: Lead', 1 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='CRM' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'deal', 'Deal', 'Conceito: Deal', 2 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='CRM' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'conversa', 'Conversa', 'Conceito: Conversa', 3 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Atendimento' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'setor', 'Setor', 'Conceito: Setor', 4 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Atendimento' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'squad', 'Squad', 'Conceito: Squad', 5 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Atendimento' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'produto', 'Produto', 'Conceito: Produto', 6 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Catálogo' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'brain', 'Brain', 'Conceito: Brain', 7 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='IA' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'agente-ia', 'Agente IA', 'Conceito: Agente IA', 8 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='IA' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'copiloto', 'Copiloto', 'Conceito: Copiloto', 9 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='IA' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'cadencia', 'Cadência', 'Conceito: Cadência', 10 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Automação' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'funil', 'Funil de captura', 'Conceito: Funil de captura', 11 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Captura' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'tag', 'Tag', 'Conceito: Tag', 12 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Automação' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'permissoes', 'Permissões granulares', 'Conceito: Permissões granulares', 13 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Segurança' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'bant', 'BANT', 'Conceito: BANT', 14 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='CRM' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'auto-dispatch', 'Auto Dispatch', 'Conceito: Auto Dispatch', 15 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Automação' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'atendente-unico', 'Atendente único', 'Conceito: Atendente único', 16 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Atendimento' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'handoff', 'Handoff', 'Conceito: Handoff', 17 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='IA' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;
INSERT INTO public.docs_pages (track_id, section_id, slug, title, description, display_order) SELECT t.id, s.id, 'white-label', 'White Label', 'Conceito: White Label', 18 FROM public.docs_tracks t LEFT JOIN public.docs_sections s ON s.track_id=t.id AND s.label='Plataforma' WHERE t.slug='conceitos' ON CONFLICT (track_id, slug) DO NOTHING;