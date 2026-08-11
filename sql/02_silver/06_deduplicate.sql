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
                                     AND (q.natural_key = i.transaction_id
                                          OR (q.natural_key IS NULL
                                              AND i.transaction_id IS NULL))
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
           -- Matched on natural_key too, so this predicate is identical to the
           -- one the completeness tiebreaker uses above. They differed by this
           -- column: for a rejected line whose parent transaction has no id,
           -- natural_key is NULL, so the tiebreaker counted the line as
           -- readable while this dropped it — the two disagreeing about the
           -- same row. Equal-or-NULL because NULL = NULL is never true.
           AND (q.natural_key = i.transaction_id
                OR (q.natural_key IS NULL AND i.transaction_id IS NULL))
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
   which is what makes an unguarded join multiply rows.

   The tiebreaker is LEAST WRONG FIRST, then file position — the master
   equivalent of the completeness rule the transaction path uses above, and for
   the same reason. Plain 'last row wins' published the deliberately corrupted
   copy: Product.csv delivers C-SKU-011 as 59.99 in the body and -59.99 in the
   trailing anomaly block, so dim_product carried -59.99 while the clean row was
   quarantined as the duplicate. Every CSV keeps its corrupted copies in that
   trailing block, so the naive rule preferred them systematically.

   defect_count comes from v_master_defect_count, which 04 builds from the
   findings its own rules raised — and 04's DUPLICATE_* rules break the tie by
   reading the same view, so the copy quarantine names as discarded is the copy
   actually discarded here.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE customers_clean AS
SELECT m.source_system, m.customer_id,
       NULLIF(TRIM(COALESCE(m.first_name, '') || ' ' || COALESCE(m.last_name, '')), '') AS customer_name,
       m.first_name, m.last_name, m.email,
       m.loyalty_tier                       AS tier_raw,
       -- NULL when the row ended early. RAGGED_ROW records that CUST-A-0040
       -- shifted one column left, so this field holds is_active's 'false'.
       -- Publishing it would assert a signup channel the client never sent —
       -- the same reason a missing payment status is not defaulted to UNKNOWN.
       IFF(m.is_active_raw IS NULL AND LOWER(m.signup_source) IN ('true', 'false'),
           NULL, m.signup_source)      AS signup_source,
       m.is_active, m.source_file, m.file_row_number
FROM   stg_client_a_customers AS m
LEFT JOIN v_master_defect_count AS d
       ON m.source_system   = d.source_system
      AND m.customer_id = d.natural_key
      AND m.file_row_number = d.file_row_number
      AND d.entity          = 'customer'
WHERE  m.customer_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY m.source_system, m.customer_id
                           ORDER BY COALESCE(d.defect_count, 0) ASC,
                                    -- source_file because METADATA$FILE_ROW_NUMBER
                                    -- restarts at each file: Client A already
                                    -- arrives split across seven, so a master
                                    -- entity delivered in two files would tie
                                    -- and ROW_NUMBER would pick arbitrarily.
                                    m.file_row_number DESC, m.source_file DESC) = 1
UNION ALL
SELECT m.source_system, m.customer_id,
       m.customer_name,
       NULL AS first_name, NULL AS last_name, m.email,
       m.segment                            AS tier_raw,
       NULL AS signup_source, m.is_active, m.source_file, m.file_row_number
FROM   stg_client_b_customers AS m
LEFT JOIN v_master_defect_count AS d
       ON m.source_system   = d.source_system
      AND m.customer_id = d.natural_key
      AND m.file_row_number = d.file_row_number
      AND d.entity          = 'customer'
WHERE  m.customer_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY m.source_system, m.customer_id
                           ORDER BY COALESCE(d.defect_count, 0) ASC,
                                    -- source_file because METADATA$FILE_ROW_NUMBER
                                    -- restarts at each file: Client A already
                                    -- arrives split across seven, so a master
                                    -- entity delivered in two files would tie
                                    -- and ROW_NUMBER would pick arbitrarily.
                                    m.file_row_number DESC, m.source_file DESC) = 1;

CREATE OR REPLACE TABLE products_clean AS
SELECT m.source_system, m.sku, m.product_name, m.category, m.unit_price, m.currency,
       m.is_active, m.source_file, m.file_row_number
FROM   stg_client_a_products AS m
LEFT JOIN v_master_defect_count AS d
       ON m.source_system   = d.source_system
      AND m.sku = d.natural_key
      AND m.file_row_number = d.file_row_number
      AND d.entity          = 'product'
WHERE  m.sku IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY m.source_system, m.sku
                           ORDER BY COALESCE(d.defect_count, 0) ASC,
                                    -- source_file because METADATA$FILE_ROW_NUMBER
                                    -- restarts at each file: Client A already
                                    -- arrives split across seven, so a master
                                    -- entity delivered in two files would tie
                                    -- and ROW_NUMBER would pick arbitrarily.
                                    m.file_row_number DESC, m.source_file DESC) = 1
UNION ALL
SELECT m.source_system, m.sku, m.product_name, m.category, m.unit_price, m.currency,
       m.is_active, m.source_file, m.file_row_number
FROM   stg_client_b_products AS m
LEFT JOIN v_master_defect_count AS d
       ON m.source_system   = d.source_system
      AND m.sku = d.natural_key
      AND m.file_row_number = d.file_row_number
      AND d.entity          = 'product'
WHERE  m.sku IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY m.source_system, m.sku
                           ORDER BY COALESCE(d.defect_count, 0) ASC,
                                    -- source_file because METADATA$FILE_ROW_NUMBER
                                    -- restarts at each file: Client A already
                                    -- arrives split across seven, so a master
                                    -- entity delivered in two files would tie
                                    -- and ROW_NUMBER would pick arbitrarily.
                                    m.file_row_number DESC, m.source_file DESC) = 1;

CREATE OR REPLACE TABLE orders_clean AS
SELECT m.source_system, m.order_id, m.customer_id, m.order_date, m.order_status, m.channel,
       m.source_file, m.file_row_number
FROM   stg_client_a_orders AS m
LEFT JOIN v_master_defect_count AS d
       ON m.source_system   = d.source_system
      AND m.order_id = d.natural_key
      AND m.file_row_number = d.file_row_number
      AND d.entity          = 'order'
WHERE  m.order_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY m.source_system, m.order_id
                           ORDER BY COALESCE(d.defect_count, 0) ASC,
                                    -- source_file because METADATA$FILE_ROW_NUMBER
                                    -- restarts at each file: Client A already
                                    -- arrives split across seven, so a master
                                    -- entity delivered in two files would tie
                                    -- and ROW_NUMBER would pick arbitrarily.
                                    m.file_row_number DESC, m.source_file DESC) = 1
UNION ALL
SELECT m.source_system, m.order_id, m.customer_id, m.order_date, m.order_status, m.channel,
       m.source_file, m.file_row_number
FROM   stg_client_b_orders AS m
LEFT JOIN v_master_defect_count AS d
       ON m.source_system   = d.source_system
      AND m.order_id = d.natural_key
      AND m.file_row_number = d.file_row_number
      AND d.entity          = 'order'
WHERE  m.order_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY m.source_system, m.order_id
                           ORDER BY COALESCE(d.defect_count, 0) ASC,
                                    -- source_file because METADATA$FILE_ROW_NUMBER
                                    -- restarts at each file: Client A already
                                    -- arrives split across seven, so a master
                                    -- entity delivered in two files would tie
                                    -- and ROW_NUMBER would pick arbitrarily.
                                    m.file_row_number DESC, m.source_file DESC) = 1;

/* Client B only — Client A embeds payment in the transaction, with no id and
   no status. Gold reconciles the two shapes without inventing the missing
   fields. */
CREATE OR REPLACE TABLE payments_clean AS
SELECT m.source_system, m.payment_id, m.order_id, m.payment_method, m.amount, m.currency, m.status,
       m.source_file, m.file_row_number
FROM   stg_client_b_payments AS m
LEFT JOIN v_master_defect_count AS d
       ON m.source_system   = d.source_system
      AND m.payment_id = d.natural_key
      AND m.file_row_number = d.file_row_number
      AND d.entity          = 'payment'
WHERE  m.payment_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY m.source_system, m.payment_id
                           ORDER BY COALESCE(d.defect_count, 0) ASC,
                                    -- source_file because METADATA$FILE_ROW_NUMBER
                                    -- restarts at each file: Client A already
                                    -- arrives split across seven, so a master
                                    -- entity delivered in two files would tie
                                    -- and ROW_NUMBER would pick arbitrarily.
                                    m.file_row_number DESC, m.source_file DESC) = 1;

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
