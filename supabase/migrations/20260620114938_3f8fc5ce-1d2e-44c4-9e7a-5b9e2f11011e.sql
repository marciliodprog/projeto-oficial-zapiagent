ALTER TABLE public.product_agents
ADD COLUMN IF NOT EXISTS qualification_schema jsonb;

COMMENT ON COLUMN public.product_agents.qualification_schema IS
'Schema de qualificação customizado por agente. Estrutura: { name: string, fields: [{ key, label, weight, hints[] }] }. Quando NULL, usa BANT padrão.';