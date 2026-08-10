/* ============================================================================
   00 · INFRASTRUCTURE
   ----------------------------------------------------------------------------
   Creates the role, compute, database and medallion schemas used by the whole
   pipeline. Idempotent: safe to re-run, including against an environment where
   the objects already exist.

   Layers
     BRONZE  raw bytes exactly as received, plus lineage. No transformation.
     SILVER  parsed, typed, deduplicated, validated. Quarantine lives here.
     GOLD    canonical multi-client model. No source-specific logic.
   ========================================================================= */

/* ---------------------------------------------------------------------------
   Role
   ----------------------------------------------------------------------------
   ACCOUNTADMIN is used only to create the role and the warehouse, then dropped.
   Snowflake explicitly advises against creating objects with ACCOUNTADMIN: it
   makes that role the owner of everything, so any other role — including
   SYSADMIN — gets "does not exist or not authorized" on objects that plainly
   do exist, and cannot grant itself access. Ownership by a purpose-built role
   is what makes the pipeline transferable to another engineer.

   The role is granted to SYSADMIN so it sits under the standard hierarchy
   rather than dangling, and to the current user so this script can continue.
   ------------------------------------------------------------------------ */
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS ingestion_engineer
    COMMENT = 'Owns the financial ingestion pipeline: database, schemas, objects';

GRANT ROLE ingestion_engineer TO ROLE SYSADMIN;

-- Granted to whoever runs this, so the script is portable between accounts.
EXECUTE IMMEDIATE $$
BEGIN
    EXECUTE IMMEDIATE 'GRANT ROLE ingestion_engineer TO USER "' || CURRENT_USER() || '"';
    RETURN 'role granted to ' || CURRENT_USER();
END;
$$;

/* ---------------------------------------------------------------------------
   Compute
   Dedicated XS warehouse rather than the trial default, with an aggressive
   auto-suspend: this workload is bursty and interactive, so idle time is pure
   waste. AUTO_RESUME keeps it transparent to the caller.
   ------------------------------------------------------------------------ */
CREATE WAREHOUSE IF NOT EXISTS wh_ingestion
    WAREHOUSE_SIZE      = 'XSMALL'
    AUTO_SUSPEND        = 60      -- seconds
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT             = 'Compute for the financial data ingestion pipeline';

GRANT USAGE, OPERATE ON WAREHOUSE wh_ingestion TO ROLE ingestion_engineer;

/* ---------------------------------------------------------------------------
   Database, then ownership transfer
   ----------------------------------------------------------------------------
   The database is created by ACCOUNTADMIN and handed over immediately, rather
   than created by the role directly. This is what makes the script correct
   against an environment that already exists: CREATE ... IF NOT EXISTS is a
   no-op on an existing object, so it would silently leave the original owner
   in place while the script claims otherwise. Transferring afterwards covers
   both a fresh account and a pre-existing one, and is harmless when ownership
   already matches.

   Ownership must move before the role creates anything inside the database —
   otherwise CREATE SCHEMA fails with "primary role must have CREATE SCHEMA
   granted on DATABASE", which is finding #4 stated by Snowflake itself.
   ------------------------------------------------------------------------ */
CREATE DATABASE IF NOT EXISTS financial_ingestion
    COMMENT = 'Multi-client financial transaction ingestion and canonical model';

GRANT OWNERSHIP ON DATABASE financial_ingestion
    TO ROLE ingestion_engineer COPY CURRENT GRANTS;

GRANT OWNERSHIP ON ALL SCHEMAS IN DATABASE financial_ingestion
    TO ROLE ingestion_engineer COPY CURRENT GRANTS;

GRANT OWNERSHIP ON ALL TABLES IN DATABASE financial_ingestion
    TO ROLE ingestion_engineer COPY CURRENT GRANTS;

GRANT OWNERSHIP ON ALL FILE FORMATS IN DATABASE financial_ingestion
    TO ROLE ingestion_engineer COPY CURRENT GRANTS;

GRANT OWNERSHIP ON ALL STAGES IN DATABASE financial_ingestion
    TO ROLE ingestion_engineer COPY CURRENT GRANTS;

-- Views matter here specifically: 05_validate_bronze.sql creates
-- v_bronze_validation, and a view left owned by another role would make
-- CREATE OR REPLACE VIEW fail — disabling the very check that exists to catch
-- a silent load failure.
GRANT OWNERSHIP ON ALL VIEWS IN DATABASE financial_ingestion
    TO ROLE ingestion_engineer COPY CURRENT GRANTS;

/* ---------------------------------------------------------------------------
   Medallion schemas — created as the owning role
   ------------------------------------------------------------------------ */
USE ROLE ingestion_engineer;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;

CREATE SCHEMA IF NOT EXISTS bronze
    COMMENT = 'Raw landing. Bytes as received plus file lineage. Replayable.';

CREATE SCHEMA IF NOT EXISTS silver
    COMMENT = 'Parsed, typed, deduplicated and validated. Holds DQ quarantine.';

CREATE SCHEMA IF NOT EXISTS gold
    COMMENT = 'Canonical model conformed across all client sources.';

SHOW SCHEMAS IN DATABASE financial_ingestion;
