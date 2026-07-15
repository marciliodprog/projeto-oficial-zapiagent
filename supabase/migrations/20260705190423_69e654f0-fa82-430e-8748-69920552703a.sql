
-- Amplia provedores de IA para incluir xAI (enum se existir)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_provider') THEN
    BEGIN
      ALTER TYPE public.ai_provider ADD VALUE IF NOT EXISTS 'xai';
    EXCEPTION WHEN others THEN NULL;
    END;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ai_capability') THEN
    BEGIN
      ALTER TYPE public.ai_capability ADD VALUE IF NOT EXISTS 'voice_call';
    EXCEPTION WHEN others THEN NULL;
    END;
  END IF;
END $$;

-- ============================================================================
-- VOICE AGENTS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.voice_agents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  objective TEXT,
  system_prompt TEXT NOT NULL,
  voice_option TEXT NOT NULL DEFAULT 'default',
  language TEXT NOT NULL DEFAULT 'pt-BR',
  provider TEXT NOT NULL DEFAULT 'xai',
  external_agent_id TEXT,
  tools JSONB NOT NULL DEFAULT '[]'::jsonb,
  is_active BOOLEAN NOT NULL DEFAULT true,
  is_inbound_default BOOLEAN NOT NULL DEFAULT false,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.voice_agents TO authenticated;
GRANT ALL ON public.voice_agents TO service_role;
ALTER TABLE public.voice_agents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "voice_agents_org_select" ON public.voice_agents FOR SELECT TO authenticated
  USING (
    organization_id = public.get_user_organization(auth.uid())
    OR public.is_super_admin(auth.uid())
  );
CREATE POLICY "voice_agents_admin_write" ON public.voice_agents FOR ALL TO authenticated
  USING (
    (organization_id = public.get_user_organization(auth.uid())
      AND (public.has_role(auth.uid(),'admin'::app_role) OR public.has_role(auth.uid(),'manager'::app_role)))
    OR public.is_super_admin(auth.uid())
  )
  WITH CHECK (
    (organization_id = public.get_user_organization(auth.uid())
      AND (public.has_role(auth.uid(),'admin'::app_role) OR public.has_role(auth.uid(),'manager'::app_role)))
    OR public.is_super_admin(auth.uid())
  );

-- ============================================================================
-- VOICE CONTEXTS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.voice_contexts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  content TEXT NOT NULL,
  product_id UUID REFERENCES public.products(id) ON DELETE SET NULL,
  tags TEXT[] NOT NULL DEFAULT '{}',
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.voice_contexts TO authenticated;
GRANT ALL ON public.voice_contexts TO service_role;
ALTER TABLE public.voice_contexts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "voice_contexts_org_select" ON public.voice_contexts FOR SELECT TO authenticated
  USING (
    organization_id = public.get_user_organization(auth.uid())
    OR public.is_super_admin(auth.uid())
  );
CREATE POLICY "voice_contexts_admin_write" ON public.voice_contexts FOR ALL TO authenticated
  USING (
    (organization_id = public.get_user_organization(auth.uid())
      AND (public.has_role(auth.uid(),'admin'::app_role) OR public.has_role(auth.uid(),'manager'::app_role)))
    OR public.is_super_admin(auth.uid())
  )
  WITH CHECK (
    (organization_id = public.get_user_organization(auth.uid())
      AND (public.has_role(auth.uid(),'admin'::app_role) OR public.has_role(auth.uid(),'manager'::app_role)))
    OR public.is_super_admin(auth.uid())
  );

-- ============================================================================
-- VOICE CAMPAIGNS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.voice_campaigns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  voice_agent_id UUID REFERENCES public.voice_agents(id) ON DELETE SET NULL,
  voice_context_id UUID REFERENCES public.voice_contexts(id) ON DELETE SET NULL,
  lead_filter JSONB NOT NULL DEFAULT '{}'::jsonb,
  schedule JSONB NOT NULL DEFAULT '{}'::jsonb,
  max_concurrent INTEGER NOT NULL DEFAULT 3,
  max_attempts INTEGER NOT NULL DEFAULT 2,
  retry_interval_minutes INTEGER NOT NULL DEFAULT 60,
  status TEXT NOT NULL DEFAULT 'draft',
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.voice_campaigns TO authenticated;
GRANT ALL ON public.voice_campaigns TO service_role;
ALTER TABLE public.voice_campaigns ENABLE ROW LEVEL SECURITY;

CREATE POLICY "voice_campaigns_org_select" ON public.voice_campaigns FOR SELECT TO authenticated
  USING (
    organization_id = public.get_user_organization(auth.uid())
    OR public.is_super_admin(auth.uid())
  );
CREATE POLICY "voice_campaigns_admin_write" ON public.voice_campaigns FOR ALL TO authenticated
  USING (
    (organization_id = public.get_user_organization(auth.uid())
      AND (public.has_role(auth.uid(),'admin'::app_role) OR public.has_role(auth.uid(),'manager'::app_role)))
    OR public.is_super_admin(auth.uid())
  )
  WITH CHECK (
    (organization_id = public.get_user_organization(auth.uid())
      AND (public.has_role(auth.uid(),'admin'::app_role) OR public.has_role(auth.uid(),'manager'::app_role)))
    OR public.is_super_admin(auth.uid())
  );

-- ============================================================================
-- VOICE CAMPAIGN TARGETS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.voice_campaign_targets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id UUID NOT NULL REFERENCES public.voice_campaigns(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  lead_id UUID REFERENCES public.leads(id) ON DELETE CASCADE,
  phone TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  last_attempt_at TIMESTAMPTZ,
  last_error TEXT,
  scheduled_for TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_vct_campaign_status ON public.voice_campaign_targets(campaign_id, status);
CREATE INDEX IF NOT EXISTS idx_vct_scheduled ON public.voice_campaign_targets(scheduled_for) WHERE status = 'pending';
GRANT SELECT, INSERT, UPDATE, DELETE ON public.voice_campaign_targets TO authenticated;
GRANT ALL ON public.voice_campaign_targets TO service_role;
ALTER TABLE public.voice_campaign_targets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "vct_org_all" ON public.voice_campaign_targets FOR ALL TO authenticated
  USING (
    organization_id = public.get_user_organization(auth.uid())
    OR public.is_super_admin(auth.uid())
  )
  WITH CHECK (
    organization_id = public.get_user_organization(auth.uid())
    OR public.is_super_admin(auth.uid())
  );

-- ============================================================================
-- CALL LOGS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.call_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  lead_id UUID REFERENCES public.leads(id) ON DELETE SET NULL,
  voice_agent_id UUID REFERENCES public.voice_agents(id) ON DELETE SET NULL,
  campaign_id UUID REFERENCES public.voice_campaigns(id) ON DELETE SET NULL,
  campaign_target_id UUID REFERENCES public.voice_campaign_targets(id) ON DELETE SET NULL,
  provider TEXT NOT NULL DEFAULT 'xai',
  direction TEXT NOT NULL DEFAULT 'outbound',
  from_number TEXT,
  to_number TEXT,
  call_sid TEXT,
  status TEXT NOT NULL DEFAULT 'initiated',
  status_reason TEXT,
  started_at TIMESTAMPTZ,
  answered_at TIMESTAMPTZ,
  ended_at TIMESTAMPTZ,
  duration_sec INTEGER,
  cost_usd NUMERIC(10,4),
  recording_url TEXT,
  transcription_text TEXT,
  summary TEXT,
  sentiment TEXT,
  key_points JSONB NOT NULL DEFAULT '[]'::jsonb,
  next_actions JSONB NOT NULL DEFAULT '[]'::jsonb,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  raw_payload JSONB,
  initiated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_call_logs_org_created ON public.call_logs(organization_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_call_logs_lead ON public.call_logs(lead_id);
CREATE INDEX IF NOT EXISTS idx_call_logs_campaign ON public.call_logs(campaign_id);
CREATE INDEX IF NOT EXISTS idx_call_logs_call_sid ON public.call_logs(call_sid);
CREATE INDEX IF NOT EXISTS idx_call_logs_status ON public.call_logs(organization_id, status);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.call_logs TO authenticated;
GRANT ALL ON public.call_logs TO service_role;
ALTER TABLE public.call_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "call_logs_org_select" ON public.call_logs FOR SELECT TO authenticated
  USING (
    organization_id = public.get_user_organization(auth.uid())
    OR public.is_super_admin(auth.uid())
  );
CREATE POLICY "call_logs_org_insert" ON public.call_logs FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = public.get_user_organization(auth.uid())
    OR public.is_super_admin(auth.uid())
  );
CREATE POLICY "call_logs_update" ON public.call_logs FOR UPDATE TO authenticated
  USING (
    (organization_id = public.get_user_organization(auth.uid())
      AND (public.has_role(auth.uid(),'admin'::app_role) OR public.has_role(auth.uid(),'manager'::app_role) OR initiated_by = auth.uid()))
    OR public.is_super_admin(auth.uid())
  );
CREATE POLICY "call_logs_delete" ON public.call_logs FOR DELETE TO authenticated
  USING (
    (organization_id = public.get_user_organization(auth.uid())
      AND (public.has_role(auth.uid(),'admin'::app_role) OR public.has_role(auth.uid(),'manager'::app_role)))
    OR public.is_super_admin(auth.uid())
  );

-- ============================================================================
-- CALL EVENTS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.call_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  call_log_id UUID NOT NULL REFERENCES public.call_logs(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL,
  role TEXT,
  content TEXT,
  payload JSONB,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_call_events_log ON public.call_events(call_log_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_call_events_org ON public.call_events(organization_id, occurred_at DESC);
GRANT SELECT, INSERT ON public.call_events TO authenticated;
GRANT ALL ON public.call_events TO service_role;
ALTER TABLE public.call_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "call_events_org_select" ON public.call_events FOR SELECT TO authenticated
  USING (
    organization_id = public.get_user_organization(auth.uid())
    OR public.is_super_admin(auth.uid())
  );

-- Realtime
DO $$ BEGIN
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.call_events; EXCEPTION WHEN others THEN NULL; END;
  BEGIN ALTER PUBLICATION supabase_realtime ADD TABLE public.call_logs; EXCEPTION WHEN others THEN NULL; END;
END $$;
ALTER TABLE public.call_events REPLICA IDENTITY FULL;
ALTER TABLE public.call_logs REPLICA IDENTITY FULL;

-- ============================================================================
-- VOICE ACTIONS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.voice_actions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  call_log_id UUID NOT NULL REFERENCES public.call_logs(id) ON DELETE CASCADE,
  lead_id UUID REFERENCES public.leads(id) ON DELETE SET NULL,
  action_type TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  due_at TIMESTAMPTZ,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  status TEXT NOT NULL DEFAULT 'pending',
  executed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_voice_actions_log ON public.voice_actions(call_log_id);
CREATE INDEX IF NOT EXISTS idx_voice_actions_lead ON public.voice_actions(lead_id);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.voice_actions TO authenticated;
GRANT ALL ON public.voice_actions TO service_role;
ALTER TABLE public.voice_actions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "voice_actions_org_all" ON public.voice_actions FOR ALL TO authenticated
  USING (
    organization_id = public.get_user_organization(auth.uid())
    OR public.is_super_admin(auth.uid())
  )
  WITH CHECK (
    organization_id = public.get_user_organization(auth.uid())
    OR public.is_super_admin(auth.uid())
  );

-- ============================================================================
-- Triggers updated_at
-- ============================================================================
CREATE TRIGGER trg_voice_agents_updated BEFORE UPDATE ON public.voice_agents
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_voice_contexts_updated BEFORE UPDATE ON public.voice_contexts
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_voice_campaigns_updated BEFORE UPDATE ON public.voice_campaigns
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_vct_updated BEFORE UPDATE ON public.voice_campaign_targets
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_call_logs_updated BEFORE UPDATE ON public.call_logs
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trg_voice_actions_updated BEFORE UPDATE ON public.voice_actions
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================================
-- Trigger: cria journey_event quando ligação finaliza
-- ============================================================================
CREATE OR REPLACE FUNCTION public.log_call_journey_event()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.lead_id IS NOT NULL
     AND NEW.status IN ('completed','failed','no_answer','busy','canceled')
     AND (OLD.status IS DISTINCT FROM NEW.status)
  THEN
    BEGIN
      INSERT INTO public.journey_events (
        organization_id, lead_id, event_type, event_category,
        title, description, metadata, created_at
      ) VALUES (
        NEW.organization_id,
        NEW.lead_id,
        'voice_call',
        'interaction',
        CASE WHEN NEW.direction = 'inbound' THEN 'Ligação recebida' ELSE 'Ligação realizada' END,
        COALESCE(NEW.summary, 'Ligação ' || NEW.status),
        jsonb_build_object(
          'call_log_id', NEW.id,
          'duration_sec', NEW.duration_sec,
          'status', NEW.status,
          'sentiment', NEW.sentiment,
          'direction', NEW.direction
        ),
        COALESCE(NEW.ended_at, now())
      );
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_call_logs_journey
  AFTER UPDATE ON public.call_logs
  FOR EACH ROW EXECUTE FUNCTION public.log_call_journey_event();
