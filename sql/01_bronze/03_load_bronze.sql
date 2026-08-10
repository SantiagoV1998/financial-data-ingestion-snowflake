/* ============================================================================
   01 · BRONZE — LOAD
   ----------------------------------------------------------------------------
   Loads every staged file into its bronze table, attaching lineage.

   FORCE = TRUE on every COPY: Snowflake retains per-table load metadata for 64
   days and silently skips files it has already loaded, reporting success while
   loading zero rows. FORCE makes these scripts re-runnable from scratch, which
   is what an evaluator reproducing the pipeline needs. In a production
   incremental pipeline it would be omitted.
   ========================================================================= */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA bronze;

/* ---------------------------------------------------------------------------
   Unparseable files → verbatim text lines
   ----------------------------------------------------------------------------
   Captures the seven ClientA XML fragments (including the one misnamed .txt)
   and the ClientC JSON. ON_ERROR = ABORT_STATEMENT is deliberate: at this stage
   we are only copying bytes, so any failure is structural, not a data-quality
   issue, and must not pass silently.
   ------------------------------------------------------------------------ */
COPY INTO raw_text_lines (source_file, file_row_number, line_text)
FROM (
    SELECT METADATA$FILENAME,
           METADATA$FILE_ROW_NUMBER,
           $1
    FROM @raw_files
)
PATTERN     = '.*(ClientA_Transactions_[0-9]+[.](xml|txt)|transactions[.]json)'
FILE_FORMAT = (FORMAT_NAME = ff_raw_text)
ON_ERROR    = ABORT_STATEMENT
FORCE       = TRUE;

/* ---------------------------------------------------------------------------
   Client A master data
   ------------------------------------------------------------------------ */
COPY INTO raw_client_a_customers
       (customer_id, first_name, last_name, email, loyalty_tier,
        signup_source, is_active, source_file, file_row_number)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
    FROM @raw_files/client_a/Customer.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_client_csv)
ON_ERROR    = CONTINUE
FORCE       = TRUE;

COPY INTO raw_client_a_orders
       (order_id, customer_id, order_date, order_status, channel,
        source_file, file_row_number)
FROM (
    SELECT $1, $2, $3, $4, $5,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
    FROM @raw_files/client_a/Orders.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_client_csv)
ON_ERROR    = CONTINUE
FORCE       = TRUE;

COPY INTO raw_client_a_products
       (sku, product_name, category, unit_price, currency, is_active,
        source_file, file_row_number)
FROM (
    SELECT $1, $2, $3, $4, $5, $6,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
    FROM @raw_files/client_a/Products.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_client_csv)
ON_ERROR    = CONTINUE
FORCE       = TRUE;

/* ---------------------------------------------------------------------------
   Client B master data
   ------------------------------------------------------------------------ */
COPY INTO raw_client_b_customers
       (customer_id, customer_name, email, segment, is_active,
        source_file, file_row_number)
FROM (
    SELECT $1, $2, $3, $4, $5,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
    FROM @raw_files/client_b/Customer.CSV
)
FILE_FORMAT = (FORMAT_NAME = ff_client_csv)
ON_ERROR    = CONTINUE
FORCE       = TRUE;

COPY INTO raw_client_b_orders
       (order_id, customer_id, order_date, order_status,
        source_file, file_row_number)
FROM (
    SELECT $1, $2, $3, $4,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
    FROM @raw_files/client_b/Order.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_client_csv)
ON_ERROR    = CONTINUE
FORCE       = TRUE;

COPY INTO raw_client_b_products
       (sku, product_name, category, unit_price, currency, is_active,
        source_file, file_row_number)
FROM (
    SELECT $1, $2, $3, $4, $5, $6,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
    FROM @raw_files/client_b/Product.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_client_csv)
ON_ERROR    = CONTINUE
FORCE       = TRUE;

COPY INTO raw_client_b_payments
       (payment_id, order_id, payment_method, amount, currency, status,
        source_file, file_row_number)
FROM (
    SELECT $1, $2, $3, $4, $5, $6,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
    FROM @raw_files/client_b/Payments.csv
)
FILE_FORMAT = (FORMAT_NAME = ff_client_csv)
ON_ERROR    = CONTINUE
FORCE       = TRUE;
