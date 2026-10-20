-- ==============================================================================
-- e-SUS APS PEC - Script de Provisionamento do Usuário Read-Only (LGPD)
-- ==============================================================================
-- Finalidade: Cria uma conta de acesso estritamente somente leitura para
-- auditorias, BI (PowerBI/Metabase), relatórios e integrações, impedindo
-- qualquer alteração acidental no banco de produção.
-- ==============================================================================

DO $$
BEGIN
    -- 1. Criação do papel caso não exista
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'esus_leitura') THEN
        CREATE ROLE esus_leitura WITH LOGIN PASSWORD 'esus_leitura_segura_2026';
    END IF;
END
$$;

-- 2. Atribuição de regras estritas de segurança da sessão
ALTER ROLE esus_leitura SET default_transaction_read_only = on;
ALTER ROLE esus_leitura SET statement_timeout = '30s';
ALTER ROLE esus_leitura SET idle_in_transaction_session_timeout = '60s';

-- 3. Permissões de conexão e leitura
GRANT CONNECT ON DATABASE esus TO esus_leitura;
GRANT USAGE ON SCHEMA public TO esus_leitura;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO esus_leitura;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO esus_leitura;

-- 4. Garantir leitura em tabelas criadas no futuro (migrações do PEC)
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO esus_leitura;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO esus_leitura;
