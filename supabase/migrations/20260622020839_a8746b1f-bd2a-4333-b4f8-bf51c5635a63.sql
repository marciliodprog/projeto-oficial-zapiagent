ALTER TABLE public.mia_actions DROP CONSTRAINT IF EXISTS mia_actions_type_check;
ALTER TABLE public.mia_actions ADD CONSTRAINT mia_actions_type_check
  CHECK (action_type = ANY (ARRAY[
    'create_task','schedule_followup','notify_seller',
    'open_conversation','open_lead','open_calendar','open_tasks','open_report',
    'send_whatsapp','send_email','send_notification','send_conversation_message',
    'assign_conversation','transfer_sector','close_conversation',
    'takeover_from_agent','handback_to_agent',
    'reschedule_booking','cancel_booking'
  ]));