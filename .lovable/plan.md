# Novo Super Admin: marciliobarrosdev@gmail.com

## Objetivo
Dar acesso de Super Admin ao e-mail **marciliobarrosdev@gmail.com**, com a senha que você vai informar.

## O que será feito
1. Verificar se esse e-mail já tem conta na plataforma.
2. Se **não tiver**: criar a conta com nome, e-mail e a senha informada, já confirmada (entra direto, sem precisar clicar em link no e-mail).
3. Se **já tiver**: manter a conta e apenas redefinir a senha para a que você informar.
4. Dar os papéis de **Super Admin** e **Admin** para essa conta (mesma combinação do Super Admin já existente).
5. Garantir o registro de perfil da pessoa (nome e e-mail) para não quebrar telas que dependem dele.
6. Conferir no final que o acesso aparece na lista de usuários e que os dois Super Admins continuam ativos.

## O que preciso de você
- **A senha** que deseja usar (mínimo 8 caracteres; se for uma senha comum ou já vazada publicamente, o sistema recusa e peço outra).
- **O nome completo** para exibir no perfil (se não informar, uso "Marcilio Barros").

Observação: o banco está em manutenção programada até por volta das 18h45 (horário de Brasília); se ainda estiver indisponível na hora de executar, eu repito a operação logo em seguida.

## Detalhes técnicos
- Operação feita via Admin API de autenticação (criação/atualização de usuário com `email_confirm: true`), seguindo o mesmo padrão de `setup-super-admin`.
- Papéis gravados em `public.user_roles` (`super_admin` + `admin`), nunca no perfil.
- `public.profiles` recebe upsert com `id`, `full_name`, `email`, `is_active`.
- Nenhuma alteração de estrutura do banco e nenhum arquivo de código do app é modificado.
