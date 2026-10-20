-- ==============================================================================
-- e-SUS APS PEC - Usuário somente leitura para BI, auditoria e integrações
-- ==============================================================================
-- Idempotente: cria ou atualiza o papel e reaplica as permissões. Rodar depois
-- de cada migração ou restauração (os scripts do projeto já fazem isso).
--
-- A senha NÃO fica neste arquivo: vem da variável ESUS_LEITURA_PASSWORD do .env,
-- lida com \getenv (psql 15+), sem passar pela linha de comando.
--
-- Uso: ESUS_LEITURA_PASSWORD=... psql -v ON_ERROR_STOP=1 -d esus -f esus-leitura.sql
-- ==============================================================================
\set ON_ERROR_STOP on
\set QUIET on

-- O ALTER ROLE abaixo leva a senha em texto: não deixar ir para o log do servidor.
SET log_statement = 'none';
SET log_min_error_statement = 'panic';
SET log_min_duration_statement = -1;

\getenv leitura_user ESUS_LEITURA_USER
\getenv leitura_pwd ESUS_LEITURA_PASSWORD

\if :{?leitura_user}
\else
  \set leitura_user esus_leitura
\endif

\if :{?leitura_pwd}
\else
  \echo 'ERRO: ESUS_LEITURA_PASSWORD não definida (rode scripts/gerar-env.sh).'
  SELECT 'ESUS_LEITURA_PASSWORD ausente'::int;
\endif

SELECT (:'leitura_pwd' = '' OR :'leitura_pwd' LIKE 'altere\_%') AS senha_exemplo,
       length(:'leitura_pwd') < 16 AS senha_curta \gset
\if :senha_exemplo
  \echo 'ERRO: ESUS_LEITURA_PASSWORD vazia ou com o valor de exemplo publicado no repositório.'
  SELECT 'ESUS_LEITURA_PASSWORD de exemplo'::int;
\endif
\if :senha_curta
  \echo 'AVISO: ESUS_LEITURA_PASSWORD com menos de 16 caracteres. Recomendado: ./scripts/trocar-senhas.sh --leitura'
\endif

-- O usuário de leitura não pode ser um papel administrativo: o ALTER ROLE
-- abaixo tiraria dele os privilégios.
SELECT (r.rolsuper OR r.rolname = current_user) AS papel_admin
  FROM (SELECT :'leitura_user'::name AS n) x
  LEFT JOIN pg_roles r ON r.rolname = x.n \gset
\if :{?papel_admin}
\if :papel_admin
  \echo 'ERRO: ESUS_LEITURA_USER aponta para um papel administrativo.'
  SELECT 'ESUS_LEITURA_USER inválido'::int;
\endif
\endif

-- 1. Papel: login, sem privilégios, no máximo 5 conexões simultâneas
SELECT format('CREATE ROLE %I LOGIN', :'leitura_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'leitura_user') \gexec

SELECT format(
  'ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5 PASSWORD %L',
  :'leitura_user', :'leitura_pwd') \gexec

-- 2. Padrões da sessão. São defesa extra: o próprio usuário consegue alterá-los
--    com SET. A garantia real de "só leitura" é ter apenas SELECT (item 3).
SELECT format('ALTER ROLE %I SET default_transaction_read_only = on', :'leitura_user') \gexec
SELECT format('ALTER ROLE %I SET statement_timeout = %L', :'leitura_user', '30s') \gexec
SELECT format('ALTER ROLE %I SET idle_in_transaction_session_timeout = %L', :'leitura_user', '60s') \gexec

-- 3. Permissões: conectar e ler. Nada de escrita.
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'leitura_user') \gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'leitura_user') \gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', :'leitura_user') \gexec
SELECT format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO %I', :'leitura_user') \gexec

-- Tabelas criadas no futuro pelo dono do banco (migrações do PEC).
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT SELECT ON TABLES TO %I',
              current_user, :'leitura_user') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT SELECT ON SEQUENCES TO %I',
              current_user, :'leitura_user') \gexec

-- Bancos restaurados de versões antigas (PostgreSQL 9.6) ainda dão CREATE em
-- public para todos. Sem isso, o usuário de leitura poderia criar tabelas.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

\set QUIET off
SELECT format('esus_leitura OK: papel %s, %s tabelas legíveis, limite de %s conexões',
              r.rolname,
              (SELECT count(*) FROM pg_tables t
                WHERE t.schemaname = 'public'
                  AND has_table_privilege(r.rolname, format('%I.%I', t.schemaname, t.tablename), 'SELECT')),
              r.rolconnlimit) AS resultado
  FROM pg_roles r WHERE r.rolname = :'leitura_user';
