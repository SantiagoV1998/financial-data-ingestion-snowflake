/* ============================================================================
   01 · BRONZE — LOAD
   ----------------------------------------------------------------------------
   Loads every staged file into its bronze table, attaching lineage.

   Re-runnability. Each target is TRUNCATEd before its COPY. FORCE = TRUE alone
   is not enough and is in fact dangerous: it disables the load-metadata guard
   that would otherwise skip already-loaded files, so without a TRUNCATE a
   second run appends a complete second copy of every file. For the CSV tables
   that silently inflates counts; for raw_text_lines it is worse, because the
   XML reassembly stitches lines with LISTAGG in file order and would emit every
   line twice in adjacent pairs, producing <Transaction><Transaction> and making
   PARSE_XML raise. TRUNCATE + FORCE together give a genuinely idempotent load.

   The PATTERN tolerates an optional .gz suffix. 02_upload_files.sql stages with
   AUTO_COMPRESS = FALSE, but PUT's default is TRUE, and a pattern that misses
   the compressed name matches zero files — which COPY reports as success, not
   as an error. ON_ERROR would not catch it. The optional group makes the load
   correct under either upload.
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
TRUNCATE TABLE raw_text_lines;

COPY INTO raw_text_lines (source_file, file_row_number, line_text)
FROM (
    SELECT METADATA$FILENAME,
           METADATA$FILE_ROW_NUMBER,
           $1
    FROM @raw_files
)
PATTERN     = '.*(ClientA_Transactions_[0-9]+[.](xml|txt)|transactions[.]json)([.]gz)?'
FILE_FORMAT = (FORMAT_NAME = ff_raw_text)
ON_ERROR    = ABORT_STATEMENT
FORCE       = TRUE;

/* ---------------------------------------------------------------------------
   Client A master data
   ------------------------------------------------------------------------ */
TRUNCATE TABLE raw_client_a_customers;
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

TRUNCATE TABLE raw_client_a_orders;
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

TRUNCATE TABLE raw_client_a_products;
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
TRUNCATE TABLE raw_client_b_customers;
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

TRUNCATE TABLE raw_client_b_orders;
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

TRUNCATE TABLE raw_client_b_products;
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

TRUNCATE TABLE raw_client_b_payments;
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

/* ---------------------------------------------------------------------------
   Remove the exporter footer
   ----------------------------------------------------------------------------
   Every CSV ends with ----- END OF FILE -----. SKIP_HEADER removes the banner
   at the top but there is no SKIP_FOOTER, and COPY INTO rejects a WHERE clause
   in its transformation, so the line loads as a row whose business key is the
   literal footer text and whose remaining columns are NULL. Left in place it is
   indistinguishable from real data and inflates every count by one per table.

   Deleting it here is not data cleansing — the banner and the footer are both
   exporter metadata, and we already discard the banner via SKIP_HEADER. Removing
   both is reading the format correctly. Genuine data-quality decisions (nulls,
   negative amounts, invalid emails) belong in silver, where they are recorded
   in dq_quarantine rather than deleted.

   raw_text_lines is deliberately NOT filtered here: it is a literal dump whose
   rows are lines, not business records, and its banner lines carry no false key.
   They are excluded by the reassembly logic in silver instead.
   ------------------------------------------------------------------------ */
DELETE FROM raw_client_a_customers WHERE REGEXP_LIKE(customer_id, '^\\s*-{3,}.*OF FILE.*$');
DELETE FROM raw_client_a_orders    WHERE REGEXP_LIKE(order_id,    '^\\s*-{3,}.*OF FILE.*$');
DELETE FROM raw_client_a_products  WHERE REGEXP_LIKE(sku,         '^\\s*-{3,}.*OF FILE.*$');
DELETE FROM raw_client_b_customers WHERE REGEXP_LIKE(customer_id, '^\\s*-{3,}.*OF FILE.*$');
DELETE FROM raw_client_b_orders    WHERE REGEXP_LIKE(order_id,    '^\\s*-{3,}.*OF FILE.*$');
DELETE FROM raw_client_b_products  WHERE REGEXP_LIKE(sku,         '^\\s*-{3,}.*OF FILE.*$');
DELETE FROM raw_client_b_payments  WHERE REGEXP_LIKE(payment_id,  '^\\s*-{3,}.*OF FILE.*$');
