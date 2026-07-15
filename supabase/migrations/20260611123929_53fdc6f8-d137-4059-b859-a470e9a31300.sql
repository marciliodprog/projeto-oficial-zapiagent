ALTER TABLE public.campaign_targets
  ADD COLUMN IF NOT EXISTS connection_type text NOT NULL DEFAULT 'evolution';

ALTER TABLE public.campaign_targets
  DROP CONSTRAINT IF EXISTS campaign_targets_connection_type_chk;

ALTER TABLE public.campaign_targets
  ADD CONSTRAINT campaign_targets_connection_type_chk
  CHECK (connection_type IN ('evolution','meta_whatsapp'));