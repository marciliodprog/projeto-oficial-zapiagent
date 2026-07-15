# Stack Mia — Premium

As Edge Functions `mia-tools`, `mia-realtime-session`, `mia-prepare-action` e `mia-execute-action` fazem parte da versão **premium** do produto e são mantidas em um repositório separado (`vendus-mia`) que compartilha o mesmo banco Supabase.

**Não recriar essas funções neste repositório público.**

Elas permanecem deployadas no servidor Supabase (não deletar do ambiente) porque são usadas pelo projeto premium. As tabelas correlatas (`mia_actions`, `mia_communications`, `mia_logs`, `mia_daily_summaries`, `mia_user_memory`) também devem permanecer intactas — nunca gerar migration com `DROP TABLE` para elas.
