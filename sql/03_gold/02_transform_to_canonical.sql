/* ============================================================================
   03 · GOLD — TRANSFORMATION INTO THE CANONICAL MODEL
   ----------------------------------------------------------------------------
   Loads silver's cleaned output into the canonical structure, resolving the
   five conflicts between the two client schemas.

   The governing principle throughout: preserve what the source said, expose a
   normalized reading beside it, and never invent a value the client did not
   send. Every place that principle applies is marked CONFLICT below.
   ========================================================================= */

USE ROLE ingestion_engineer;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA gold;

/* ---------------------------------------------------------------------------
   dim_source_system
   ------------------------------------------------------------------------ */
TRUNCATE TABLE dim_source_system;
-- INSERT ... SELECT, not VALUES: Snowflake rejects a function call inside a
-- VALUES clause ("Invalid expression [MD5('CLIENT_A')] in VALUES clause").
INSERT INTO dim_source_system
    (source_system_key, source_system, client_label, delivery_format, notes)
SELECT
    MD5('CLIENT_A'), 'CLIENT_A', 'Client A', 'XML fragments + CSV',
    'Seven XML fragments of one document with unbalanced root tags. '
    || 'Payment embedded per transaction, with no payment id and no status.'
UNION ALL
SELECT
    MD5('CLIENT_B'), 'CLIENT_B', 'Client B (contents identify as ClientC)', 'JSON + CSV',
    'Folder named Client B but every file inside identifies as clientC, with '
    || 'C- prefixed ids. Reported rather than silently resolved. JSON is a '
    || 'truncated sample: its trailing comment describes ~120 records where '
    || '11 were delivered.';

/* ---------------------------------------------------------------------------
   dim_customer
   ----------------------------------------------------------------------------
   CONFLICT 1 · name.  full_name is always populated. For Client A it is
   composed from the parts; for Client B it is the delivered field. The parts
   stay NULL for Client B rather than being split on whitespace — "Mary Jane
   Watson" has no reliable division, and a wrong split is worse than an honest
   absence.

   CONFLICT 2 · tier.  tier_raw is verbatim. tier_rank is an ordinal that makes
   the two taxonomies comparable WITHOUT claiming they are equivalent: rank 1 is
   each client's top tier, whatever it is called. A query can order by rank; a
   query that needs the real tier reads tier_raw. Nothing asserts GOLD = VIP.
   ------------------------------------------------------------------------ */
TRUNCATE TABLE dim_customer;
INSERT INTO dim_customer
    (customer_key, source_system, customer_id, full_name, first_name, last_name,
     email, email_is_valid, tier_raw, tier_rank, signup_source, is_active)
SELECT
    MD5(source_system || '|' || customer_id)  AS customer_key,
    source_system,
    customer_id,
    customer_name                             AS full_name,
    first_name,
    last_name,
    email,
    IFF(email IS NULL, NULL,
        REGEXP_LIKE(email, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$'))
                                              AS email_is_valid,
    tier_raw,
    CASE UPPER(tier_raw)
        WHEN 'GOLD'    THEN 1   -- Client A top tier
        WHEN 'VIP'     THEN 1   -- Client B top tier — same RANK, not the same tier
        WHEN 'SILVER'  THEN 2
        WHEN 'REGULAR' THEN 2
    END                                       AS tier_rank,
    signup_source,
    is_active
FROM silver.customers_clean;

/* ---------------------------------------------------------------------------
   dim_product
   ------------------------------------------------------------------------ */
TRUNCATE TABLE dim_product;
INSERT INTO dim_product
    (product_key, source_system, sku, product_name, category,
     list_unit_price, currency, is_active)
SELECT
    MD5(source_system || '|' || sku),
    source_system, sku, product_name, category, unit_price, currency, is_active
FROM silver.products_clean;

/* ---------------------------------------------------------------------------
   fact_order
   ----------------------------------------------------------------------------
   CONFLICT 4 · channel.  Passed through as delivered — Web/Mobile for Client A,
   NULL for Client B, which does not collect it. Not defaulted to 'UNKNOWN':
   "we do not know the channel" and "this client does not record channels" are
   different facts, and the second is only visible if the column stays NULL.
   ------------------------------------------------------------------------ */
TRUNCATE TABLE fact_order;
INSERT INTO fact_order
    (order_key, source_system, order_id, customer_key, order_date, order_status, channel)
SELECT
    MD5(o.source_system || '|' || o.order_id),
    o.source_system,
    o.order_id,
    -- NULL when the order references a customer with no master record. The
    -- orphan is already reported in quarantine; the model does not fabricate a
    -- dimension row to make the join succeed.
    c.customer_key,
    o.order_date,
    o.order_status,
    o.channel
FROM      silver.orders_clean AS o
LEFT JOIN dim_customer AS c
       ON o.source_system = c.source_system
      AND o.customer_id   = c.customer_id;

/* ---------------------------------------------------------------------------
   fact_order_item
   ----------------------------------------------------------------------------
   CONFLICT 5 · currency.  Cascade: the line's own currency, then the product
   master's, then the transaction's. Recorded per line rather than assumed
   uniform — a delivery mixing currencies would otherwise be summed together
   silently, which is the kind of error that survives all the way to a report.

   is_return_line flags a negative quantity instead of dropping it. It may be a
   genuine return; the client decides, and the flag makes either reading
   queryable.
   ------------------------------------------------------------------------ */
TRUNCATE TABLE fact_order_item;
INSERT INTO fact_order_item
    (order_item_key, source_system, transaction_key, order_key, product_key, sku,
     line_number, description, quantity, unit_price, line_amount, currency, is_return_line)
WITH t AS (SELECT source_system, transaction_id, order_id,
                  MAX(payment_currency) AS currency_hint
           FROM   silver.transactions_clean
           GROUP  BY source_system, transaction_id, order_id
)
SELECT
    MD5(i.source_system || '|' || i.transaction_id || '|' || i.line_number),
    i.source_system,
    MD5(i.source_system || '|' || i.transaction_id)                  AS transaction_key,
    o.order_key,
    p.product_key,
    i.sku,
    i.line_number,
    i.description,
    i.quantity,
    i.unit_price,
    i.quantity * i.unit_price                                        AS line_amount,
    COALESCE(i.currency, p.currency, t.currency_hint)                AS currency,
    IFF(i.quantity IS NULL, NULL, i.quantity < 0)                    AS is_return_line
FROM      silver.transaction_items_clean AS i
LEFT JOIN t
       ON i.source_system  = t.source_system
      AND i.transaction_id = t.transaction_id
LEFT JOIN dim_product AS p
       ON i.source_system = p.source_system
      AND i.sku           = p.sku
-- NULL when the order has no master record, as customer_key already is.
LEFT JOIN fact_order AS o
       ON i.source_system = o.source_system
      AND t.order_id      = o.order_id;

/* ---------------------------------------------------------------------------
   fact_transaction
   ----------------------------------------------------------------------------
   amount_variance is the reconciliation this model exists to make possible:
   the difference between what the source says was paid and what its own lines
   add up to. A non-zero variance is not corrected here — correcting it would
   erase the finding — it is measured and left visible.
   ------------------------------------------------------------------------ */
TRUNCATE TABLE fact_transaction;
INSERT INTO fact_transaction
    (transaction_key, source_system, transaction_id, order_key, customer_key,
     transaction_date, line_count, gross_line_amount, payment_amount,
     amount_variance, rejected_line_count, variance_is_comparable,
     currency, has_quality_warning)
WITH li AS (SELECT source_system, transaction_key,
                  COUNT(*)                  AS line_count,
                  SUM(line_amount)          AS gross_line_amount,
                  MAX(currency)             AS currency
           FROM   fact_order_item
           GROUP  BY source_system, transaction_key
),
rj AS (SELECT source_system, natural_key, document_position,
                  -- DISTINCT line_number, not COUNT(*): a row is deliberately
                  -- recorded once per rule it violates, so a line that is both
                  -- missing its SKU and negatively priced would be counted twice
                  -- and overstate how much of the transaction was unreadable.
                  COUNT(DISTINCT line_number) AS rejected_lines
           FROM   silver.dq_quarantine
           WHERE  entity = 'transaction_item' AND severity = 'REJECT'
           GROUP  BY source_system, natural_key, document_position
)
SELECT
    MD5(t.source_system || '|' || t.transaction_id),
    t.source_system,
    t.transaction_id,
    -- NULL when the order has no master record, exactly as customer_key is.
    -- Deriving the key from the id regardless produced 19 transactions pointing
    -- at fact_order rows that were never created — a foreign key referencing
    -- nothing, invisible to the validation gate because no check looked.
    o.order_key,
    c.customer_key,
    t.order_date                                                     AS transaction_date,
    COALESCE(li.line_count, 0)                                       AS line_count,
    -- COALESCE to zero, not NULL. When every line of a transaction was REJECTed
    -- the join to li misses, and a NULL variance excluded exactly the worst
    -- reconciliation cases — 100% of the payment unaccounted for — from both the
    -- variance count and its total. The failure hid itself.
    COALESCE(li.gross_line_amount, 0)                                AS gross_line_amount,
    t.payment_amount,
    ROUND(t.payment_amount - COALESCE(li.gross_line_amount, 0), 2)   AS amount_variance,
    COALESCE(rj.rejected_lines, 0)                                   AS rejected_line_count,
    -- The variance only means "the source disagrees with itself" when every
    -- line was readable. Where lines were rejected the gap is partly ours, and
    -- reporting the two together would overstate the source's inconsistency.
    COALESCE(rj.rejected_lines, 0) = 0                               AS variance_is_comparable,
    COALESCE(t.payment_currency, li.currency)                        AS currency,
    EXISTS(SELECT 1 FROM silver.dq_quarantine AS q
            -- Scoped to THIS copy. Without document_position a warning raised
            -- against a discarded copy flags the surviving one — the same
            -- cross-copy leak the deduplication join was corrected for. A
            -- previous commit claimed this fix and did not apply it.
            WHERE q.source_system     = t.source_system
              AND q.natural_key       = t.transaction_id
              AND q.document_position = t.document_position
              AND q.entity            = 'transaction'
              AND q.severity          = 'WARN')                      AS has_quality_warning
FROM      silver.transactions_clean AS t
LEFT JOIN li
       ON li.transaction_key = MD5(t.source_system || '|' || t.transaction_id)
LEFT JOIN dim_customer AS c
       ON t.source_system = c.source_system
      AND t.customer_id   = c.customer_id
LEFT JOIN fact_order AS o
       ON t.source_system = o.source_system
      AND t.order_id      = o.order_id
LEFT JOIN rj
       ON t.source_system     = rj.source_system
      AND t.transaction_id       = rj.natural_key
      AND t.document_position = rj.document_position;

/* ---------------------------------------------------------------------------
   fact_payment
   ----------------------------------------------------------------------------
   CONFLICT 3 · payment shape.  Two sources, deliberately different treatment:

     Client B  a payments file, with a real payment_id and a real status.
     Client A  payment embedded in the transaction, with neither. The key is
               derived from the transaction, flagged as a surrogate, and status
               stays NULL with status_source recording WHY. A fabricated
               'UNKNOWN' would be indistinguishable from a status the client
               actually sent.
   ------------------------------------------------------------------------ */
TRUNCATE TABLE fact_payment;

-- Client B: delivered payments
INSERT INTO fact_payment
    (payment_key, source_system, payment_id, payment_id_is_surrogate, order_key,
     transaction_key, payment_method, amount, currency, status, status_source, is_refund)
WITH t AS (SELECT source_system, order_id, MIN(transaction_id) AS transaction_id
           FROM   silver.transactions_clean
           GROUP  BY source_system, order_id
)
SELECT
    MD5(p.source_system || '|' || p.payment_id),
    p.source_system,
    p.payment_id,
    FALSE,
    o.order_key,
    MD5(t.source_system || '|' || t.transaction_id),
    p.payment_method,
    p.amount,
    p.currency,
    p.status,
    'delivered by source',
    IFF(p.amount IS NULL, NULL, p.amount < 0)
FROM      silver.payments_clean AS p
-- One row per order, not per transaction: a LEFT JOIN straight to
-- transactions_clean fans out when an order carries several transaction ids,
-- duplicating payment_key and doubling SUM(amount).
LEFT JOIN t
       ON p.source_system = t.source_system
      AND p.order_id      = t.order_id
-- Resolved through fact_order, not derived: fact_transaction and
-- fact_order_item were corrected for this and fact_payment was missed, leaving
-- 19 Client A payments pointing at orders that were never created.
LEFT JOIN fact_order AS o
       ON p.source_system = o.source_system
      AND p.order_id      = o.order_id;

-- Client A: payment embedded in the transaction
INSERT INTO fact_payment
    (payment_key, source_system, payment_id, payment_id_is_surrogate, order_key,
     transaction_key, payment_method, amount, currency, status, status_source, is_refund)
SELECT
    MD5(t.source_system || '|PAY|' || t.transaction_id),
    t.source_system,
    'PAY-' || t.transaction_id                       AS payment_id,
    TRUE                                             AS payment_id_is_surrogate,
    o.order_key,
    MD5(t.source_system || '|' || t.transaction_id),
    t.payment_method,
    t.payment_amount,
    t.payment_currency,
    NULL                                             AS status,
    'not delivered: payment is embedded in the transaction and carries no status field'
                                                     AS status_source,
    IFF(t.payment_amount IS NULL, NULL, t.payment_amount < 0)
FROM      silver.transactions_clean AS t
LEFT JOIN fact_order AS o
       ON t.source_system = o.source_system
      AND t.order_id      = o.order_id
WHERE t.source_system = 'CLIENT_A';

/* ---------------------------------------------------------------------------
   dq_summary
   ------------------------------------------------------------------------ */
TRUNCATE TABLE dq_summary;
INSERT INTO dq_summary (source_system, entity, severity, rule_code, finding_count)
SELECT source_system, entity, severity, rule_code, COUNT(*)
FROM   silver.dq_quarantine
GROUP  BY source_system, entity, severity, rule_code;

SELECT 'dim_source_system' AS table_name, COUNT(*) AS row_count FROM dim_source_system
UNION ALL
SELECT 'dim_customer',     COUNT(*) FROM dim_customer
UNION ALL
SELECT 'dim_product',      COUNT(*) FROM dim_product
UNION ALL
SELECT 'fact_order',       COUNT(*) FROM fact_order
UNION ALL
SELECT 'fact_transaction', COUNT(*) FROM fact_transaction
UNION ALL
SELECT 'fact_order_item',  COUNT(*) FROM fact_order_item
UNION ALL
SELECT 'fact_payment',     COUNT(*) FROM fact_payment
UNION ALL
SELECT 'dq_summary',       COUNT(*) FROM dq_summary
ORDER BY table_name;
