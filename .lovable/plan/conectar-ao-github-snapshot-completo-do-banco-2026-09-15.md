# Conectar ao GitHub + snapshot completo do banco

## 1. Conexão com o GitHub (ação sua, no painel)

O envio do código para `github.com/marciliodprog/projeto-oficial-zapiagent` é feito
pela própria integração do Lovable — eu não consigo autorizar a conta nem empurrar
commits por conta própria.

Passos:
1. No menu "+" (canto inferior esquerdo do chat) escolha **GitHub → Connect project**.
2. Autorize o app do Lovable na conta `marciliodprog`.
3. Escolha a conta/organização e conecte ao repositório `projeto-oficial-zapiagent`.

Observação: hoje o Lovable cria um repositório novo na conexão. Se o repositório
informado já tiver conteúdo, pode ser necessário usá-lo vazio ou deixar o Lovable
criar o repo e depois ajustar o remoto no GitHub.

A partir daí a sincronização é automática nos dois sentidos: tudo que eu alterar
aqui vira commit lá, e o que for enviado lá aparece aqui. Nenhum commit manual
é necessário depois disso.

## 2. Arquivo com a estrutura completa do banco

Vou gerar um documento único e atualizado, lido diretamente do banco real (não de
arquivos antigos), para servir de referência numa futura migração sem perda de
dados.

Local: `docs/DATABASE_SNAPSHOT.md` (mais um índice de apoio em
`docs/DATABASE_SNAPSHOT.sql` com o DDL puro, pronto para recriar tudo).

Conteúdo:
- Inventário geral (tabelas, colunas, chaves, índices, funções, triggers, views, políticas, enums, extensões) com contagens conferidas.
- Lista de todas as tabelas com suas colunas, tipos, obrigatoriedade e valores padrão.
- Relacionamentos entre tabelas (chaves estrangeiras) e ordem de importação recomendada para migrar dados sem quebrar vínculos.
- Regras de acesso (RLS) e permissões por tabela.
- Funções, gatilhos e views do banco.
- Buckets de arquivos e o que guardam.
- Lista das funções de servidor (edge functions) e os segredos/credenciais que cada integração exige — para reconectar tudo no destino.
- Roteiro de migração: ordem dos passos, o que exportar, o que reconfigurar manualmente (chaves de API, webhooks, calendários, WhatsApp).

## Detalhes técnicos

- O snapshot será extraído via consultas a `pg_catalog`/`information_schema`
  (`pg_tables`, `pg_attribute`, `pg_constraint`, `pg_indexes`, `pg_proc`,
  `pg_trigger`, `pg_policies`, `pg_enum`, `pg_extension`, `storage.buckets`),
  garantindo fidelidade ao estado atual.
- Os baselines existentes em `supabase/migrations_shared/` e o `docs/DATABASE.md`
  (de 2026-05-04) serão referenciados e o novo documento apontará divergências
  encontradas em relação a eles.
- Nenhuma alteração de schema será feita: a operação é somente leitura + escrita
  de arquivos de documentação.
