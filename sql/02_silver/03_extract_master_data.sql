/* ============================================================================
   02 · SILVER — MASTER DATA
   ----------------------------------------------------------------------------
   Types the CSV master tables. Bronze holds every column as VARCHAR; here they
   become dates, numbers and booleans — with the original text retained wherever
   a cast can fail, so a quality rule can report what actually arrived rather
   than just "NULL".

   The schema divergence between the two clients is preserved, not resolved:
   Client A splits first_name / last_name where Client B has one customer_name,
   and Client A's loyalty_tier (GOLD/SILVER) is a different taxonomy from Client
   B's segment (VIP/REGULAR). Conforming them is gold's job, and doing it here
   would destroy the evidence gold needs.

   TRY_TO_BOOLEAN, not a comparison against 'true': the latter silently maps
   every unexpected value — 'TRUE', 'Y', '1', a shifted column — to false, which
   reads as a deliberate flag rather than as bad data.
   ========================================================================= */

USE ROLE ingestion_engineer;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA silver;


/* ---------------------------------------------------------------------------
   Exporter annotations inside the CSV values
   ----------------------------------------------------------------------------
   FINDING. All seven CSVs carry inline annotations appended to data rows:

       CUST-A-0001,John,Doe,john.doe@example.com,GOLD,Web,true   <-- duplicate
       CUST-A-0033,Julia,Chen,jchen@@example..com,SILVER,Web,true <-- invalid email
       CUST-A-0040,,,,,false                                      <-- null-heavy row

   28 of them across the delivery. They are the same device as the XML comments:
   the provider labelling each intentional anomaly. But where an XML comment is a
   separate node the parser ignores, these sit INSIDE a field value, so
   `true   <-- duplicate` is what reaches the column — and TRY_TO_BOOLEAN
   returns NULL, which reads as bad source data rather than as an artefact.

   They do not always land in the last column. The short row above carries six
   fields for seven columns, so its annotation ends up in signup_source. Every
   text field is therefore cleaned, not just the last one.

   The annotation is not discarded. It is the provider's own statement of which
   anomaly each row contains, which makes it ground truth for validating the
   quality rules in 05 — rules that agree with it are demonstrably right, and
   rows it flags that the rules miss are gaps worth knowing about.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE FUNCTION F_STRIP_ANNOTATION(s VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Removes an inline "<-- ..." exporter annotation from a CSV value'
AS $$
    NULLIF(TRIM(REGEXP_REPLACE(s, '\\s*<--.*$', '')), '')
$$;

CREATE OR REPLACE FUNCTION F_ANNOTATION(s VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Returns the inline "<-- ..." annotation from a CSV value, or NULL'
AS $$
    NULLIF(TRIM(REGEXP_SUBSTR(s, '<--\\s*(.*)$', 1, 1, 'e', 1)), '')
$$;

/* ---------------------------------------------------------------------------
   Client A
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE stg_client_a_customers AS
SELECT
    'CLIENT_A'                        AS source_system,
    F_STRIP_ANNOTATION(customer_id)     AS customer_id,
    F_STRIP_ANNOTATION(first_name)      AS first_name,
    F_STRIP_ANNOTATION(last_name)       AS last_name,
    F_STRIP_ANNOTATION(email)           AS email,
    F_STRIP_ANNOTATION(loyalty_tier)    AS loyalty_tier,
    F_STRIP_ANNOTATION(signup_source)   AS signup_source,
    is_active                         AS is_active_raw,
    TRY_TO_BOOLEAN(F_STRIP_ANNOTATION(is_active)) AS is_active,
    -- The provider's own label for this row's anomaly, kept as ground truth
    -- for validating the quality rules. Can appear in any column, since a short
    -- row shifts it left.
    COALESCE(
        F_ANNOTATION(customer_id),
        F_ANNOTATION(first_name),
        F_ANNOTATION(last_name),
        F_ANNOTATION(email),
        F_ANNOTATION(loyalty_tier),
        F_ANNOTATION(signup_source),
        F_ANNOTATION(is_active)
    )
        AS source_annotation,
    source_file,
    file_row_number
FROM bronze.raw_client_a_customers;

CREATE OR REPLACE TABLE stg_client_a_orders AS
SELECT
    'CLIENT_A'                        AS source_system,
    F_STRIP_ANNOTATION(order_id)        AS order_id,
    F_STRIP_ANNOTATION(customer_id)     AS customer_id,
    order_date                        AS order_date_raw,
    TRY_TO_DATE(F_STRIP_ANNOTATION(order_date), 'YYYY-MM-DD') AS order_date,
    F_STRIP_ANNOTATION(order_status)    AS order_status,
    F_STRIP_ANNOTATION(channel)         AS channel,          -- absent for Client B
    -- The provider's own label for this row's anomaly, kept as ground truth
    -- for validating the quality rules. Can appear in any column, since a short
    -- row shifts it left.
    COALESCE(
        F_ANNOTATION(order_id),
        F_ANNOTATION(customer_id),
        F_ANNOTATION(order_date),
        F_ANNOTATION(order_status),
        F_ANNOTATION(channel)
    )
        AS source_annotation,
    source_file,
    file_row_number
FROM bronze.raw_client_a_orders;

CREATE OR REPLACE TABLE stg_client_a_products AS
SELECT
    'CLIENT_A'                        AS source_system,
    F_STRIP_ANNOTATION(sku)             AS sku,
    F_STRIP_ANNOTATION(product_name)    AS product_name,
    F_STRIP_ANNOTATION(category)        AS category,
    unit_price                        AS unit_price_raw,
    TRY_TO_NUMBER(F_STRIP_ANNOTATION(unit_price), 18, 2) AS unit_price,
    F_STRIP_ANNOTATION(currency)        AS currency,
    is_active                         AS is_active_raw,
    TRY_TO_BOOLEAN(F_STRIP_ANNOTATION(is_active)) AS is_active,
    -- The provider's own label for this row's anomaly, kept as ground truth
    -- for validating the quality rules. Can appear in any column, since a short
    -- row shifts it left.
    COALESCE(
        F_ANNOTATION(sku),
        F_ANNOTATION(product_name),
        F_ANNOTATION(category),
        F_ANNOTATION(unit_price),
        F_ANNOTATION(currency),
        F_ANNOTATION(is_active)
    )
        AS source_annotation,
    source_file,
    file_row_number
FROM bronze.raw_client_a_products;

/* ---------------------------------------------------------------------------
   Client B
   ----------------------------------------------------------------------------
   FINDING carried forward from bronze: the folder is "Client B" but every file
   inside identifies as clientC and every id is prefixed C-. Table names follow
   the folder; identifiers keep their own prefix. See knowledge-base/DATA_SOURCES.md.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE stg_client_b_customers AS
SELECT
    'CLIENT_B'                        AS source_system,
    F_STRIP_ANNOTATION(customer_id)     AS customer_id,
    F_STRIP_ANNOTATION(customer_name)   AS customer_name,   -- one field, not two
    F_STRIP_ANNOTATION(email)           AS email,
    F_STRIP_ANNOTATION(segment)         AS segment,         -- VIP/REGULAR, not GOLD/SILVER
    is_active                         AS is_active_raw,
    TRY_TO_BOOLEAN(F_STRIP_ANNOTATION(is_active)) AS is_active,
    -- The provider's own label for this row's anomaly, kept as ground truth
    -- for validating the quality rules. Can appear in any column, since a short
    -- row shifts it left.
    COALESCE(
        F_ANNOTATION(customer_id),
        F_ANNOTATION(customer_name),
        F_ANNOTATION(email),
        F_ANNOTATION(segment),
        F_ANNOTATION(is_active)
    )
        AS source_annotation,
    source_file,
    file_row_number
FROM bronze.raw_client_b_customers;

CREATE OR REPLACE TABLE stg_client_b_orders AS
SELECT
    'CLIENT_B'                        AS source_system,
    F_STRIP_ANNOTATION(order_id)        AS order_id,
    F_STRIP_ANNOTATION(customer_id)     AS customer_id,
    order_date                        AS order_date_raw,
    TRY_TO_DATE(F_STRIP_ANNOTATION(order_date), 'YYYY-MM-DD') AS order_date,
    F_STRIP_ANNOTATION(order_status)    AS order_status,
    NULL::VARCHAR                     AS channel,         -- not delivered by this client
    -- The provider's own label for this row's anomaly, kept as ground truth
    -- for validating the quality rules. Can appear in any column, since a short
    -- row shifts it left.
    COALESCE(
        F_ANNOTATION(order_id),
        F_ANNOTATION(customer_id),
        F_ANNOTATION(order_date),
        F_ANNOTATION(order_status)
    )
        AS source_annotation,
    source_file,
    file_row_number
FROM bronze.raw_client_b_orders;

CREATE OR REPLACE TABLE stg_client_b_products AS
SELECT
    'CLIENT_B'                        AS source_system,
    F_STRIP_ANNOTATION(sku)             AS sku,
    F_STRIP_ANNOTATION(product_name)    AS product_name,
    F_STRIP_ANNOTATION(category)        AS category,
    unit_price                        AS unit_price_raw,
    TRY_TO_NUMBER(F_STRIP_ANNOTATION(unit_price), 18, 2) AS unit_price,
    F_STRIP_ANNOTATION(currency)        AS currency,
    is_active                         AS is_active_raw,
    TRY_TO_BOOLEAN(F_STRIP_ANNOTATION(is_active)) AS is_active,
    -- The provider's own label for this row's anomaly, kept as ground truth
    -- for validating the quality rules. Can appear in any column, since a short
    -- row shifts it left.
    COALESCE(
        F_ANNOTATION(sku),
        F_ANNOTATION(product_name),
        F_ANNOTATION(category),
        F_ANNOTATION(unit_price),
        F_ANNOTATION(currency),
        F_ANNOTATION(is_active)
    )
        AS source_annotation,
    source_file,
    file_row_number
FROM bronze.raw_client_b_products;

/* Client A has no payments file at all — payment is embedded in each XML
   transaction, with no payment_id and no status. Gold reconciles the two
   shapes; it does not invent the missing fields. */
CREATE OR REPLACE TABLE stg_client_b_payments AS
SELECT
    'CLIENT_B'                        AS source_system,
    F_STRIP_ANNOTATION(payment_id)      AS payment_id,
    F_STRIP_ANNOTATION(order_id)        AS order_id,
    F_STRIP_ANNOTATION(payment_method)  AS payment_method,
    amount                            AS amount_raw,
    TRY_TO_NUMBER(F_STRIP_ANNOTATION(amount), 18, 2) AS amount,
    F_STRIP_ANNOTATION(currency)        AS currency,
    F_STRIP_ANNOTATION(status)          AS status,          -- absent for Client A
    -- The provider's own label for this row's anomaly, kept as ground truth
    -- for validating the quality rules. Can appear in any column, since a short
    -- row shifts it left.
    COALESCE(
        F_ANNOTATION(payment_id),
        F_ANNOTATION(order_id),
        F_ANNOTATION(payment_method),
        F_ANNOTATION(amount),
        F_ANNOTATION(currency),
        F_ANNOTATION(status)
    )
        AS source_annotation,
    source_file,
    file_row_number
FROM bronze.raw_client_b_payments;
