ALTER TABLE public.webchat_conversations
  ADD COLUMN IF NOT EXISTS closing_reason text,
  ADD COLUMN IF NOT EXISTS closing_outcome text,
  ADD COLUMN IF NOT EXISTS closing_value numeric;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'webchat_conv_closing_outcome_check'
  ) THEN
    ALTER TABLE public.webchat_conversations
      ADD CONSTRAINT webchat_conv_closing_outcome_check
      CHECK (closing_outcome IS NULL OR closing_outcome IN ('won','lost','no_deal','other'));
  END IF;
END $$;