#!/usr/bin/env bash
# Exports the dashboard's figures from Snowflake into data.json.
#
# Fails loudly. Silencing stderr and ignoring exit codes produced malformed JSON
# that surfaced later as an opaque JSONDecodeError in build.py, with no
# indication of which query had failed.
set -euo pipefail

q() {
    local out
    if ! out=$(snow sql -c nuaav --format json -q "$1"); then
        echo "export failed on query: $1" >&2
        exit 1
    fi
    printf '%s' "$out"
}
echo "{"
echo '"rules":' ; q "SELECT rule_code, severity, entity, COUNT(*) AS findings FROM silver.dq_quarantine GROUP BY rule_code, severity, entity ORDER BY findings DESC;"
echo ',"by_client":' ; q "SELECT source_system, severity, COUNT(*) AS findings FROM silver.dq_quarantine GROUP BY source_system, severity;"
echo ',"coverage":' ; q "SELECT expected_rule, COUNT(*) AS labelled, SUM(IFF(outcome='DETECTED',1,0)) AS detected FROM silver.v_rule_coverage GROUP BY expected_rule ORDER BY labelled DESC;"
echo ',"classification":' ; q "SELECT classification, COUNT(*) AS labels FROM silver.v_label_classification GROUP BY classification;"
echo ',"variance":' ; q "SELECT source_system, COUNT(*) AS txns, SUM(IFF(variance_is_comparable AND ABS(COALESCE(amount_variance,0))>0.01,1,0)) AS with_variance, ROUND(SUM(IFF(variance_is_comparable, ABS(COALESCE(amount_variance,0)), 0)),2) AS total_abs_variance, SUM(IFF(NOT variance_is_comparable,1,0)) AS not_comparable FROM gold.fact_transaction GROUP BY source_system;"
echo ',"client_rows":' ; q "SELECT source_system, COUNT(*) AS transactions FROM gold.fact_transaction GROUP BY source_system;"
echo ',"funnel":' ; q "SELECT stage, row_count FROM silver.v_silver_summary;"
echo ',"gold_counts":' ; q "SELECT 'transactions' AS entity, COUNT(*) AS n FROM gold.fact_transaction UNION ALL SELECT 'items', COUNT(*) FROM gold.fact_order_item UNION ALL SELECT 'customers', COUNT(*) FROM gold.dim_customer UNION ALL SELECT 'products', COUNT(*) FROM gold.dim_product UNION ALL SELECT 'payments', COUNT(*) FROM gold.fact_payment;"
echo ',"master_annotations":' ; q "SELECT entity, source_annotation, COUNT(*) AS records FROM silver.v_master_annotations GROUP BY entity, source_annotation ORDER BY records DESC;"
echo "}"
