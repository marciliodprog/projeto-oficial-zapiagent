DO $$
DECLARE
  v_url text := 'https://syvhrtaksjcvhrzhbltt.supabase.co/functions/v1';
  v_key text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN5dmhydGFrc2pjdmhyemhibHR0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTU1NDEsImV4cCI6MjA5MzYzMTU0MX0.wnXrkMUWnN4MdBt1QB2p3BXlHTwxxsox8zLrV2sMZPw';
BEGIN
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'voice-campaign-tick';

  PERFORM cron.schedule(
    'voice-campaign-tick',
    '* * * * *',
    format(
      $f$ select net.http_post(url:=%L, headers:=%L::jsonb, body:='{}'::jsonb) $f$,
      v_url || '/voice-campaign-tick',
      json_build_object('Content-Type','application/json','Authorization','Bearer '||v_key,'apikey',v_key)::text
    )
  );
END $$;