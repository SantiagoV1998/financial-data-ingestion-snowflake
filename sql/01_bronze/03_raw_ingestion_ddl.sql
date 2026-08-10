/* ============================================================================
   01 · BRONZE — RAW INGESTION DDL
   ----------------------------------------------------------------------------
   Bronze mirrors the source. One table per source file, every column VARCHAR,
   nothing cast, nothing filtered, nothing deduplicated.

   Why every column is VARCHAR: a malformed date or a negative amount is a
   finding to report, not a reason for a load to fail. Typing happens in silver
   with TRY_* functions, where a bad value becomes a quarantined row instead of
   an aborted batch.

   Why bronze is source-shaped rather than generic: it must be replayable.
   If silver logic changes we rebuild from bronze without re-reading the source
   files. That property is lost the moment bronze reshapes or drops anything.
   Conforming across clients is silver's and gold's job.

   Every table carries the same three lineage columns:
     source_file      METADATA$FILENAME       — which file the row came from
     file_row_number  METADATA$FILE_ROW_NUMBER — position within that file
     loaded_at        load timestamp
   ========================================================================= */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA bronze;

/* ---------------------------------------------------------------------------
   Raw text lines — the XML fragments and the JSON document
   ----------------------------------------------------------------------------
   One row per physical line of every non-CSV file. This is what makes the
   unparseable files tractable: line_text holds the bytes verbatim, and
   (source_file, file_row_number) preserves the ordering needed to stitch the
   seven ClientA fragments back into a single document.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE raw_text_lines (
    source_file     VARCHAR       NOT NULL,
    file_row_number NUMBER        NOT NULL,
    line_text       VARCHAR,
    loaded_at       TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Verbatim lines from files no native parser accepts (XML fragments, commented JSON).';

/* ---------------------------------------------------------------------------
   Client A master data
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE raw_client_a_customers (
    customer_id     VARCHAR, first_name VARCHAR, last_name    VARCHAR,
    email           VARCHAR, loyalty_tier VARCHAR, signup_source VARCHAR,
    is_active       VARCHAR,
    source_file     VARCHAR NOT NULL,
    file_row_number NUMBER  NOT NULL,
    loaded_at       TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE raw_client_a_orders (
    order_id        VARCHAR, customer_id VARCHAR, order_date VARCHAR,
    order_status    VARCHAR, channel     VARCHAR,
    source_file     VARCHAR NOT NULL,
    file_row_number NUMBER  NOT NULL,
    loaded_at       TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE raw_client_a_products (
    sku             VARCHAR, product_name VARCHAR, category VARCHAR,
    unit_price      VARCHAR, currency     VARCHAR, is_active VARCHAR,
    source_file     VARCHAR NOT NULL,
    file_row_number NUMBER  NOT NULL,
    loaded_at       TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

/* ---------------------------------------------------------------------------
   Client B master data
   ----------------------------------------------------------------------------
   FINDING: the folder is named "Client B" but every file inside identifies
   itself as clientC_* and all identifiers are prefixed C- (C-CUST, C-ORD,
   C-TXN). Bronze preserves the discrepancy rather than resolving it — the
   folder gives the table its name, the content keeps its own identifiers.
   See docs/anomalies.md.

   Note the schema divergence from Client A, which is the real modeling problem:
     · one customer_name field instead of first_name + last_name
     · segment (VIP/REGULAR) instead of loyalty_tier (GOLD/SILVER)
     · orders carry no channel
     · payments arrive as their own file, with payment_id and status, whereas
       Client A embeds payment inside each transaction with neither
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE raw_client_b_customers (
    customer_id     VARCHAR, customer_name VARCHAR, email VARCHAR,
    segment         VARCHAR, is_active     VARCHAR,
    source_file     VARCHAR NOT NULL,
    file_row_number NUMBER  NOT NULL,
    loaded_at       TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE raw_client_b_orders (
    order_id        VARCHAR, customer_id VARCHAR, order_date VARCHAR,
    order_status    VARCHAR,
    source_file     VARCHAR NOT NULL,
    file_row_number NUMBER  NOT NULL,
    loaded_at       TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE raw_client_b_products (
    sku             VARCHAR, product_name VARCHAR, category VARCHAR,
    unit_price      VARCHAR, currency     VARCHAR, is_active VARCHAR,
    source_file     VARCHAR NOT NULL,
    file_row_number NUMBER  NOT NULL,
    loaded_at       TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE raw_client_b_payments (
    payment_id      VARCHAR, order_id VARCHAR, payment_method VARCHAR,
    amount          VARCHAR, currency VARCHAR, status         VARCHAR,
    source_file     VARCHAR NOT NULL,
    file_row_number NUMBER  NOT NULL,
    loaded_at       TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

SHOW TABLES IN SCHEMA bronze;
