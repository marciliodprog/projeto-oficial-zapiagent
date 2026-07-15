UPDATE webchat_messages
SET metadata = jsonb_set(
  metadata,
  '{media,kind}',
  to_jsonb(metadata->'media'->>'type')
)
WHERE metadata ? 'media'
  AND metadata->'media' ? 'type'
  AND NOT (metadata->'media' ? 'kind')
  AND (metadata->'media'->>'url') IS NOT NULL;