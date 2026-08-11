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
SELECT MD5('CLIENT_A'), 'CLIENT_A', 'Client A', 'XML fragments + CSV',
       'Seven XML fragments of one document with unbalanced root tags. Payment embedded per transaction, with no payment id and no status.'
UNION ALL
SELECT MD5('CLIENT_B'), 'CLIENT_B', 'Client B (contents identify as ClientC)', 'JSON + CSV',
       'Folder named Client B but every file inside identifies as clientC, with C- prefixed ids. Reported rather than silently resolved. JSON is a truncated sample: its trailing comment describes ~120 records where 11 were delivered.';

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
        ELSE NULL
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
FROM      silver.orders_clean o
LEFT JOIN dim_customer c
       ON c.source_system = o.source_system
      AND c.customer_id   = o.customer_id;

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
SELECT
    MD5(i.source_system || '|' || i.transaction_id || '|' || i.line_number),
    i.source_system,
    MD5(i.source_system || '|' || i.transaction_id)                  AS transaction_key,
    MD5(t.source_system || '|' || t.order_id)                        AS order_key,
    p.product_key,
    i.sku,
    i.line_number,
    i.description,
    i.quantity,
    i.unit_price,
    i.quantity * i.unit_price                                        AS line_amount,
    COALESCE(i.currency, p.currency, t.currency_hint)                AS currency,
    IFF(i.quantity IS NULL, NULL, i.quantity < 0)                    AS is_return_line
FROM      silver.transaction_items_clean i
LEFT JOIN (SELECT source_system, transaction_id, order_id,
                  MAX(payment_currency) AS currency_hint
           FROM   silver.transactions_clean
           GROUP  BY 1, 2, 3) t
       ON t.source_system  = i.source_system
      AND t.transaction_id = i.transaction_id
LEFT JOIN dim_product p
       ON p.source_system = i.source_system
      AND p.sku           = i.sku;

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
     amount_variance, currency, has_quality_warning)
SELECT
    MD5(t.source_system || '|' || t.transaction_id),
    t.source_system,
    t.transaction_id,
    MD5(t.source_system || '|' || t.order_id)                        AS order_key,
    c.customer_key,
    t.order_date                                                     AS transaction_date,
    COALESCE(li.line_count, 0)                                       AS line_count,
    li.gross_line_amount,
    t.payment_amount,
    ROUND(t.payment_amount - li.gross_line_amount, 2)                AS amount_variance,
    COALESCE(t.payment_currency, li.currency)                        AS currency,
    EXISTS (SELECT 1 FROM silver.dq_quarantine q
            WHERE q.source_system = t.source_system
              AND q.natural_key   = t.transaction_id
              AND q.severity      = 'WARN')                          AS has_quality_warning
FROM      silver.transactions_clean t
LEFT JOIN (SELECT source_system, transaction_key,
                  COUNT(*)                  AS line_count,
                  SUM(line_amount)          AS gross_line_amount,
                  MAX(currency)             AS currency
           FROM   fact_order_item
           GROUP  BY 1, 2) li
       ON li.transaction_key = MD5(t.source_system || '|' || t.transaction_id)
LEFT JOIN dim_customer c
       ON c.source_system = t.source_system
      AND c.customer_id   = t.customer_id;

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
SELECT
    MD5(p.source_system || '|' || p.payment_id),
    p.source_system,
    p.payment_id,
    FALSE,
    MD5(p.source_system || '|' || p.order_id),
    MD5(t.source_system || '|' || t.transaction_id),
    p.payment_method,
    p.amount,
    p.currency,
    p.status,
    'delivered by source',
    IFF(p.amount IS NULL, NULL, p.amount < 0)
FROM      silver.payments_clean p
LEFT JOIN silver.transactions_clean t
       ON t.source_system = p.source_system
      AND t.order_id      = p.order_id;

-- Client A: payment embedded in the transaction
INSERT INTO fact_payment
    (payment_key, source_system, payment_id, payment_id_is_surrogate, order_key,
     transaction_key, payment_method, amount, currency, status, status_source, is_refund)
SELECT
    MD5(t.source_system || '|PAY|' || t.transaction_id),
    t.source_system,
    'PAY-' || t.transaction_id                       AS payment_id,
    TRUE                                             AS payment_id_is_surrogate,
    MD5(t.source_system || '|' || t.order_id),
    MD5(t.source_system || '|' || t.transaction_id),
    t.payment_method,
    t.payment_amount,
    t.payment_currency,
    NULL                                             AS status,
    'not delivered: payment is embedded in the transaction and carries no status field'
                                                     AS status_source,
    IFF(t.payment_amount IS NULL, NULL, t.payment_amount < 0)
FROM silver.transactions_clean t
WHERE t.source_system = 'CLIENT_A';

/* ---------------------------------------------------------------------------
   dq_summary
   ------------------------------------------------------------------------ */
TRUNCATE TABLE dq_summary;
INSERT INTO dq_summary (source_system, entity, severity, rule_code, finding_count)
SELECT source_system, entity, severity, rule_code, COUNT(*)
FROM   silver.dq_quarantine
GROUP  BY 1, 2, 3, 4;

SELECT 'dim_source_system' AS table_name, COUNT(*) AS row_count FROM dim_source_system
UNION ALL SELECT 'dim_customer',     COUNT(*) FROM dim_customer
UNION ALL SELECT 'dim_product',      COUNT(*) FROM dim_product
UNION ALL SELECT 'fact_order',       COUNT(*) FROM fact_order
UNION ALL SELECT 'fact_transaction', COUNT(*) FROM fact_transaction
UNION ALL SELECT 'fact_order_item',  COUNT(*) FROM fact_order_item
UNION ALL SELECT 'fact_payment',     COUNT(*) FROM fact_payment
UNION ALL SELECT 'dq_summary',       COUNT(*) FROM dq_summary
ORDER BY 1;
