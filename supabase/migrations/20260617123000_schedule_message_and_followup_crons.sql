-- Ensure scheduled inbox messages and AI follow-ups are actually dispatched.
-- Both functions are idempotent and internally limit their batch size, so a
-- one-minute tick keeps short delays reliable without requiring a user session.

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

DO $$
DECLARE
  v_url text := 'https://syvhrtaksjcvhrzhbltt.supabase.co/functions/v1';
  -- Project anon key. These functions run with their own service-role client
  -- internally and are exposed to cron via verify_jwt=false in config.toml.
  v_key text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN5dmhydGFrc2pjdmhyemhibHR0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTU1NDEsImV4cCI6MjA5MzYzMTU0MX0.wnXrkMUWnN4MdBt1QB2p3BXlHTwxxsox8zLrV2sMZPw';
BEGIN
  PERFORM cron.unschedule(jobid)
  FROM cron.job
  WHERE jobname IN ('process-scheduled-messages', 'ai-followup-cron');

  PERFORM cron.schedule(
    'process-scheduled-messages',
    '* * * * *',
    format(
      $f$ select net.http_post(url:=%L, headers:=%L::jsonb, body:='{}'::jsonb) $f$,
      v_url || '/process-scheduled-messages',
      json_build_object('Content-Type','application/json','Authorization','Bearer '||v_key,'apikey',v_key)::text
    )
  );

  PERFORM cron.schedule(
    'ai-followup-cron',
    '* * * * *',
    format(
      $f$ select net.http_post(url:=%L, headers:=%L::jsonb, body:='{}'::jsonb) $f$,
      v_url || '/ai-followup-cron',
      json_build_object('Content-Type','application/json','Authorization','Bearer '||v_key,'apikey',v_key)::text
    )
  );
END $$;
