
CREATE OR REPLACE FUNCTION public.exec_finalize_campaign_targets(
  p_ids        uuid[],
  p_statuses   text[],
  p_errors     text[],
  p_sent_ats   timestamptz[],
  p_conv_ids   uuid[],
  p_queue_ids  uuid[]
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count int;
BEGIN
  IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  WITH input AS (
    SELECT
      u.id,
      u.status,
      u.err,
      u.sent_at,
      u.conv_id,
      u.queue_id
    FROM unnest(p_ids, p_statuses, p_errors, p_sent_ats, p_conv_ids, p_queue_ids)
      AS u(id, status, err, sent_at, conv_id, queue_id)
  )
  UPDATE public.campaign_targets ct
     SET status            = i.status,
         error             = i.err,
         sent_at           = COALESCE(i.sent_at, ct.sent_at),
         conversation_id   = COALESCE(i.conv_id,  ct.conversation_id),
         outreach_queue_id = COALESCE(i.queue_id, ct.outreach_queue_id)
    FROM input i
   WHERE ct.id = i.id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END
$$;

REVOKE EXECUTE ON FUNCTION public.exec_finalize_campaign_targets(uuid[], text[], text[], timestamptz[], uuid[], uuid[]) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exec_finalize_campaign_targets(uuid[], text[], text[], timestamptz[], uuid[], uuid[]) TO service_role;
