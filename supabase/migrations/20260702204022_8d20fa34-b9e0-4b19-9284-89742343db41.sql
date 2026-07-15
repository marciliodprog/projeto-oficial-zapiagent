ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'ai_handoff';
ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'human_handoff';
ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'agent_tool_executed';
ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'sale_cancelled';
ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'sale_refunded';
ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'commission_created';