/* ============================================================================
   00 · INFRASTRUCTURE
   ----------------------------------------------------------------------------
   Creates the compute, database and medallion schemas used by the whole
   pipeline. Idempotent: safe to re-run from scratch.

   Layers
     BRONZE  raw bytes exactly as received, plus lineage. No transformation.
     SILVER  parsed, typed, deduplicated, validated. Quarantine lives here.
     GOLD    canonical multi-client model. No source-specific logic.
   ========================================================================= */

USE ROLE ACCOUNTADMIN;

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

/* ---------------------------------------------------------------------------
   Database and medallion schemas
   ------------------------------------------------------------------------ */
CREATE DATABASE IF NOT EXISTS financial_ingestion
    COMMENT = 'Multi-client financial transaction ingestion and canonical model';

USE DATABASE financial_ingestion;

CREATE SCHEMA IF NOT EXISTS bronze
    COMMENT = 'Raw landing. Bytes as received plus file lineage. Replayable.';

CREATE SCHEMA IF NOT EXISTS silver
    COMMENT = 'Parsed, typed, deduplicated and validated. Holds DQ quarantine.';

CREATE SCHEMA IF NOT EXISTS gold
    COMMENT = 'Canonical model conformed across all client sources.';

USE WAREHOUSE wh_ingestion;

SHOW SCHEMAS IN DATABASE financial_ingestion;
