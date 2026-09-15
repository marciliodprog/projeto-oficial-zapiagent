# Snapshot completo do banco de dados — Vendus / ZapiAgent

> Documento gerado automaticamente a partir do **banco real** (`pg_catalog` + `pg_dump`).
> Serve como referência para uma futura migração **sem perda de dados, integrações e informações**.

Arquivos que compõem o snapshot:

| Arquivo | Conteúdo |
|---|---|
| `docs/DATABASE_SNAPSHOT.md` | Este documento — visão geral, inventário, ordem de migração e checklist |
| `docs/DATABASE_SNAPSHOT.sql` | DDL completo (schema `public`): tabelas, colunas, chaves, índices, funções, triggers, views, RLS e GRANTs. Recria 100% da estrutura em um banco vazio |
| `supabase/migrations/` | Histórico de migrations (aplicado incrementalmente) |
| `supabase/migrations_shared/` | Baselines consolidados antigos (referência histórica — defasados) |

Gerado em: **2026-09-15**

---

## 1. Inventário geral

| Objeto | Quantidade |
|---|---:|
| Tabelas (schema `public`) | 214 |
| Colunas | 3.331 |
| Chaves estrangeiras | 459 |
| Restrições únicas | 72 |
| Restrições de verificação (check) | 133 |
| Índices (total) | 697 |
| Funções | 305 |
| Triggers (não internos) | 168 |
| Views | 8 |
| Views materializadas | 0 |
| Políticas de acesso (RLS) | 520 |
| Tabelas com RLS ativo | 214 (100%) |
| Tipos enumerados | 14 |
| Extensões | 10 |
| Buckets de arquivos | 17 |

> Atenção: o antigo `docs/DATABASE.md` (baseline de 2026-05-04) descreve 139 tabelas e 377 políticas.
> Ele está **defasado**. Este snapshot é a fonte de verdade atual.

---

## 2. Extensões instaladas

pg_cron 1.6.4 · pg_net 0.20.3 · pg_stat_statements 1.11 · pg_trgm 1.6 · pgcrypto 1.3 · pgmq 1.5.1 · plpgsql 1.0 · supabase_vault 0.3.1 · uuid-ossp 1.1 · vector 0.8.2

No destino, instale as extensões **antes** de aplicar o DDL.

---

## 3. Tipos enumerados

- **app_role**: admin, manager, seller, super_admin
- **interaction_channel**: whatsapp, email, phone, instagram, telegram, other
- **journey_actor_type**: human, ai, system, external
- **journey_event_category**: origin, contact, attendance, qualification, opportunity, meeting, proposal, negotiation, sale, post_sale, system
- **journey_event_type**: lead_created, lead_updated, lead_assigned, lead_transferred, lead_archived, lead_reopened, lead_qualified, lead_disqualified, temperature_changed, tag_added, tag_removed, field_changed, first_conversation, first_message_in, first_reply_out, human_reply, ai_reply, conversation_accepted, conversation_transferred, conversation_archived, conversation_reopened, message_scheduled, message_sent, message_read, call_made, opportunity_created, pipeline_changed, stage_changed, meeting_created, meeting_confirmed, meeting_cancelled, task_created, task_completed, followup_created, followup_done, proposal_created, proposal_sent, proposal_viewed, pix_generated, pix_paid, checkout_created, sale_completed, post_sale_started, customer_lost, customer_reactivated, campaign_identified, meta_ctwa_received, meta_click_received, ad_click_received, session_started, session_ended, owner_changed, cadence_enrolled, cadence_step_sent, cadence_completed, wa_template_sent, wa_window_expired, ai_handoff, human_handoff, agent_tool_executed, sale_cancelled, sale_refunded, commission_created
- **lead_temperature**: hot, warm, cold
- **notification_type**: cadence, urgency, opportunity, audit, system
- **product_status**: draft, review, published, archived
- **sector_rotation_strategy**: round_robin, least_busy, random
- **support_ticket_priority**: low, normal, high, urgent
- **support_ticket_status**: open, in_progress, resolved, closed
- **task_priority**: low, medium, high, urgent
- **task_status**: pending, in_progress, completed, overdue
- **webchat_conversation_status**: bot_active, waiting_human, human_active, closed

---

## 4. Views

- `admin_cron_health`
- `lead_journey_events`
- `lead_journey_touchpoints_v`
- `platform_branding_public`
- `public_booking_profiles`
- `v_agent_quality_30d`
- `v_campaign_throughput`
- `v_provider_health`

---

## 5. Tabelas — colunas, regras de acesso e volume

Todas as tabelas têm RLS habilitado. A contagem de registros é uma estimativa do
otimizador (`pg_stat_user_tables`) e serve para dimensionar a migração.

| Tabela | Colunas | Políticas RLS | RLS ativo | Registros (aprox.) |
|---|---:|---:|---|---:|
| `admin_agent_messages` | 9 | 2 | sim | 0 |
| `admin_notifications` | 16 | 3 | sim | 0 |
| `agent_action_logs` | 12 | 2 | sim | 0 |
| `agent_activation_logs` | 11 | 2 | sim | 0 |
| `agent_handoff_history` | 11 | 2 | sim | 0 |
| `agent_post_sale_scenarios` | 14 | 4 | sim | 0 |
| `agent_routing_rules` | 18 | 2 | sim | 0 |
| `agent_safety_limits` | 7 | 2 | sim | 0 |
| `agent_specialists` | 10 | 2 | sim | 0 |
| `agent_tool_executions` | 15 | 3 | sim | 0 |
| `agent_training_materials` | 16 | 2 | sim | 0 |
| `ai_audits` | 7 | 2 | sim | 0 |
| `ai_insights` | 10 | 2 | sim | 0 |
| `ai_knowledge_base` | 10 | 2 | sim | 0 |
| `ai_outreach_queue` | 30 | 3 | sim | 0 |
| `ai_prompt_experiments` | 12 | 2 | sim | 0 |
| `ai_prompt_variants` | 13 | 2 | sim | 0 |
| `ai_quality_evaluations` | 20 | 2 | sim | 0 |
| `ai_response_feedback` | 11 | 4 | sim | 0 |
| `ai_router_failures` | 8 | 1 | sim | 0 |
| `ai_usage_logs` | 13 | 2 | sim | 0 |
| `auto_notification_settings` | 32 | 2 | sim | 0 |
| `availability_overrides` | 9 | 2 | sim | 0 |
| `billing_history` | 12 | 2 | sim | 0 |
| `booking_event_types` | 25 | 3 | sim | 0 |
| `booking_logs` | 8 | 1 | sim | 0 |
| `booking_notification_settings` | 21 | 4 | sim | 0 |
| `booking_reminders` | 12 | 4 | sim | 0 |
| `booking_requests` | 23 | 2 | sim | 0 |
| `booking_scheduled_jobs` | 14 | 1 | sim | 0 |
| `booking_status_history` | 8 | 1 | sim | 0 |
| `business_holidays` | 5 | 2 | sim | 0 |
| `business_hours` | 8 | 2 | sim | 0 |
| `cadence_api_keys` | 10 | 1 | sim | 0 |
| `cadence_enrollments` | 15 | 1 | sim | 0 |
| `cadence_step_runs` | 13 | 1 | sim | 0 |
| `cadence_steps` | 17 | 1 | sim | 0 |
| `cadence_templates` | 8 | 2 | sim | 0 |
| `cadences` | 18 | 1 | sim | 0 |
| `cakto_credentials` | 14 | 3 | sim | 0 |
| `cakto_orders` | 33 | 4 | sim | 0 |
| `cakto_recovery_config` | 11 | 2 | sim | 0 |
| `cakto_recovery_dispatches` | 15 | 2 | sim | 0 |
| `calendar_events` | 34 | 8 | sim | 0 |
| `call_events` | 9 | 1 | sim | 0 |
| `call_logs` | 33 | 4 | sim | 0 |
| `call_tool_events` | 9 | 2 | sim | 0 |
| `campaign_contexts` | 13 | 1 | sim | 0 |
| `campaign_preparation_jobs` | 16 | 2 | sim | 0 |
| `campaign_targets` | 17 | 1 | sim | 0 |
| `campaigns` | 28 | 1 | sim | 0 |
| `capture_funnels` | 34 | 5 | sim | 0 |
| `catalog_sync_logs` | 15 | 2 | sim | 0 |
| `chat_flows` | 14 | 2 | sim | 0 |
| `commission_rules` | 14 | 2 | sim | 0 |
| `commissions` | 16 | 3 | sim | 0 |
| `conversation_notes` | 7 | 2 | sim | 0 |
| `conversation_processing_locks` | 5 | 1 | sim | 0 |
| `conversation_transfers` | 8 | 2 | sim | 0 |
| `custom_fields` | 10 | 4 | sim | 0 |
| `deals` | 12 | 3 | sim | 0 |
| `distribution_config` | 9 | 2 | sim | 0 |
| `docs_change_proposals` | 13 | 1 | sim | 0 |
| `docs_pages` | 12 | 2 | sim | 0 |
| `docs_sections` | 6 | 2 | sim | 0 |
| `docs_tracks` | 11 | 2 | sim | 0 |
| `email_send_log` | 8 | 3 | sim | 0 |
| `email_send_state` | 7 | 1 | sim | 0 |
| `email_templates` | 11 | 2 | sim | 0 |
| `email_unsubscribe_tokens` | 5 | 3 | sim | 0 |
| `evolution_instances` | 20 | 4 | sim | 0 |
| `facebook_lead_integrations` | 19 | 4 | sim | 0 |
| `facebook_lead_logs` | 13 | 1 | sim | 0 |
| `form_blocks` | 17 | 5 | sim | 0 |
| `form_submissions` | 23 | 2 | sim | 0 |
| `form_templates` | 15 | 4 | sim | 0 |
| `forms` | 25 | 5 | sim | 0 |
| `funnel_analytics` | 8 | 2 | sim | 0 |
| `funnel_webhook_logs` | 16 | 2 | sim | 0 |
| `google_calendar_connections` | 17 | 1 | sim | 0 |
| `help_article_feedback` | 6 | 4 | sim | 0 |
| `help_articles` | 19 | 2 | sim | 0 |
| `help_categories` | 11 | 2 | sim | 0 |
| `hotmart_credentials` | 10 | 2 | sim | 0 |
| `hotmart_orders` | 25 | 3 | sim | 0 |
| `hotmart_product_mapping` | 7 | 3 | sim | 0 |
| `instagram_comment_replies` | 8 | 1 | sim | 0 |
| `instagram_connections` | 24 | 4 | sim | 0 |
| `instagram_flow_runs` | 13 | 1 | sim | 0 |
| `instagram_flows` | 15 | 2 | sim | 0 |
| `instagram_webhook_logs` | 13 | 1 | sim | 0 |
| `integration_settings` | 9 | 2 | sim | 0 |
| `interactions` | 10 | 2 | sim | 0 |
| `journey_events` | 29 | 2 | sim | 0 |
| `journey_touchpoints` | 11 | 2 | sim | 0 |
| `lead_notes` | 6 | 2 | sim | 0 |
| `lead_queue` | 10 | 3 | sim | 0 |
| `lead_semantic_memory` | 12 | 3 | sim | 0 |
| `lead_sessions` | 10 | 2 | sim | 0 |
| `lead_sources` | 14 | 2 | sim | 0 |
| `lead_stage_history` | 6 | 2 | sim | 0 |
| `lead_tag_assignments` | 5 | 2 | sim | 0 |
| `lead_tags` | 10 | 2 | sim | 0 |
| `lead_transfer_history` | 9 | 2 | sim | 0 |
| `leads` | 52 | 4 | sim | 0 |
| `marketing_adsets` | 15 | 1 | sim | 0 |
| `marketing_ads` | 17 | 1 | sim | 0 |
| `marketing_campaigns` | 16 | 1 | sim | 0 |
| `marketing_creatives` | 15 | 1 | sim | 0 |
| `marketing_insights_daily` | 21 | 1 | sim | 0 |
| `mass_email_campaigns` | 13 | 2 | sim | 0 |
| `mass_email_recipients` | 8 | 2 | sim | 0 |
| `materials` | 11 | 2 | sim | 0 |
| `message_reactions` | 8 | 3 | sim | 0 |
| `meta_oauth_sessions` | 12 | 1 | sim | 0 |
| `mia_actions` | 14 | 4 | sim | 0 |
| `mia_communications` | 16 | 2 | sim | 0 |
| `mia_daily_summaries` | 4 | 1 | sim | 0 |
| `mia_logs` | 8 | 2 | sim | 0 |
| `mia_user_memory` | 12 | 1 | sim | 0 |
| `notification_logs` | 7 | 2 | sim | 0 |
| `notifications` | 11 | 4 | sim | 0 |
| `objections` | 11 | 2 | sim | 0 |
| `onboarding_submissions` | 26 | 2 | sim | 1 |
| `opportunity_scan_items` | 16 | 2 | sim | 0 |
| `opportunity_scan_schedules` | 13 | 1 | sim | 0 |
| `opportunity_scans` | 20 | 4 | sim | 0 |
| `orchestration_logs` | 15 | 1 | sim | 0 |
| `org_ai_credentials` | 11 | 4 | sim | 0 |
| `org_ai_routing` | 8 | 4 | sim | 0 |
| `org_marketing_credentials` | 17 | 2 | sim | 0 |
| `organization_orchestrator_config` | 9 | 4 | sim | 0 |
| `organizations` | 45 | 3 | sim | 0 |
| `payment_links` | 16 | 4 | sim | 0 |
| `pipeline_stages` | 9 | 2 | sim | 0 |
| `platform_ai_keys` | 16 | 1 | sim | 0 |
| `platform_audit_logs` | 8 | 1 | sim | 0 |
| `platform_email_settings` | 15 | 1 | sim | 0 |
| `platform_email_templates` | 12 | 2 | sim | 0 |
| `platform_plans` | 50 | 4 | sim | 0 |
| `platform_release_reads` | 3 | 3 | sim | 0 |
| `platform_releases` | 13 | 2 | sim | 0 |
| `platform_settings` | 48 | 2 | sim | 0 |
| `post_sale_event_actions` | 28 | 2 | sim | 0 |
| `post_sale_event_logs` | 10 | 1 | sim | 0 |
| `post_sale_scheduled_runs` | 14 | 1 | sim | 0 |
| `processed_messages` | 5 | 1 | sim | 0 |
| `product_agent_connections` | 6 | 1 | sim | 0 |
| `product_agents` | 95 | 4 | sim | 0 |
| `product_catalog_items` | 22 | 4 | sim | 0 |
| `product_ctas` | 16 | 4 | sim | 0 |
| `product_knowledge_sources` | 28 | 4 | sim | 0 |
| `product_offers` | 14 | 4 | sim | 0 |
| `product_onboarding_state` | 11 | 4 | sim | 0 |
| `product_suites` | 11 | 4 | sim | 0 |
| `product_training_videos` | 13 | 2 | sim | 0 |
| `products` | 31 | 4 | sim | 0 |
| `profiles` | 21 | 7 | sim | 0 |
| `push_subscriptions` | 12 | 1 | sim | 0 |
| `quick_replies` | 10 | 4 | sim | 0 |
| `quiz_templates` | 24 | 4 | sim | 0 |
| `sales_goals` | 14 | 4 | sim | 0 |
| `sales_leads` | 17 | 2 | sim | 0 |
| `sales_squads` | 12 | 2 | sim | 0 |
| `sankhya_mappings` | 11 | 2 | sim | 0 |
| `sankhya_sync_logs` | 11 | 3 | sim | 0 |
| `scheduled_messages` | 17 | 1 | sim | 0 |
| `sector_members` | 4 | 3 | sim | 0 |
| `sectors` | 18 | 4 | sim | 0 |
| `seller_lead_form_config` | 5 | 2 | sim | 0 |
| `seller_notification_settings` | 11 | 1 | sim | 0 |
| `sent_responses` | 5 | 1 | sim | 0 |
| `squad_members` | 5 | 2 | sim | 0 |
| `stage_values` | 7 | 2 | sim | 0 |
| `subscriptions` | 16 | 2 | sim | 0 |
| `support_attachments` | 10 | 3 | sim | 0 |
| `support_messages` | 6 | 2 | sim | 0 |
| `support_tickets` | 14 | 4 | sim | 0 |
| `suppressed_emails` | 5 | 2 | sim | 0 |
| `tag_automations` | 10 | 2 | sim | 0 |
| `tasks` | 14 | 3 | sim | 0 |
| `team_invitations` | 10 | 5 | sim | 0 |
| `user_availability` | 8 | 3 | sim | 0 |
| `user_badges` | 7 | 2 | sim | 0 |
| `user_notification_settings` | 17 | 4 | sim | 0 |
| `user_org_switch_log` | 5 | 1 | sim | 0 |
| `user_organizations` | 7 | 9 | sim | 0 |
| `user_permissions` | 27 | 3 | sim | 0 |
| `user_product_assignments` | 6 | 4 | sim | 0 |
| `user_roles` | 4 | 8 | sim | 0 |
| `user_status` | 7 | 4 | sim | 0 |
| `voice_actions` | 13 | 1 | sim | 0 |
| `voice_agents` | 29 | 3 | sim | 0 |
| `voice_call_sessions` | 29 | 1 | sim | 0 |
| `voice_call_views` | 16 | 1 | sim | 0 |
| `voice_calls` | 24 | 2 | sim | 0 |
| `voice_campaign_journeys` | 12 | 2 | sim | 0 |
| `voice_campaign_targets` | 13 | 1 | sim | 0 |
| `voice_campaigns` | 33 | 2 | sim | 0 |
| `voice_clones` | 11 | 4 | sim | 0 |
| `voice_contexts` | 10 | 2 | sim | 0 |
| `voice_inbound_webhooks` | 17 | 2 | sim | 0 |
| `voice_pricing` | 11 | 2 | sim | 0 |
| `webchat_agent_configs` | 29 | 2 | sim | 0 |
| `webchat_assignment_events` | 6 | 2 | sim | 0 |
| `webchat_conversations` | 72 | 3 | sim | 0 |
| `webchat_messages` | 21 | 2 | sim | 0 |
| `webchat_widgets` | 19 | 2 | sim | 0 |
| `webhook_logs` | 13 | 2 | sim | 0 |
| `webhook_sample_requests` | 7 | 2 | sim | 0 |
| `webhooks` | 19 | 4 | sim | 0 |
| `whatsapp_meta_connections` | 25 | 4 | sim | 0 |
| `whatsapp_meta_templates` | 23 | 2 | sim | 0 |
| `whatsapp_meta_webhook_logs` | 8 | 1 | sim | 0 |
---

## 6. Buckets de arquivos (Storage)

Os arquivos **não** são copiados pelo DDL — precisam ser exportados e reenviados separadamente.

| Bucket | Público | Limite de tamanho |
|---|---|---|
| `avatars` | sim | padrão |
| `cadence-media` | sim | padrão |
| `catalog-media` | sim | padrão |
| `chat-media` | sim | padrão |
| `company-logos` | sim | padrão |
| `form-media` | não | padrão |
| `funnel-assets` | sim | padrão |
| `help-media` | sim | padrão |
| `materials` | sim | padrão |
| `onboarding-uploads` | não | padrão |
| `platform-assets` | sim | padrão |
| `product-documents` | sim | 52428800 |
| `squad-icons` | sim | 1048576 |
| `support-attachments` | não | padrão |
| `voice-samples` | não | padrão |
| `whatsapp-media` | não | padrão |
| `whatsapp-meta-media` | não | padrão |

---

## 7. Ordem recomendada para importar os dados

O grafo de dependências tem ciclos (ex.: `organizations` ↔ `profiles`), então o
caminho seguro é:

1. Aplicar `DATABASE_SNAPSHOT.sql` no banco vazio (estrutura completa).
2. Importar `auth.users` primeiro (usuários), pois quase tudo referencia usuários.
3. Desativar temporariamente as validações de vínculo durante a carga:
   `SET session_replication_role = replica;` — isso desliga triggers e checagens de FK.
4. Importar as tabelas na ordem abaixo (nível 0 primeiro).
5. Reativar: `SET session_replication_role = origin;`
6. Validar contagens por tabela contra a coluna "Registros" da seção 5.
7. Reajustar sequences/identidades, se houver.

### Nível 0
`agent_handoff_history`, `agent_safety_limits`, `agent_specialists`, `agent_tool_executions`, `ai_prompt_experiments`, `ai_quality_evaluations`, `ai_router_failures`, `cadence_api_keys`, `cadences`, `campaign_contexts`, `conversation_processing_locks`, `docs_tracks`, `email_send_log`, `email_send_state`, `email_unsubscribe_tokens`, `help_categories`, `instagram_connections`, `meta_oauth_sessions`, `mia_actions`, `mia_daily_summaries`, `mia_logs`, `mia_user_memory`, `opportunity_scan_schedules`, `opportunity_scans`, `org_ai_credentials`, `org_ai_routing`, `platform_ai_keys`, `platform_email_settings`, `platform_email_templates`, `platform_plans`, `platform_releases`, `platform_settings`, `processed_messages`, `product_suites`, `push_subscriptions`, `sales_leads`, `sectors`, `seller_lead_form_config`, `sent_responses`, `suppressed_emails`, `user_badges`, `user_notification_settings`, `user_org_switch_log`, `user_roles`, `voice_pricing`

### Nível 1
`agent_routing_rules`, `ai_prompt_variants`, `campaigns`, `docs_sections`, `help_articles`, `instagram_webhook_logs`, `mia_communications`, `opportunity_scan_items`, `platform_release_reads`

### Nível 2
`campaign_targets`, `docs_pages`, `help_article_feedback`

### Nível 3
`docs_change_proposals`

### Ciclos (importar com FKs adiadas)
`admin_agent_messages`, `admin_notifications`, `agent_action_logs`, `agent_activation_logs`, `agent_post_sale_scenarios`, `agent_training_materials`, `ai_audits`, `ai_insights`, `ai_knowledge_base`, `ai_outreach_queue`, `ai_response_feedback`, `ai_usage_logs`, `auto_notification_settings`, `availability_overrides`, `billing_history`, `booking_event_types`, `booking_logs`, `booking_notification_settings`, `booking_reminders`, `booking_requests`, `booking_scheduled_jobs`, `booking_status_history`, `business_holidays`, `business_hours`, `cadence_enrollments`, `cadence_step_runs`, `cadence_steps`, `cadence_templates`, `cakto_credentials`, `cakto_orders`, `cakto_recovery_config`, `cakto_recovery_dispatches`, `calendar_events`, `call_events`, `call_logs`, `call_tool_events`, `campaign_preparation_jobs`, `capture_funnels`, `catalog_sync_logs`, `chat_flows`, `commission_rules`, `commissions`, `conversation_notes`, `conversation_transfers`, `custom_fields`, `deals`, `distribution_config`, `email_templates`, `evolution_instances`, `facebook_lead_integrations`, `facebook_lead_logs`, `form_blocks`, `form_submissions`, `form_templates`, `forms`, `funnel_analytics`, `funnel_webhook_logs`, `google_calendar_connections`, `hotmart_credentials`, `hotmart_orders`, `hotmart_product_mapping`, `instagram_comment_replies`, `instagram_flow_runs`, `instagram_flows`, `integration_settings`, `interactions`, `journey_events`, `journey_touchpoints`, `lead_notes`, `lead_queue`, `lead_semantic_memory`, `lead_sessions`, `lead_sources`, `lead_stage_history`, `lead_tag_assignments`, `lead_tags`, `lead_transfer_history`, `leads`, `marketing_ads`, `marketing_adsets`, `marketing_campaigns`, `marketing_creatives`, `marketing_insights_daily`, `mass_email_campaigns`, `mass_email_recipients`, `materials`, `message_reactions`, `notification_logs`, `notifications`, `objections`, `onboarding_submissions`, `orchestration_logs`, `org_marketing_credentials`, `organization_orchestrator_config`, `organizations`, `payment_links`, `pipeline_stages`, `platform_audit_logs`, `post_sale_event_actions`, `post_sale_event_logs`, `post_sale_scheduled_runs`, `product_agent_connections`, `product_agents`, `product_catalog_items`, `product_ctas`, `product_knowledge_sources`, `product_offers`, `product_onboarding_state`, `product_training_videos`, `products`, `profiles`, `quick_replies`, `quiz_templates`, `sales_goals`, `sales_squads`, `sankhya_mappings`, `sankhya_sync_logs`, `scheduled_messages`, `sector_members`, `seller_notification_settings`, `squad_members`, `stage_values`, `subscriptions`, `support_attachments`, `support_messages`, `support_tickets`, `tag_automations`, `tasks`, `team_invitations`, `user_availability`, `user_organizations`, `user_permissions`, `user_product_assignments`, `user_status`, `voice_actions`, `voice_agents`, `voice_call_sessions`, `voice_call_views`, `voice_calls`, `voice_campaign_journeys`, `voice_campaign_targets`, `voice_campaigns`, `voice_clones`, `voice_contexts`, `voice_inbound_webhooks`, `webchat_agent_configs`, `webchat_assignment_events`, `webchat_conversations`, `webchat_messages`, `webchat_widgets`, `webhook_logs`, `webhook_sample_requests`, `webhooks`, `whatsapp_meta_connections`, `whatsapp_meta_templates`, `whatsapp_meta_webhook_logs`
---

## 8. Funções de servidor (Edge Functions)

O projeto tem **175 funções de servidor** em `supabase/functions/`. Elas fazem parte do
código e viajam junto no repositório Git — mas precisam ser **implantadas** no destino.

Funções premium da stack Mia (`mia-tools`, `mia-realtime-session`, `mia-prepare-action`,
`mia-execute-action`) vivem em repositório separado e compartilham o mesmo banco;
as tabelas `mia_*` nunca devem ser removidas.

### Credenciais exigidas pelas integrações

Estes nomes são lidos pelas funções em tempo de execução e precisam ser recadastrados no destino:

| Credencial | Usada para |
|---|---|
| `OPENAI_API_KEY` | IA (texto, voz em tempo real, transcrição) |
| `XAI_API_KEY` | Voz Grok / xAI |
| `ELEVENLABS_API_KEY` | Voz e clonagem de voz |
| `LOVABLE_API_KEY` | Gateway de IA da plataforma |
| `RESEND_API_KEY` | Envio de e-mails |
| `FIRECRAWL_API_KEY` | Captura de conteúdo de sites |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` | Notificações push |
| `BOTCONVERSA_API_KEY` | WhatsApp BotConversa |
| `ISICHAT_TOKEN` | Integração IsiChat |
| `SITE_URL`, `LOVABLE_SEND_URL` | URLs base para links e envios |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | Acesso interno ao backend (gerados pelo próprio ambiente) |
| `CIRCUIT_BREAKER_ENABLED`, `USE_BATCH_SENDER` | Chaves de comportamento (opcionais) |

Credenciais por empresa (WhatsApp Meta, Instagram, Evolution, Google Calendar, Cakto,
Hotmart, Doppus, Sankhya, Meta Ads) ficam **no banco**, em tabelas próprias
(`whatsapp_meta_connections`, `instagram_connections`, `evolution_instances`,
`google_calendar_connections`, `cakto_credentials`, `hotmart_credentials`,
`org_ai_credentials`, `org_marketing_credentials`, `integration_settings`) — parte
delas criptografada com a chave-mestre guardada em `platform_settings`.
**Migre `platform_settings` junto**, senão os valores criptografados ficam ilegíveis.

---

## 9. Contas de Super Admin

Papéis em `public.user_roles` (nunca em `profiles`). Ambas as contas abaixo têm
`super_admin` + `admin` e estão com e-mail confirmado.

| E-mail | Nome | Papéis | Observação |
|---|---|---|---|
| admzapyer@gmail.com | Marcilio Barros | super_admin, admin | Conta original |
| marciliobarrosdev@gmail.com | Marcílio Barros | super_admin, admin | Criada em 2026-09-15 (id `a1edfe7a-a78c-4389-8ba3-c33fc18d3e15`) |

As senhas ficam criptografadas em `auth.users` e não são recuperáveis em texto —
não devem ser anotadas aqui. Em uma migração, importe `auth.users` (que já leva os
hashes) ou refaça o acesso por "Esqueci minha senha". Depois confirme que as linhas
correspondentes existem em `profiles` e `user_roles`.

---

## 10. Roteiro de migração (checklist)

1. **Código** — repositório Git sincronizado (este projeto).
2. **Estrutura** — aplicar `docs/DATABASE_SNAPSHOT.sql` no banco destino.
3. **Usuários** — exportar/importar `auth.users` e depois `profiles`, `user_roles`, `user_organizations`, `user_permissions`.
4. **Dados** — importar as demais tabelas conforme a seção 7.
5. **Arquivos** — copiar os 17 buckets da seção 6 preservando os caminhos.
6. **Segredos** — recadastrar as credenciais da seção 8.
7. **Funções de servidor** — implantar as 175 funções.
8. **Tarefas agendadas** — recriar os agendamentos `pg_cron` (cadências, follow-up de IA, campanhas de voz, fila de e-mails, pós-venda, varredura de oportunidades).
9. **Webhooks externos** — atualizar as URLs no Meta/WhatsApp, Instagram, Facebook Lead Ads, Cakto, Hotmart, Doppus, Evolution e Google Calendar para o novo domínio.
10. **Validação** — conferir contagens por tabela, login de um usuário real, envio de uma mensagem e um agendamento de ponta a ponta.

---

## 10. Como regenerar este snapshot

```bash
pg_dump "$SUPABASE_DB_URL" --schema-only --no-owner --schema=public -f docs/DATABASE_SNAPSHOT.sql
```

As contagens deste documento saem de consultas a `pg_catalog`, `information_schema`,
`pg_policies`, `pg_stat_user_tables` e `storage.buckets`.
