ALTER TABLE public.user_notification_settings 
  ADD COLUMN IF NOT EXISTS push_sale_won boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS push_new_booking boolean NOT NULL DEFAULT true;