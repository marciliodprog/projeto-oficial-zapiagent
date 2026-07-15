
CREATE TABLE public.product_agent_connections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id uuid NOT NULL REFERENCES public.product_agents(id) ON DELETE CASCADE,
  connection_type text NOT NULL CHECK (connection_type IN ('evolution','meta_whatsapp','instagram')),
  connection_id uuid NOT NULL,
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agent_id, connection_type, connection_id)
);

CREATE INDEX idx_pac_lookup ON public.product_agent_connections(connection_type, connection_id);
CREATE INDEX idx_pac_agent ON public.product_agent_connections(agent_id);
CREATE INDEX idx_pac_org ON public.product_agent_connections(organization_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.product_agent_connections TO authenticated;
GRANT ALL ON public.product_agent_connections TO service_role;

ALTER TABLE public.product_agent_connections ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Org members manage agent connections"
  ON public.product_agent_connections
  FOR ALL
  TO authenticated
  USING (
    public.has_role(auth.uid(), 'super_admin')
    OR public.user_belongs_to_organization(auth.uid(), organization_id)
  )
  WITH CHECK (
    public.has_role(auth.uid(), 'super_admin')
    OR public.user_belongs_to_organization(auth.uid(), organization_id)
  );

-- Backfill: copy existing evolution_instance_id bindings
INSERT INTO public.product_agent_connections (agent_id, connection_type, connection_id, organization_id)
SELECT pa.id, 'evolution', pa.evolution_instance_id, pa.organization_id
FROM public.product_agents pa
WHERE pa.evolution_instance_id IS NOT NULL
  AND pa.organization_id IS NOT NULL
ON CONFLICT (agent_id, connection_type, connection_id) DO NOTHING;
