
-- 1. push_subscriptions table
CREATE TABLE public.push_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  organization_id uuid,
  endpoint text NOT NULL UNIQUE,
  p256dh text NOT NULL,
  auth text NOT NULL,
  user_agent text,
  platform text,
  is_standalone boolean DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);

CREATE INDEX idx_push_subs_user ON public.push_subscriptions(user_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_push_subs_org ON public.push_subscriptions(organization_id) WHERE revoked_at IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.push_subscriptions TO authenticated;
GRANT ALL ON public.push_subscriptions TO service_role;

ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own push subs"
ON public.push_subscriptions
FOR ALL
TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- 2. granular push preferences on existing user_notification_settings
ALTER TABLE public.user_notification_settings
  ADD COLUMN IF NOT EXISTS push_new_message boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS push_queue_lead boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS push_assigned_lead boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS push_booking_reminder boolean NOT NULL DEFAULT true;
