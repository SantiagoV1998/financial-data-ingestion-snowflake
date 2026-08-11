/* ============================================================================
   03 · GOLD — CANONICAL MODEL VALIDATION
   ----------------------------------------------------------------------------
   Snowflake does not enforce PRIMARY KEY or FOREIGN KEY, so the constraints
   declared in the DDL document intent and nothing more. What actually holds has
   to be asserted, and this script does the asserting.

   It raises on failure rather than printing a report nobody reads.
   ========================================================================= */

USE ROLE ingestion_engineer;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA gold;

CREATE OR REPLACE VIEW v_canonical_validation AS

/* Surrogate keys are unique -------------------------------------------------
   The whole model rests on this. Silver deduplicates, and if that failed the
   damage surfaces here rather than in a report six queries downstream.       */
SELECT 'dim_customer_key_unique' AS check_name, 0 AS expected,
       (SELECT COUNT(*) FROM (SELECT customer_key FROM dim_customer
                              GROUP BY 1 HAVING COUNT(*) > 1) AS dupes) AS actual
UNION ALL
SELECT 'dim_product_key_unique', 0,
       (SELECT COUNT(*) FROM (SELECT product_key FROM dim_product
                              GROUP BY 1 HAVING COUNT(*) > 1) AS dupes)
UNION ALL
SELECT 'fact_transaction_key_unique', 0,
       (SELECT COUNT(*) FROM (SELECT transaction_key FROM fact_transaction
                              GROUP BY 1 HAVING COUNT(*) > 1) AS dupes)
UNION ALL
SELECT 'fact_order_item_key_unique', 0,
       (SELECT COUNT(*) FROM (SELECT order_item_key FROM fact_order_item
                              GROUP BY 1 HAVING COUNT(*) > 1) AS dupes)
UNION ALL
-- fact_order was the one primary key with no uniqueness assertion, while three
-- tables resolve foreign keys against it: a duplicate would fan out
-- fact_transaction, fact_order_item and fact_payment simultaneously.
SELECT 'fact_order_key_unique', 0,
       (SELECT COUNT(*) FROM (SELECT order_key FROM fact_order
                              GROUP BY 1 HAVING COUNT(*) > 1) AS dupes)
UNION ALL
SELECT 'fact_payment_key_unique', 0,
       (SELECT COUNT(*) FROM (SELECT payment_key FROM fact_payment
                              GROUP BY 1 HAVING COUNT(*) > 1) AS dupes)

/* Referential integrity -----------------------------------------------------
   A populated foreign key must resolve. NULL is permitted and meaningful — an
   order whose customer has no master record keeps a NULL customer_key, and the
   orphan is reported in quarantine rather than papered over with a fabricated
   dimension row. What must never happen is a key that points at nothing.      */
UNION ALL
SELECT 'fact_order_customer_resolves', 0,
       (SELECT COUNT(*) FROM fact_order AS f
        WHERE f.customer_key IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dim_customer AS d
                          WHERE d.customer_key = f.customer_key))
UNION ALL
SELECT 'fact_transaction_customer_resolves', 0,
       (SELECT COUNT(*) FROM fact_transaction AS f
        WHERE f.customer_key IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dim_customer AS d
                          WHERE d.customer_key = f.customer_key))
UNION ALL
SELECT 'fact_order_item_transaction_resolves', 0,
       (SELECT COUNT(*) FROM fact_order_item AS i
        WHERE i.transaction_key IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM fact_transaction AS t
                          WHERE t.transaction_key = i.transaction_key))
UNION ALL
-- These two were absent, and their absence hid a real break: order_key was
-- derived from the id unconditionally, so 19 transactions and 15 line items
-- carried foreign keys pointing at fact_order rows that were never created.
-- The header above says "what must never happen is a key that points at
-- nothing" — nothing was checking.
SELECT 'fact_transaction_order_resolves', 0,
       (SELECT COUNT(*) FROM fact_transaction AS f
        WHERE f.order_key IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM fact_order AS o
                          WHERE o.order_key = f.order_key))
UNION ALL
SELECT 'fact_order_item_order_resolves', 0,
       (SELECT COUNT(*) FROM fact_order_item AS i
        WHERE i.order_key IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM fact_order AS o
                          WHERE o.order_key = i.order_key))
UNION ALL
-- Every line must belong to the copy of the transaction that survived
-- deduplication. Joining without document_position let lines from a discarded
-- copy attach to the surviving one and invent a 91.00 variance on TXN-1001.
SELECT 'items_belong_to_surviving_copy', 0,
       (SELECT COUNT(*) FROM silver.transaction_items_clean AS i
        WHERE NOT EXISTS (SELECT 1 FROM silver.transactions_clean AS t
                          WHERE t.source_system     = i.source_system
                            AND t.transaction_id    = i.transaction_id
                            AND t.document_position = i.document_position))
UNION ALL
-- fact_payment had only a uniqueness check, which is why its order_key kept
-- dangling after the same defect was fixed for transactions and line items.
SELECT 'fact_payment_order_resolves', 0,
       (SELECT COUNT(*) FROM fact_payment AS p
        WHERE p.order_key IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM fact_order AS o
                          WHERE o.order_key = p.order_key))
UNION ALL
SELECT 'fact_payment_transaction_resolves', 0,
       (SELECT COUNT(*) FROM fact_payment AS p
        WHERE p.transaction_key IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM fact_transaction AS f
                          WHERE f.transaction_key = p.transaction_key))
UNION ALL
-- Deduplication must keep the copy carrying the most lines. Keeping the last
-- one dropped the only real line of C-TXN-3001 and invented a 149.99 variance.
-- Excludes transactions whose lines were REJECTed: those legitimately have no
-- lines in gold, which rejected_line_count records. What this catches is a
-- transaction that HAD readable lines and lost them to deduplication.
SELECT 'no_transaction_lost_its_only_lines', 0,
       (SELECT COUNT(*) FROM fact_transaction AS f
        WHERE f.line_count = 0
          AND COALESCE(f.rejected_line_count, 0) = 0
          AND EXISTS (SELECT 1 FROM silver.v_all_transaction_items AS i
                      WHERE i.source_system  = f.source_system
                        AND i.transaction_id = f.transaction_id
                        AND i.raw_payload IS NOT NULL))
UNION ALL
-- A NULL variance excluded the worst reconciliation cases from the figures.
SELECT 'variance_never_null_when_paid', 0,
       (SELECT COUNT(*) FROM fact_transaction
        WHERE payment_amount IS NOT NULL AND amount_variance IS NULL)
UNION ALL
SELECT 'fact_order_item_product_resolves', 0,
       (SELECT COUNT(*) FROM fact_order_item AS i
        WHERE i.product_key IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dim_product AS p
                          WHERE p.product_key = i.product_key))

/* Nothing was lost or invented in the transformation ------------------------ */
UNION ALL
SELECT 'transactions_match_silver',
       (SELECT COUNT(*) FROM silver.transactions_clean),
       (SELECT COUNT(*) FROM fact_transaction)
UNION ALL
SELECT 'items_match_silver',
       (SELECT COUNT(*) FROM silver.transaction_items_clean),
       (SELECT COUNT(*) FROM fact_order_item)
UNION ALL
SELECT 'customers_match_silver',
       (SELECT COUNT(*) FROM silver.customers_clean),
       (SELECT COUNT(*) FROM dim_customer)

/* Every client appears, and every row belongs to a known client -------------- */
UNION ALL
SELECT 'both_clients_present', 2,
       (SELECT COUNT(DISTINCT source_system) FROM fact_transaction)
UNION ALL
SELECT 'no_unknown_source_system', 0,
       (SELECT COUNT(*) FROM fact_transaction AS f
        WHERE NOT EXISTS (SELECT 1 FROM dim_source_system AS s
                          WHERE s.source_system = f.source_system))

/* Conflict resolutions actually held ----------------------------------------
   These assert the modelling decisions, not the mechanics. If someone later
   "simplifies" the tier mapping into an equivalence, or defaults a missing
   status to UNKNOWN, these fail.                                              */
UNION ALL
-- Every customer with a delivered tier keeps the original text verbatim.
-- The inverse direction, which was the one missing: a tier the delivery carries
-- but the CASE does not map stays NULL and disappears from any ranked query.
-- That is how PLATINUM — above GOLD — went unranked while GOLD read as the top.
-- UNKNOWN is exempt: it is the absence of a tier, not an unmapped one.
SELECT 'every_delivered_tier_is_ranked', 0,
       (SELECT COUNT(*) FROM dim_customer
        WHERE tier_raw IS NOT NULL
          AND UPPER(tier_raw) <> 'UNKNOWN'
          AND tier_rank IS NULL)
UNION ALL
SELECT 'tier_raw_preserved', 0,
       (SELECT COUNT(*) FROM dim_customer AS c
        WHERE c.tier_rank IS NOT NULL AND c.tier_raw IS NULL)
UNION ALL
-- Client A payments must carry no status: the source does not deliver one.
SELECT 'client_a_payment_status_not_invented', 0,
       (SELECT COUNT(*) FROM fact_payment
        WHERE source_system = 'CLIENT_A' AND status IS NOT NULL)
UNION ALL
-- ...and must be flagged as surrogate-keyed.
SELECT 'client_a_payment_ids_flagged_surrogate', 0,
       (SELECT COUNT(*) FROM fact_payment
        WHERE source_system = 'CLIENT_A' AND payment_id_is_surrogate = FALSE)
UNION ALL
-- Client B payments are real, never surrogate.
SELECT 'client_b_payment_ids_not_surrogate', 0,
       (SELECT COUNT(*) FROM fact_payment
        WHERE source_system = 'CLIENT_B' AND payment_id_is_surrogate = TRUE)
UNION ALL
-- Client B delivers no channel; inventing one would hide that fact.
SELECT 'client_b_channel_not_invented', 0,
       (SELECT COUNT(*) FROM fact_order
        WHERE source_system = 'CLIENT_B' AND channel IS NOT NULL)
UNION ALL
-- Negative quantities survive as flagged return lines rather than being dropped.
SELECT 'return_lines_retained',
       (SELECT COUNT(*) FROM silver.transaction_items_clean WHERE quantity < 0),
       (SELECT COUNT(*) FROM fact_order_item WHERE is_return_line = TRUE)
UNION ALL
-- A transaction whose lines span several currencies must never be reported as
-- having a comparable variance: gross_line_amount would be a sum across units.
-- Zero in this delivery because every line is USD, which is exactly why the
-- check has to exist rather than the property be assumed.
-- Recomputed from fact_order_item with the SAME null-aware measure the flag
-- uses. Comparing against COUNT(DISTINCT currency) > 1 alone restated the flag's
-- own definition, so the answer was 0 by construction rather than by evidence —
-- a check that cannot fail is not a check.
SELECT 'no_comparable_variance_with_unclear_currency',
       0,
       (SELECT COUNT(*)
        FROM   fact_transaction AS t
        WHERE  t.variance_is_comparable = TRUE
          AND  EXISTS (SELECT 1
                       FROM   fact_order_item AS i
                       WHERE  i.transaction_key = t.transaction_key
                       HAVING COUNT(DISTINCT i.currency) > 1
                           OR COUNT(*) <> COUNT(i.currency)))
UNION ALL
-- Master rows leave the pipeline only through a recorded finding. Silver's
-- reconciliation raises on mismatch; this restates it as a canonical invariant
-- so the gold gate cannot pass while master data was lost upstream.
SELECT 'master_rows_discarded_without_record',
       0,
       (SELECT COUNT(*) FROM silver.v_master_reconciliation
        WHERE discarded_actual <> discarded_and_recorded)
UNION ALL
-- Coverage is published over one denominator. If master labels stop being
-- evaluated they become MISSED here rather than vanishing from the total.
SELECT 'every_master_label_detected',
       (SELECT COUNT(*) FROM silver.v_master_rule_coverage),
       (SELECT COUNT(*) FROM silver.v_master_rule_coverage WHERE outcome = 'DETECTED')
UNION ALL
-- Both sides of the check above come from the same view, so if the annotations
-- ever stop being extracted it reads 0 = 0 and PASSES while the master half of
-- the published 83/83 has quietly stopped being evaluated. This is the floor:
-- the delivery carries 28 inline annotations, and fewer means the extraction
-- regressed, not that the data improved.
SELECT 'master_labels_are_present',
       28,
       (SELECT COUNT(*) FROM silver.v_master_annotations)
UNION ALL
-- Same asymmetry on the transaction side, which had no canonical check at all:
-- a label the expectation list does not recognise drops out of the LATERAL join
-- and out of the denominator, leaving coverage at 100%.
SELECT 'every_transaction_label_detected',
       (SELECT COUNT(*) FROM silver.v_rule_coverage),
       (SELECT COUNT(*) FROM silver.v_rule_coverage WHERE outcome = 'DETECTED')
UNION ALL
SELECT 'transaction_labels_are_present',
       55,
       (SELECT COUNT(*) FROM silver.v_rule_coverage)
UNION ALL
SELECT 'no_unclassified_labels',
       0,
       (SELECT COUNT(*) FROM silver.v_label_classification
        WHERE classification = 'UNCLASSIFIED');

SELECT check_name, expected, actual,
       IFF(actual = expected, 'PASS', 'FAIL') AS status
FROM   v_canonical_validation
-- AM06 has no satisfiable form on the next line: status is an alias this SELECT
-- defines over a view of UNION ALL branches, and ordering by position is
-- rejected because the SELECT names its columns. Silenced on this line only —
-- excluding the rule repo-wide would disarm it everywhere else, and what it
-- catches there is worth keeping: a GROUP BY or ORDER BY that MIXES positional
-- and named references (GROUP BY 1, tier_raw), where reordering the SELECT
-- moves the 1 and leaves the name, silently regrouping the result. Verified by
-- probe: pure positional does not fire, mixed does.
ORDER  BY status, check_name;  -- noqa: AM06

EXECUTE IMMEDIATE $$
DECLARE
    failed INTEGER;
    canonical_validation_failed EXCEPTION (-20003, 'Canonical model validation failed');
BEGIN
    SELECT COUNT(*) INTO :failed FROM v_canonical_validation WHERE actual <> expected;
    IF (failed > 0) THEN
        RAISE canonical_validation_failed;
    END IF;
    RETURN 'Canonical model validated';
END;
$$;
