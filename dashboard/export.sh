#!/usr/bin/env bash
# Exports the dashboard's figures from Snowflake into data.json.
#
# Writes dashboard/data.json ATOMICALLY: the document is assembled in a temp
# file and moved into place only after every query succeeded.
#
# Failing loudly is not enough on its own, and the previous version proved it.
# It detected a failed query and exited — but the earlier sections had already
# been written to the redirect target, leaving a truncated file that ended
# mid-key. `json.load()` then failed at import time in build.py, so the
# documented rebuild command crashed and index.html could no longer be
# regenerated from the repository. A partial write is the failure mode; refusing
# to write at all is the fix.
#
# The connection name is a parameter, not a constant: nobody but the author
# could run this, and it is the only way to regenerate data.json.
set -euo pipefail

CONN="${1:-${SNOWFLAKE_CONNECTION:-nuaav}}"
OUT="$(cd "$(dirname "$0")" && pwd)/data.json"
# Same directory as the target, so `mv` is a rename within one filesystem and
# therefore actually atomic. A bare mktemp lands in $TMPDIR — on macOS a
# different volume — where mv degrades to copy-then-unlink and an interrupt
# leaves exactly the truncated file this was written to prevent.
TMP="$(mktemp "$(dirname "$OUT")/.data.json.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

q() {
    local out
    if ! out=$(snow sql -c "$CONN" --format json -q "$1"); then
        echo "export failed on query: $1" >&2
        exit 1
    fi
    printf '%s' "$out"
}
# Every query carries a TOTAL ordering. Without a tiebreaker Snowflake is free to
# return tied rows in any order, so two exports of identical data differed only
# in row order — which made the staleness check in verify-everything.sh fire on a
# dashboard that was perfectly current, and would make every git diff noise.
{
echo "{"
echo '"rules":' ; q "SELECT rule_code, severity, entity, COUNT(*) AS findings FROM silver.dq_quarantine GROUP BY rule_code, severity, entity ORDER BY findings DESC, rule_code, severity, entity;"
echo ',"by_client":' ; q "SELECT source_system, severity, COUNT(*) AS findings FROM silver.dq_quarantine GROUP BY source_system, severity ORDER BY source_system, severity;"
# Transactions AND master, one list. Exporting only v_rule_coverage published
# 55/55 while 28 master labels had no rule evaluating them at all.
echo ',"coverage":' ; q "SELECT expected_rule, COUNT(*) AS labelled, SUM(IFF(outcome='DETECTED',1,0)) AS detected FROM (SELECT expected_rule, outcome FROM silver.v_rule_coverage UNION ALL SELECT 'master: ' || entity || ' — ' || label, outcome FROM silver.v_master_rule_coverage) GROUP BY expected_rule ORDER BY labelled DESC, expected_rule;"
echo ',"classification":' ; q "SELECT classification, COUNT(*) AS labels FROM silver.v_label_classification GROUP BY classification ORDER BY classification;"
echo ',"variance":' ; q "SELECT source_system, COUNT(*) AS txns, SUM(IFF(variance_is_comparable AND ABS(COALESCE(amount_variance,0))>0.01,1,0)) AS with_variance, ROUND(SUM(IFF(variance_is_comparable, ABS(COALESCE(amount_variance,0)), 0)),2) AS total_abs_variance, SUM(IFF(NOT variance_is_comparable,1,0)) AS not_comparable FROM gold.fact_transaction GROUP BY source_system ORDER BY source_system;"
echo ',"client_rows":' ; q "SELECT source_system, COUNT(*) AS transactions FROM gold.fact_transaction GROUP BY source_system;"
echo ',"funnel":' ; q "SELECT stage, row_count FROM silver.v_silver_summary ORDER BY stage;"
echo ',"gold_counts":' ; q "SELECT 'transactions' AS entity, COUNT(*) AS n FROM gold.fact_transaction UNION ALL SELECT 'items', COUNT(*) FROM gold.fact_order_item UNION ALL SELECT 'customers', COUNT(*) FROM gold.dim_customer UNION ALL SELECT 'products', COUNT(*) FROM gold.dim_product UNION ALL SELECT 'payments', COUNT(*) FROM gold.fact_payment ORDER BY entity;"
echo ',"master_annotations":' ; q "SELECT entity, source_annotation, COUNT(*) AS records FROM silver.v_master_annotations GROUP BY entity, source_annotation ORDER BY records DESC, entity, source_annotation;"
echo "}"
} > "$TMP"

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP" \
  || { echo "export produced invalid JSON; data.json left untouched" >&2; exit 1; }

mv "$TMP"  "$OUT"
trap - EXIT
echo "wrote $OUT"
