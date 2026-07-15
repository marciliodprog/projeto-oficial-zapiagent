
DROP VIEW IF EXISTS public.lead_journey_events;
CREATE VIEW public.lead_journey_events
  WITH (security_invoker = true)
  AS SELECT * FROM public.journey_events WHERE subject_type = 'lead';
GRANT SELECT ON public.lead_journey_events TO authenticated;
GRANT ALL ON public.lead_journey_events TO service_role;
