ALTER TABLE public.voice_calls
  ADD COLUMN IF NOT EXISTS post_call_automations jsonb NOT NULL DEFAULT '{"rules": []}'::jsonb;

COMMENT ON COLUMN public.voice_calls.post_call_automations IS
  'Regras de automação pós-chamada por outcome: { rules: [{ outcome, cadence_id?, create_task?, task_title?, task_priority?, task_due_hours?, notify_admins? }] }';
