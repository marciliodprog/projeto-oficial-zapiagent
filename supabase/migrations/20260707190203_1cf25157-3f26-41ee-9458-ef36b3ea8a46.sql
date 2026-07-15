
ALTER TABLE public.org_ai_routing DROP CONSTRAINT IF EXISTS org_ai_routing_capability_check;
ALTER TABLE public.org_ai_routing ADD CONSTRAINT org_ai_routing_capability_check CHECK (capability = ANY (ARRAY['agent_chat','sales_copilot','audio_transcription','image_vision','content_generation','analysis_insights','embeddings','voice_realtime']));

ALTER TABLE public.org_ai_routing DROP CONSTRAINT IF EXISTS org_ai_routing_provider_check;
ALTER TABLE public.org_ai_routing ADD CONSTRAINT org_ai_routing_provider_check CHECK (provider = ANY (ARRAY['lovable','openai','anthropic','gemini','grok','xai']));
