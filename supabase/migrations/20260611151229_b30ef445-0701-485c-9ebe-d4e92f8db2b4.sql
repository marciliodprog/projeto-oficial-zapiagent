
ALTER TABLE public.leads
  ADD COLUMN IF NOT EXISTS whatsapp_opt_in boolean,
  ADD COLUMN IF NOT EXISTS whatsapp_opted_out_at timestamptz;

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS meta_template_config jsonb;

ALTER TABLE public.cadence_steps
  ADD COLUMN IF NOT EXISTS reengagement_template_id uuid REFERENCES public.whatsapp_meta_templates(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS reengagement_variable_mapping jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE public.whatsapp_meta_templates
  ADD COLUMN IF NOT EXISTS usage_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_send_error text,
  ADD COLUMN IF NOT EXISTS last_send_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_leads_whatsapp_opt_in ON public.leads(whatsapp_opt_in) WHERE whatsapp_opt_in = false;
CREATE INDEX IF NOT EXISTS idx_cadence_steps_reeng_tpl ON public.cadence_steps(reengagement_template_id) WHERE reengagement_template_id IS NOT NULL;
