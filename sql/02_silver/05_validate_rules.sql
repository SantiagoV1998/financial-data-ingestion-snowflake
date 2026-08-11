/* ============================================================================
   02 · SILVER — VALIDATE THE RULES AGAINST THE PROVIDER'S OWN LABELS
   ----------------------------------------------------------------------------
   The delivery labels its own anomalies. Every transaction in the XML is
   preceded by a comment naming what is wrong with it:

       <!-- TXN-1008: missing order date, negative quantity -->
       <!-- TXN-1017: invalid SKU, negative amount -->

   and the CSVs carry the same thing inline (`<-- duplicate`).

   That makes them ground truth, and it turns "I wrote some quality rules" into
   something measurable: for each labelled anomaly, did the rules find it?

   Two failure directions, both worth knowing:

     MISSED    the provider says the row has a defect and no rule fired. A gap.
     UNLABELLED  a rule fired on a row the provider did not label. Not
                 necessarily wrong — the labels are illustrative, not exhaustive,
                 and derived defects (an orphan customer) are real without being
                 annotated — but worth inspecting rather than assuming.

   The comments are read back out of bronze.raw_text_lines. The parser discards
   them (they are XML comment nodes, filtered out when extracting Transaction
   elements), but bronze kept every line verbatim, which is precisely the
   property that makes this possible.
   ========================================================================= */

USE ROLE ingestion_engineer;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA silver;

/* ---------------------------------------------------------------------------
   Ground truth, recovered from the raw lines
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_ground_truth AS
WITH xml_comments AS (
    SELECT
        REGEXP_SUBSTR(line_text, '(TXN-[0-9]+)', 1, 1, 'e', 1)        AS transaction_id,
        LOWER(TRIM(REGEXP_SUBSTR(line_text, '<!--\\s*(.*?)\\s*-->', 1, 1, 'e', 1)))
                                                                     AS label
    FROM   bronze.raw_text_lines
    WHERE  source_file ILIKE '%ClientA_Transactions%'
      AND  line_text LIKE '%<!--%'
      AND  line_text LIKE '%TXN-%'
)
SELECT 'CLIENT_A' AS source_system, transaction_id, label
FROM   xml_comments
WHERE  transaction_id IS NOT NULL

UNION ALL

/* Client B carries the same labels as // comments inside the JSON. They are not
   always on the line naming the transaction — `"qty": -3,   // negative quantity`
   sits several lines below its id — so each comment is attributed to the most
   recent id above it. Coverage was previously measured on Client A alone while
   being reported as a delivery-wide figure. */
SELECT 'CLIENT_B', jb.transaction_id, jb.label
FROM (
    SELECT
        LAST_VALUE(REGEXP_SUBSTR(line_text, '(C-TXN-[0-9]+)', 1, 1, 'e', 1)) IGNORE NULLS
            OVER (ORDER BY file_row_number
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS transaction_id,
        LOWER(TRIM(REGEXP_SUBSTR(line_text, '//\\s*(.*)$', 1, 1, 'e', 1)))  AS label
    FROM   bronze.raw_text_lines
    WHERE  source_file ILIKE '%transactions.json'
) AS jb
WHERE jb.transaction_id IS NOT NULL
  AND jb.label IS NOT NULL
  -- The JSON ends with a block comment describing records that were never
  -- delivered ("Continue pattern up to C-TXN-3120: 100 valid records..."). Those
  -- lines attribute to an id that does not exist in the data, so existence is
  -- the filter — more robust than matching the shape of the text.
  AND EXISTS (SELECT 1 FROM parsed_client_b_transactions AS pb
              WHERE pb.transaction_json:id::VARCHAR = jb.transaction_id);

/* ---------------------------------------------------------------------------
   The CSV side of the same ground truth
   ----------------------------------------------------------------------------
   The 28 inline annotations extracted in 03_extract_master_data.sql belong to
   master records, not to transactions, so they cannot be matched against
   transaction-level rules. They are surfaced here as their own report: the
   provider's account of what is wrong with the master data, beside what the
   pipeline found in it.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_master_annotations AS
SELECT 'customers' AS entity, source_system, customer_id AS natural_key, source_annotation
FROM   stg_client_a_customers WHERE source_annotation IS NOT NULL
UNION ALL
SELECT 'customers', source_system, customer_id, source_annotation
FROM   stg_client_b_customers WHERE source_annotation IS NOT NULL
UNION ALL
SELECT 'orders', source_system, order_id, source_annotation
FROM   stg_client_a_orders WHERE source_annotation IS NOT NULL
UNION ALL
SELECT 'orders', source_system, order_id, source_annotation
FROM   stg_client_b_orders WHERE source_annotation IS NOT NULL
UNION ALL
SELECT 'products', source_system, sku, source_annotation
FROM   stg_client_a_products WHERE source_annotation IS NOT NULL
UNION ALL
SELECT 'products', source_system, sku, source_annotation
FROM   stg_client_b_products WHERE source_annotation IS NOT NULL
UNION ALL
SELECT 'payments', source_system, payment_id, source_annotation
FROM   stg_client_b_payments WHERE source_annotation IS NOT NULL;

SELECT entity, source_annotation, COUNT(*) AS records
FROM   v_master_annotations
GROUP  BY entity, source_annotation
ORDER  BY records DESC, entity ASC;

/* ---------------------------------------------------------------------------
   Which rule each label should have triggered
   ----------------------------------------------------------------------------
   Deliberately literal and ordered most-specific-first. An earlier version
   matched the bare word "duplicate", which sent "duplicate customer" and
   "duplicate order id" to DUPLICATE_TRANSACTION_ID and reported six false
   misses — a measurement defect that looked like a coverage gap.

   A label may legitimately be satisfied by more than one rule. "invalid sku"
   is the clear case: TXN-1017 carries no SKU at all, so it surfaces as
   MISSING_SKU rather than ORPHAN_SKU. Both are correct detections of the same
   labelled defect, so the expectation lists alternatives.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_label_expectations AS
SELECT g.source_system, g.transaction_id, g.label, e.phrase, e.acceptable_rules
FROM   v_ground_truth AS g,
LATERAL (
    SELECT m.phrase, m.acceptable_rules FROM (
        SELECT
            'duplicate customer'      AS phrase,
            ARRAY_CONSTRUCT('DUPLICATE_CUSTOMER')                     AS acceptable_rules
        UNION ALL
        SELECT 'duplicate order id',      ARRAY_CONSTRUCT('DUPLICATE_ORDER_ID')
        UNION ALL
        SELECT 'duplicate transaction id',ARRAY_CONSTRUCT('DUPLICATE_TRANSACTION_ID')
        UNION ALL
        -- Two comment formats in the same file: "TXN-1001: duplicate transaction id"
        -- and the bare "TXN-1001 duplicate". Both mean the same thing.
        SELECT 'duplicate',                ARRAY_CONSTRUCT('DUPLICATE_TRANSACTION_ID')
        UNION ALL
        SELECT 'missing transactionid',   ARRAY_CONSTRUCT('MISSING_TRANSACTION_ID')
        UNION ALL
        SELECT 'missing order id',        ARRAY_CONSTRUCT('MISSING_ORDER_ID')
        UNION ALL
        SELECT 'missing customer id',     ARRAY_CONSTRUCT('MISSING_CUSTOMER_ID')
        UNION ALL
        SELECT 'missing order date',      ARRAY_CONSTRUCT('MISSING_ORDER_DATE')
        UNION ALL
        -- The JSON writes it shorter than the XML does.
        SELECT 'missing date',            ARRAY_CONSTRUCT('MISSING_ORDER_DATE')
        UNION ALL
        SELECT 'missing customer name',   ARRAY_CONSTRUCT('MISSING_CUSTOMER_NAME')
        UNION ALL
        SELECT 'missing customer email',  ARRAY_CONSTRUCT('MISSING_EMAIL')
        UNION ALL
        SELECT 'missing email',           ARRAY_CONSTRUCT('MISSING_EMAIL')
        UNION ALL
        SELECT 'missing payment method',  ARRAY_CONSTRUCT('MISSING_PAYMENT_METHOD')
        UNION ALL
        SELECT 'missing payment amount',  ARRAY_CONSTRUCT('MISSING_PAYMENT_AMOUNT')
        UNION ALL
        SELECT 'missing sku',             ARRAY_CONSTRUCT('MISSING_SKU')
        UNION ALL
        SELECT 'missing quantity',        ARRAY_CONSTRUCT('MISSING_QUANTITY')
        UNION ALL
        SELECT 'missing item description',ARRAY_CONSTRUCT('MISSING_DESCRIPTION')
        UNION ALL
        SELECT 'invalid email',           ARRAY_CONSTRUCT('INVALID_EMAIL')
        UNION ALL
        SELECT 'invalid sku',             ARRAY_CONSTRUCT('ORPHAN_SKU', 'MISSING_SKU')
        UNION ALL
        SELECT 'invalid customer',        ARRAY_CONSTRUCT('ORPHAN_CUSTOMER', 'MISSING_CUSTOMER_ID')
        UNION ALL
        SELECT 'negative quantity',       ARRAY_CONSTRUCT('NEGATIVE_QUANTITY')
        UNION ALL
        SELECT 'negative unit price',     ARRAY_CONSTRUCT('NEGATIVE_UNIT_PRICE')
        UNION ALL
        SELECT 'negative price',          ARRAY_CONSTRUCT('NEGATIVE_UNIT_PRICE')
        UNION ALL
        SELECT 'negative amount',         ARRAY_CONSTRUCT('NEGATIVE_PAYMENT_AMOUNT')
    ) AS m
    WHERE CONTAINS(g.label, m.phrase)
      -- "duplicate customer" also contains "duplicate"; the specific reading wins.
      -- Specific readings win: "duplicate customer" contains "duplicate" too.
      -- Only the bare word is demoted. Suppressing the explicit
      -- "duplicate transaction id" phrase too would silently drop a legitimate
      -- expectation from a label naming several duplicate kinds at once, and
      -- understate the coverage denominator this file reports.
      AND NOT (m.phrase = 'duplicate'
               AND (CONTAINS(g.label, 'duplicate customer')
                    OR CONTAINS(g.label, 'duplicate order id')
                    OR CONTAINS(g.label, 'duplicate transaction id')))
      AND NOT (m.phrase = 'duplicate' AND CONTAINS(g.label, 'duplicate transaction id'))
) AS e;

/* ---------------------------------------------------------------------------
   Coverage
   ----------------------------------------------------------------------------
   A transaction whose id is missing cannot be matched on natural_key, since the
   quarantine row records the id it does not have. Those are matched on the rule
   alone — the label says the id is absent, and the rule that fires for exactly
   that condition did fire.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_rule_coverage AS
SELECT
    x.transaction_id,
    x.label,
    ARRAY_TO_STRING(x.acceptable_rules, ' or ') AS expected_rule,
    IFF(EXISTS (
            SELECT 1 FROM dq_quarantine AS q
            WHERE q.source_system = x.source_system
              AND ARRAY_CONTAINS(q.rule_code::VARIANT, x.acceptable_rules)
              AND (q.natural_key = x.transaction_id
                   OR (q.natural_key IS NULL AND q.rule_code = 'MISSING_TRANSACTION_ID'))
        ), 'DETECTED', 'MISSED') AS outcome
FROM v_label_expectations AS x;

SELECT expected_rule,
       COUNT(*)                             AS labelled,
       SUM(IFF(outcome = 'DETECTED', 1, 0)) AS detected,
       SUM(IFF(outcome = 'MISSED', 1, 0))   AS missed
FROM   v_rule_coverage
GROUP  BY expected_rule
ORDER  BY missed DESC, labelled DESC;

SELECT 'TOTAL' AS scope,
       COUNT(*)                             AS labelled_anomalies,
       SUM(IFF(outcome = 'DETECTED', 1, 0)) AS detected,
       ROUND(100.0 * SUM(IFF(outcome = 'DETECTED', 1, 0)) / NULLIF(COUNT(*), 0), 1) AS pct
FROM v_rule_coverage;

/* ---------------------------------------------------------------------------
   Labels deliberately out of scope
   ----------------------------------------------------------------------------
   Not every label describes a data-quality defect. "extra nested <Warranty>"
   and "invalid fields" describe SCHEMA variation — the records are valid, they
   simply carry elements the canonical model does not read. That is handled by
   design rather than by a rule: unselected paths are ignored during extraction
   and survive whole in raw_payload, so nothing is lost and nothing needs
   flagging.

   They are enumerated rather than quietly excluded. A coverage figure that
   silently drops the labels it cannot satisfy is worthless, so every ground
   truth label lands in exactly one of three buckets and the totals must
   reconcile.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_label_classification AS
SELECT g.transaction_id, g.label,
       CASE
         WHEN EXISTS (SELECT 1 FROM v_label_expectations AS e
                      WHERE e.transaction_id = g.transaction_id AND e.label = g.label)
              THEN 'MAPPED_TO_RULE'
         WHEN CONTAINS(g.label, 'extra nested') OR CONTAINS(g.label, 'invalid fields')
              THEN 'SCHEMA_VARIATION_BY_DESIGN'
         ELSE 'UNCLASSIFIED'
       END AS classification
FROM v_ground_truth AS g;

SELECT classification, COUNT(*) AS labels
FROM   v_label_classification
GROUP  BY classification ORDER BY labels DESC;
