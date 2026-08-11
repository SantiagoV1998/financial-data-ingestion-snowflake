/* ============================================================================
   02 · SILVER — DEDUPLICATION AND CLEAN OUTPUT
   ----------------------------------------------------------------------------
   Produces the tables gold builds on: deduplicated, with REJECT-severity rows
   held back.

   Deduplication happens exactly once, here. Downstream layers never restate the
   logic and so cannot reintroduce duplicates — and adding a column to gold
   later cannot silently change which copy survives.

   WHICH COPY SURVIVES is a business decision, not a formality. The delivery
   order is the only signal available: these are file exports with no update
   timestamp, so the last occurrence in the document is taken as the most
   recent statement of the record. document_position makes that deterministic;
   without a deterministic tiebreaker a rerun could keep a different row and the
   pipeline would stop being reproducible.

   REJECT rows are held back, not deleted. They remain in dq_quarantine with
   their payload, so a corrected rule can replay them without returning to the
   source files. WARN rows load: a negative quantity may be a return, and
   dropping it would destroy revenue the client can still explain.
   ========================================================================= */

USE ROLE ingestion_engineer;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA silver;

/* ---------------------------------------------------------------------------
   Transactions
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE transactions_clean AS
SELECT *
FROM   v_all_transactions t
WHERE  NOT EXISTS (
         SELECT 1 FROM dq_quarantine q
         WHERE q.entity        = 'transaction'
           AND q.severity      = 'REJECT'
           AND q.source_system = t.source_system
           AND (q.natural_key  = t.transaction_id
                OR (q.natural_key IS NULL AND t.transaction_id IS NULL))
       )
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY source_system, transaction_id
          ORDER BY     document_position DESC
        ) = 1;

/* ---------------------------------------------------------------------------
   Line items
   ----------------------------------------------------------------------------
   Kept only for transactions that survived, so the item table cannot reference
   a transaction gold will never see. The OUTER-produced placeholder row for a
   transaction with no items is dropped here: it existed to keep that
   transaction visible during flattening, and carries no line of its own.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE transaction_items_clean AS
SELECT i.*
FROM   v_all_transaction_items i
JOIN   transactions_clean t
  ON   t.source_system  = i.source_system
 AND   t.transaction_id = i.transaction_id
WHERE  i.raw_payload IS NOT NULL
  AND  NOT EXISTS (
         SELECT 1 FROM dq_quarantine q
         WHERE q.entity        = 'transaction_item'
           AND q.severity      = 'REJECT'
           AND q.source_system = i.source_system
           AND q.natural_key   = i.transaction_id
           AND q.line_number   = i.line_number
       )
-- Qualified: source_system exists on both sides of the join, and an
-- unqualified reference here is a compilation error. This is precisely what
-- SQLFluff's RF02 catches, which is why it was re-enabled in the CI config.
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY i.source_system, i.transaction_id, i.line_number
          ORDER BY     i.document_position DESC
        ) = 1;

/* ---------------------------------------------------------------------------
   Master data — deduplicated on the same principle
   ----------------------------------------------------------------------------
   The customer master genuinely contains repeated ids (CUST-A-0001 twice),
   which is what makes an unguarded join multiply rows. File position is the
   tiebreaker for the same reason as above.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE customers_clean AS
SELECT source_system, customer_id,
       NULLIF(TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')), '') AS customer_name,
       first_name, last_name, email,
       loyalty_tier                       AS tier_raw,
       signup_source, is_active, source_file, file_row_number
FROM   stg_client_a_customers
WHERE  customer_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY source_system, customer_id
                           ORDER BY file_row_number DESC) = 1
UNION ALL
SELECT source_system, customer_id,
       customer_name,
       NULL AS first_name, NULL AS last_name, email,
       segment                            AS tier_raw,
       NULL AS signup_source, is_active, source_file, file_row_number
FROM   stg_client_b_customers
WHERE  customer_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY source_system, customer_id
                           ORDER BY file_row_number DESC) = 1;

CREATE OR REPLACE TABLE products_clean AS
SELECT source_system, sku, product_name, category, unit_price, currency,
       is_active, source_file, file_row_number
FROM   stg_client_a_products
WHERE  sku IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY source_system, sku
                           ORDER BY file_row_number DESC) = 1
UNION ALL
SELECT source_system, sku, product_name, category, unit_price, currency,
       is_active, source_file, file_row_number
FROM   stg_client_b_products
WHERE  sku IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY source_system, sku
                           ORDER BY file_row_number DESC) = 1;

CREATE OR REPLACE TABLE orders_clean AS
SELECT source_system, order_id, customer_id, order_date, order_status, channel,
       source_file, file_row_number
FROM   stg_client_a_orders
WHERE  order_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY source_system, order_id
                           ORDER BY file_row_number DESC) = 1
UNION ALL
SELECT source_system, order_id, customer_id, order_date, order_status, channel,
       source_file, file_row_number
FROM   stg_client_b_orders
WHERE  order_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY source_system, order_id
                           ORDER BY file_row_number DESC) = 1;

/* Client B only — Client A embeds payment in the transaction, with no id and
   no status. Gold reconciles the two shapes without inventing the missing
   fields. */
CREATE OR REPLACE TABLE payments_clean AS
SELECT source_system, payment_id, order_id, payment_method, amount, currency, status,
       source_file, file_row_number
FROM   stg_client_b_payments
WHERE  payment_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY source_system, payment_id
                           ORDER BY file_row_number DESC) = 1;

/* ---------------------------------------------------------------------------
   Silver output summary
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_silver_summary AS
SELECT 'transactions_parsed'    AS stage, COUNT(*) AS row_count FROM v_all_transactions
UNION ALL SELECT 'transactions_clean',    COUNT(*) FROM transactions_clean
UNION ALL SELECT 'items_parsed',          COUNT(*) FROM v_all_transaction_items WHERE raw_payload IS NOT NULL
UNION ALL SELECT 'items_clean',           COUNT(*) FROM transaction_items_clean
UNION ALL SELECT 'customers_clean',       COUNT(*) FROM customers_clean
UNION ALL SELECT 'products_clean',        COUNT(*) FROM products_clean
UNION ALL SELECT 'orders_clean',          COUNT(*) FROM orders_clean
UNION ALL SELECT 'payments_clean',        COUNT(*) FROM payments_clean
UNION ALL SELECT 'quarantine_findings',   COUNT(*) FROM dq_quarantine;

SELECT * FROM v_silver_summary ORDER BY stage;
