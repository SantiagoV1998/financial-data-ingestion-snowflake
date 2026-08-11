/* ============================================================================
   02 · SILVER — DATA QUALITY RULES AND QUARANTINE
   ----------------------------------------------------------------------------
   Evaluates every quality rule against the parsed transactions and routes the
   findings to a quarantine table.

   Nothing is deleted. "We dropped 14 rows" is not an answer to an auditor, and
   retaining the payload means a rule can be corrected and the data replayed
   without returning to the source files.

   REJECT versus WARN is a business distinction, not a severity guess:

     REJECT  the record cannot be represented in the canonical model — a
             transaction with no id, a line with no SKU, an amount that is not
             a number. There is nothing to key on or nothing to load.
     WARN    the record loads, but something about it is questionable. A
             negative quantity may be a legitimate return rather than
             corruption, and deciding that is the client's call, not ours.
             Flagging and loading it preserves revenue that silently dropping
             it would destroy.

   A row can violate several rules at once, and all of them are recorded — a
   quarantine that reports only the first reason makes the second invisible.
   ========================================================================= */

USE ROLE ingestion_engineer;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA silver;

CREATE OR REPLACE TABLE dq_quarantine (
    quarantine_id    VARCHAR       DEFAULT UUID_STRING(),
    source_system    VARCHAR       NOT NULL,
    entity           VARCHAR       NOT NULL,  -- transaction | transaction_item
    natural_key      VARCHAR,                 -- transaction id where known
    line_number      NUMBER,
    rule_code        VARCHAR       NOT NULL,
    rule_detail      VARCHAR,
    severity         VARCHAR       NOT NULL,  -- REJECT | WARN
    source_annotation VARCHAR,                -- the provider's own label, if any
    raw_payload      VARIANT,
    detected_at      TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE()
)
COMMENT = 'Every quality finding, with the payload retained so rules can be replayed.';

TRUNCATE TABLE dq_quarantine;

/* ---------------------------------------------------------------------------
   Transaction-level rules
   ----------------------------------------------------------------------------
   Both clients are evaluated by one set of rules, over a union that maps each
   client's shape onto common column names. The rules are about the business
   fact, not about the file format, so duplicating them per client would be two
   copies to keep in step.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_all_transactions AS
SELECT source_system, document_position, transaction_id, order_id,
       order_date, order_date_raw, customer_id,
       -- Client A splits the name; Client B delivers one field. Composed here
       -- only so the "missing customer name" rule can be written once.
       NULLIF(TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')), '') AS customer_name,
       email, payment_method, payment_amount, payment_amount_raw,
       payment_currency, raw_payload
FROM   stg_client_a_transactions
UNION ALL
SELECT source_system, document_position, transaction_id, order_id,
       order_date, order_date_raw, customer_id,
       customer_name,
       email, payment_method, payment_amount, payment_amount_raw,
       -- Client B's JSON payment node carries no currency at all; Client A has
       -- it as an XML attribute. Gold resolves this with a coalesce cascade.
       payment_currency, raw_payload
FROM   stg_client_b_transactions;

CREATE OR REPLACE VIEW v_all_transaction_items AS
SELECT source_system, document_position, transaction_id, line_number,
       sku, description, quantity, quantity_raw, unit_price, unit_price_raw,
       currency, raw_payload
FROM   stg_client_a_transaction_items
UNION ALL
SELECT source_system, document_position, transaction_id, line_number,
       sku, description, quantity, quantity_raw, unit_price, unit_price_raw,
       currency, raw_payload
FROM   stg_client_b_transaction_items;

/* Missing identifiers and fields ------------------------------------------ */
INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction', transaction_id,
       'MISSING_TRANSACTION_ID',
       'Transaction has no id, so it cannot be keyed or deduplicated',
       'REJECT', raw_payload
FROM v_all_transactions WHERE transaction_id IS NULL;

INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction', transaction_id,
       'MISSING_ORDER_ID',
       'Transaction has no order id, so it cannot be attached to an order',
       'REJECT', raw_payload
FROM v_all_transactions WHERE order_id IS NULL;

INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction', transaction_id,
       'MISSING_CUSTOMER_ID',
       'Transaction has no customer id',
       'REJECT', raw_payload
FROM v_all_transactions WHERE customer_id IS NULL;

INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction', transaction_id,
       'MISSING_ORDER_DATE',
       'Order date absent or unparseable: ' || COALESCE(order_date_raw, '(absent)'),
       'WARN', raw_payload
FROM v_all_transactions WHERE order_date IS NULL;

INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction', transaction_id,
       'MISSING_CUSTOMER_NAME', 'Customer name absent', 'WARN', raw_payload
FROM v_all_transactions WHERE customer_name IS NULL;

INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction', transaction_id,
       'MISSING_EMAIL', 'Customer email absent', 'WARN', raw_payload
FROM v_all_transactions WHERE email IS NULL;

INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction', transaction_id,
       'MISSING_PAYMENT_METHOD', 'Payment method absent', 'WARN', raw_payload
FROM v_all_transactions WHERE payment_method IS NULL;

INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction', transaction_id,
       'MISSING_PAYMENT_AMOUNT',
       'Payment amount absent or unparseable: ' || COALESCE(payment_amount_raw, '(absent)'),
       'WARN', raw_payload
FROM v_all_transactions WHERE payment_amount IS NULL;

/* Invalid values ----------------------------------------------------------- */
INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction', transaction_id,
       'INVALID_EMAIL', 'Email does not parse as an address: ' || email,
       'WARN', raw_payload
FROM v_all_transactions
WHERE email IS NOT NULL
  AND NOT REGEXP_LIKE(email, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$');

-- A negative payment is not automatically wrong: refunds and chargebacks are
-- negative by nature, and this is a payments dataset. Flagged, not rejected.
INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction', transaction_id,
       'NEGATIVE_PAYMENT_AMOUNT',
       'Payment amount is negative (' || payment_amount || ') — may be a refund',
       'WARN', raw_payload
FROM v_all_transactions WHERE payment_amount < 0;

/* Duplicates ---------------------------------------------------------------
   Two distinct defects, reported separately. A repeated transaction id is a
   delivery artefact; the same order billed under different transaction ids is
   a business problem. Collapsing both into one rule hides the second.        */
INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction', transaction_id,
       'DUPLICATE_TRANSACTION_ID',
       'Transaction id appears ' || occurrences || ' times in the delivery',
       'WARN', raw_payload
FROM (
    SELECT t.*, COUNT(*) OVER (PARTITION BY source_system, transaction_id) AS occurrences
    FROM   v_all_transactions t
    WHERE  transaction_id IS NOT NULL
)
WHERE occurrences > 1;

INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction', transaction_id,
       'DUPLICATE_ORDER_ID',
       'Order ' || order_id || ' appears under ' || distinct_txns || ' different transaction ids',
       'WARN', raw_payload
FROM (
    SELECT t.*,
           COUNT(DISTINCT transaction_id) OVER (PARTITION BY source_system, order_id) AS distinct_txns
    FROM   v_all_transactions t
    WHERE  order_id IS NOT NULL AND transaction_id IS NOT NULL
)
WHERE distinct_txns > 1;

-- Same customer appearing under several transactions is normal; the provider's
-- label "duplicate customer" points at something narrower — the customer master
-- carrying the same id twice, so any join against it multiplies. This rule
-- exists because the ground-truth comparison in 05 showed six labelled
-- anomalies with no rule behind them.
INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
SELECT t.source_system, 'transaction', t.transaction_id,
       'DUPLICATE_CUSTOMER',
       'Customer ' || t.customer_id || ' appears ' || d.occurrences ||
       ' times in the customer master, so any join against it multiplies rows',
       'WARN', t.raw_payload
FROM   v_all_transactions t
JOIN (
    SELECT source_system, customer_id, COUNT(*) AS occurrences
    FROM  (SELECT source_system, customer_id FROM stg_client_a_customers
           UNION ALL
           SELECT source_system, customer_id FROM stg_client_b_customers)
    WHERE customer_id IS NOT NULL
    GROUP BY 1, 2
    HAVING COUNT(*) > 1
) d
  ON  d.source_system = t.source_system
  AND d.customer_id   = t.customer_id;

/* Referential integrity against master data -------------------------------- */
INSERT INTO dq_quarantine
    (source_system, entity, natural_key, rule_code, rule_detail, severity, raw_payload)
-- NOT EXISTS, not a LEFT JOIN. The customer master itself contains duplicates
-- (CUST-A-0001 appears twice), so a join multiplies every matching transaction
-- and the finding counts come out inflated — 51 rows for 46 transactions.
-- Existence is the question being asked, so ask it directly.
SELECT t.source_system, 'transaction', t.transaction_id,
       'ORPHAN_CUSTOMER',
       'Customer ' || t.customer_id || ' has no master record',
       'WARN', t.raw_payload
FROM   v_all_transactions t
WHERE  t.customer_id IS NOT NULL
  AND  NOT EXISTS (
        SELECT 1
        FROM  (SELECT source_system, customer_id FROM stg_client_a_customers
               UNION ALL
               SELECT source_system, customer_id FROM stg_client_b_customers) c
        WHERE c.source_system = t.source_system
          AND c.customer_id   = t.customer_id
      );

/* ---------------------------------------------------------------------------
   Line-item rules
   ------------------------------------------------------------------------ */
INSERT INTO dq_quarantine
    (source_system, entity, natural_key, line_number, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction_item', transaction_id, line_number,
       'MISSING_SKU', 'Line has no SKU, so it cannot be matched to a product',
       'REJECT', raw_payload
FROM v_all_transaction_items
WHERE raw_payload IS NOT NULL AND sku IS NULL;

INSERT INTO dq_quarantine
    (source_system, entity, natural_key, line_number, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction_item', transaction_id, line_number,
       'MISSING_QUANTITY',
       'Quantity absent or unparseable: ' || COALESCE(quantity_raw, '(absent)'),
       'REJECT', raw_payload
FROM v_all_transaction_items
WHERE raw_payload IS NOT NULL AND quantity IS NULL;

INSERT INTO dq_quarantine
    (source_system, entity, natural_key, line_number, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction_item', transaction_id, line_number,
       'MISSING_DESCRIPTION', 'Line has no description', 'WARN', raw_payload
FROM v_all_transaction_items
WHERE raw_payload IS NOT NULL AND description IS NULL;

-- Negative quantity: a return line, or corruption. The client decides.
INSERT INTO dq_quarantine
    (source_system, entity, natural_key, line_number, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction_item', transaction_id, line_number,
       'NEGATIVE_QUANTITY',
       'Quantity is ' || quantity || ' — may be a return line',
       'WARN', raw_payload
FROM v_all_transaction_items WHERE quantity < 0;

-- A negative unit price has no comparable reading. Prices are not signed.
INSERT INTO dq_quarantine
    (source_system, entity, natural_key, line_number, rule_code, rule_detail, severity, raw_payload)
SELECT source_system, 'transaction_item', transaction_id, line_number,
       'NEGATIVE_UNIT_PRICE',
       'Unit price is ' || unit_price || ', which no reading makes valid',
       'REJECT', raw_payload
FROM v_all_transaction_items WHERE unit_price < 0;

INSERT INTO dq_quarantine
    (source_system, entity, natural_key, line_number, rule_code, rule_detail, severity, raw_payload)
-- NOT EXISTS for the same reason as ORPHAN_CUSTOMER above: the product master
-- also carries duplicates, and a join would multiply the findings.
SELECT i.source_system, 'transaction_item', i.transaction_id, i.line_number,
       'ORPHAN_SKU',
       'SKU ' || i.sku || ' has no product master record',
       'WARN', i.raw_payload
FROM   v_all_transaction_items i
WHERE  i.sku IS NOT NULL
  AND  NOT EXISTS (
        SELECT 1
        FROM  (SELECT source_system, sku FROM stg_client_a_products
               UNION ALL
               SELECT source_system, sku FROM stg_client_b_products) p
        WHERE p.source_system = i.source_system
          AND p.sku           = i.sku
      );

/* ---------------------------------------------------------------------------
   Summary
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_dq_summary AS
SELECT source_system, entity, severity, rule_code, COUNT(*) AS findings
FROM   dq_quarantine
GROUP  BY 1, 2, 3, 4;

SELECT severity, rule_code, entity, SUM(findings) AS findings
FROM   v_dq_summary
GROUP  BY 1, 2, 3
ORDER  BY severity, findings DESC;
