/* ============================================================================
   02 · SILVER — DEDUPLICATION AND CLEAN OUTPUT
   ----------------------------------------------------------------------------
   Produces the tables gold builds on: deduplicated, with REJECT-severity rows
   held back.

   Deduplication happens exactly once, here. Downstream layers never restate the
   logic and so cannot reintroduce duplicates — and adding a column to gold
   later cannot silently change which copy survives.

   WHICH COPY SURVIVES is a business decision, not a formality, and the obvious
   answer is wrong here.

   "Last occurrence wins" is the usual reading of a file export with no update
   timestamp. But these duplicates are not restatements — they are duplication
   artefacts, and the provider says so: the second copy of C-TXN-3001 is labelled
   `// duplicate` in the source and carries `"items": []`. Taking the last copy
   kept the empty one, dropped the only real line, and produced a transaction
   with a 149.99 payment and no lines at all — a fabricated 149.99 variance, 74%
   of Client B's reported total.

   So completeness wins first: the copy carrying the most line items, with
   document position as the tiebreaker among equals. That both matches the
   provider's own labelling and preserves data instead of discarding it. It stays
   fully deterministic, which is what reproducibility actually requires.

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
-- The REJECT match is POSITION-AWARE. Matching on transaction_id alone would
-- drop every copy of a duplicated id when only one of them is defective: a
-- transaction whose second copy has an empty <OrderID> would vanish from gold
-- entirely, taking its clean first copy with it.
CREATE OR REPLACE TABLE transactions_clean AS
SELECT t.*
FROM   (SELECT v.*,
               (SELECT COUNT(*)
                FROM   v_all_transaction_items AS i
                WHERE  i.source_system     = v.source_system
                  AND  i.transaction_id    = v.transaction_id
                  AND  i.document_position = v.document_position
                  AND  i.raw_payload IS NOT NULL
                  -- Only READABLE lines count. Counting rejected ones could keep
                  -- a copy whose lines are all unusable over one that is fine,
                  -- and the validation gate cannot catch it: the
                  -- no_transaction_lost_its_only_lines check exempts any
                  -- transaction with rejected lines, which is exactly this case.
                  AND  NOT EXISTS (SELECT 1 FROM dq_quarantine AS q
                                   WHERE q.entity            = 'transaction_item'
                                     AND q.severity          = 'REJECT'
                                     AND q.source_system     = i.source_system
                                     AND q.natural_key       = i.transaction_id
                                     AND q.document_position = i.document_position
                                     AND q.line_number       = i.line_number)
                 ) AS line_item_count
        FROM v_all_transactions AS v) AS t
WHERE  NOT EXISTS (
         SELECT 1 FROM dq_quarantine AS q
         WHERE q.entity            = 'transaction'
           AND q.severity          = 'REJECT'
           AND q.source_system     = t.source_system
           AND q.document_position = t.document_position
       )
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY t.source_system, t.transaction_id
          ORDER BY     t.line_item_count DESC, t.document_position DESC
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
FROM   v_all_transaction_items AS i
-- The join carries document_position, and that is load-bearing.
--
-- Joining on transaction_id alone let lines from a DISCARDED copy attach to the
-- surviving one. TXN-1001 is delivered twice: copy 1 has two items, copy 2 has
-- one. When deduplication kept the LAST copy, line 2 existed only in copy 1 and
-- had no competitor to lose to, so it survived and attached itself to a copy it
-- did not belong to — mixing two records into one.
--
-- Today the tiebreaker below keeps copy 1 (more lines), and this join keeps its
-- lines with it. TXN-1001 still reports a 91.00 variance, but now legitimately:
-- copy 1's own lines sum to 2 x 25.99 - 1 x 45.50 = 6.48 against a stated 97.48.
-- Same number, different provenance — which is exactly why the position must be
-- carried rather than inferred from the value looking familiar.
INNER JOIN   transactions_clean AS t
  ON   i.source_system     = t.source_system
 AND   i.transaction_id    = t.transaction_id
 AND   i.document_position = t.document_position
WHERE  i.raw_payload IS NOT NULL
  AND  NOT EXISTS (
         SELECT 1 FROM dq_quarantine AS q
         WHERE q.entity            = 'transaction_item'
           AND q.severity          = 'REJECT'
           AND q.source_system     = i.source_system
           AND q.document_position = i.document_position
           AND q.line_number       = i.line_number
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
   Master-data reconciliation — every staged row is either kept or accounted for
   ----------------------------------------------------------------------------
   The four statements above discard rows two ways: WHERE <id> IS NOT NULL, and
   QUALIFY ROW_NUMBER() = 1. Both were silent. A row could leave the pipeline
   with no finding, no payload and nothing comparing the counts — which is how 8
   discarded master rows went unnoticed while the transaction path was audited
   line by line.

   This view closes that: staged must equal kept plus the rows quarantine says
   were discarded. It is a reconciliation, not a count — if 04's duplicate rules
   ever stop mirroring the tiebreaker used here, the two sides disagree and the
   script raises instead of quietly losing a row.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_master_reconciliation AS
WITH staged AS (
    SELECT 'customer' AS entity, COUNT(*) AS n FROM v_all_customers
    UNION ALL
    SELECT 'product', COUNT(*) FROM v_all_products
    UNION ALL
    SELECT 'order', COUNT(*) FROM v_all_master_orders
    UNION ALL
    SELECT 'payment', COUNT(*) FROM v_all_master_payments
), kept AS (
    SELECT 'customer' AS entity, COUNT(*) AS n FROM customers_clean
    UNION ALL
    SELECT 'product', COUNT(*) FROM products_clean
    UNION ALL
    SELECT 'order', COUNT(*) FROM orders_clean
    UNION ALL
    SELECT 'payment', COUNT(*) FROM payments_clean
), accounted AS (
    SELECT entity, COUNT(*) AS n
    FROM   dq_quarantine
    WHERE  entity IN ('customer', 'product', 'order', 'payment')
      AND  rule_code IN ('DUPLICATE_CUSTOMER_ID', 'DUPLICATE_SKU',
                         'DUPLICATE_MASTER_ORDER_ID', 'DUPLICATE_PAYMENT_ID',
                         'MISSING_CUSTOMER_ID', 'MISSING_MASTER_SKU',
                         'MISSING_MASTER_ORDER_ID', 'MISSING_PAYMENT_ID')
    GROUP  BY entity
)
SELECT s.entity,
       s.n                            AS staged_rows,
       k.n                            AS kept_rows,
       COALESCE(a.n, 0)               AS discarded_and_recorded,
       s.n - k.n                      AS discarded_actual
FROM   staged AS s
INNER JOIN kept AS k ON s.entity = k.entity
LEFT  JOIN accounted AS a ON s.entity = a.entity;

EXECUTE IMMEDIATE $$
DECLARE
    failed INTEGER;
    master_reconciliation_failed EXCEPTION (-20004, 'Master rows were discarded without being recorded in quarantine');
BEGIN
    SELECT COUNT(*) INTO :failed
    FROM v_master_reconciliation WHERE discarded_actual <> discarded_and_recorded;
    IF (failed > 0) THEN
        RAISE master_reconciliation_failed;
    END IF;
    RETURN 'Every discarded master row is recorded in quarantine';
END;
$$;

/* ---------------------------------------------------------------------------
   Silver output summary
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_silver_summary AS
SELECT 'transactions_parsed'    AS stage, COUNT(*) AS row_count FROM v_all_transactions
UNION ALL
SELECT 'transactions_clean',    COUNT(*) FROM transactions_clean
UNION ALL
SELECT 'items_parsed',          COUNT(*) FROM v_all_transaction_items WHERE raw_payload IS NOT NULL
UNION ALL
SELECT 'items_clean',           COUNT(*) FROM transaction_items_clean
UNION ALL
SELECT 'customers_clean',       COUNT(*) FROM customers_clean
UNION ALL
SELECT 'products_clean',        COUNT(*) FROM products_clean
UNION ALL
SELECT 'orders_clean',          COUNT(*) FROM orders_clean
UNION ALL
SELECT 'payments_clean',        COUNT(*) FROM payments_clean
UNION ALL
SELECT 'quarantine_findings',   COUNT(*) FROM dq_quarantine;

SELECT * FROM v_silver_summary ORDER BY stage;
