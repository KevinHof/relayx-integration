-- ADR-001: role and schemas for the Relay X raw and ops layers.
-- Run ONCE as postgres (Kevin). Contains no password: set it afterwards with
--   \password relayx_app
-- Safe to re-run: existing role and schemas are kept, grants are re-applied.

\set ON_ERROR_STOP on

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'relayx_app') THEN
        CREATE ROLE relayx_app LOGIN;
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS relayx_raw AUTHORIZATION relayx_app;
CREATE SCHEMA IF NOT EXISTS relayx_ops AUTHORIZATION relayx_app;

-- Read-only access to the Covalo source tables and the exploration schema.
GRANT USAGE ON SCHEMA covalo, kevin TO relayx_app;
GRANT SELECT ON ALL TABLES IN SCHEMA covalo, kevin TO relayx_app;
-- Tables added to covalo or kevin later need a new grant (or default privileges set by their owner).

-- Check: role, schema owners and a sample of grants.
SELECT rolname, rolcanlogin, rolsuper, rolcreatedb, rolcreaterole
FROM pg_roles WHERE rolname = 'relayx_app';
SELECT nspname, pg_get_userbyid(nspowner) AS owner
FROM pg_namespace WHERE nspname IN ('relayx_raw', 'relayx_ops') ORDER BY 1;
SELECT has_table_privilege('relayx_app', 'covalo.product', 'SELECT') AS covalo_select,
       has_table_privilege('relayx_app', 'covalo.product', 'INSERT') AS covalo_insert,
       has_schema_privilege('relayx_app', 'covalo', 'CREATE')       AS covalo_create;
