#!/usr/bin/env bash
#
# End-to-end verification. Runs the whole pipeline from scratch and checks every
# claim this repository makes — against the source files, against the warehouse,
# and against its own documentation.
#
#   ./scripts/verify-everything.sh [connection]
#
# Exists because the failure mode in this project was never a crash. It was
# asserting something without checking it: a fix whose text replacement did not
# match, a comment describing data nobody had queried, a figure in the README
# that no longer matched the table it came from. Every one of those passed CI.
#
# Nothing here trusts a previous step. Counts come from `grep` over the delivered
# files, not from the pipeline's own view of them.

set -uo pipefail

CONN="${1:-${SNOWFLAKE_CONNECTION:-nuaav}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Runs a scalar query and echoes the value. Retries once: a transient warehouse
# hiccup returning ERR would otherwise read as a data defect, which is the
# opposite of what this script is for.
qv() {
    local out
    for _ in 1 2; do
        out=$(snow sql -c "$CONN" --format json -q "$1" 2>/dev/null \
              | python3 -c "import json,sys
try:
    d=json.load(sys.stdin); print(list(d[0].values())[0] if d else 'ERR')
except Exception: print('ERR')")
        [ "$out" != "ERR" ] && { printf '%s' "$out"; return; }
        sleep 2
    done
    printf 'ERR'
}

# Asserts a query returns an expected value.
expect() {  # expect <label> <expected> <sql>
    local got; got="$(qv "$3")"
    if [ "$got" = "$2" ]; then ok "$1 = $got"; else bad "$1 → expected $2, got $got"; fi
}

head_ "1 · Source files are exactly as delivered"
if shasum -a 256 -c data/CHECKSUMS.sha256 >/dev/null 2>&1; then
    ok "15 checksums match"
else
    bad "checksums differ from the manifest"
fi
./scripts/check-data-integrity.sh >/dev/null 2>&1 \
    && ok "data/ invariants hold" || bad "data/ invariants FAILED"

head_ "2 · Every SQL script runs clean, in order"
for f in sql/00_setup/*.sql sql/01_bronze/*.sql sql/02_silver/*.sql sql/03_gold/*.sql; do
    if snow sql -c "$CONN" -f "$f" >/dev/null 2>&1; then
        ok "$(basename "$f")"
    else
        bad "$(basename "$f") FAILED"
    fi
done

head_ "3 · Counts match the delivered files, not the pipeline's opinion"
xml_txn=$(grep -h -o '<Transaction>' data/client_a/ClientA_Transactions_*.* | wc -l | tr -d ' ')
xml_item=$(grep -h -o '<Item>' data/client_a/ClientA_Transactions_*.* | wc -l | tr -d ' ')
# grep -o, not -c: -c counts LINES, so two items on one line would make this
# "independent" check silently agree with an undercounting parser.
json_sku=$(grep -o '"sku"' data/client_b/transactions.json | wc -l | tr -d ' ')
expect "Client A transactions (grep: $xml_txn)" "$xml_txn" \
       "SELECT COUNT(*) FROM silver.parsed_client_a_transactions"
expect "Client A line items (grep: $xml_item)" "$xml_item" \
       "SELECT COUNT(*) FROM silver.stg_client_a_transaction_items WHERE raw_payload IS NOT NULL"
expect "Client B line items (grep: $json_sku)" "$json_sku" \
       "SELECT COUNT(*) FROM silver.stg_client_b_transaction_items WHERE raw_payload IS NOT NULL"
# Counted by the id prefix each file's rows actually start with. An earlier
# version excluded blanks and banners instead, which also counted the header
# row — an ambiguous criterion that reported a mismatch where none existed. The
# lesson generalises: a verification is only as good as its own definition.
while IFS='|' read -r file prefix tbl; do
    n=$(grep -c "^$prefix" "$file" | tr -d ' ')
    expect "$(basename "$file") (file: $n data rows)" "$n" \
           "SELECT COUNT(*) FROM bronze.$tbl"
done <<'ROWS'
data/client_a/Customer.csv|CUST-|raw_client_a_customers
data/client_a/Orders.csv|ORD-|raw_client_a_orders
data/client_a/Products.csv|SKU-|raw_client_a_products
data/client_b/Customer.CSV|C-CUST-|raw_client_b_customers
data/client_b/Order.csv|C-ORD-|raw_client_b_orders
data/client_b/Product.csv|C-SKU-|raw_client_b_products
data/client_b/Payments.csv|PAY-C-|raw_client_b_payments
ROWS

head_ "4 · Assertions the pipeline makes about itself"
# Captured once and checked for FAIL, not just counted for PASS. Counting passes
# alone is the asymmetry already fixed for gold below: add a 15th check and
# 14 PASS + 1 FAIL would still have read as green.
bout=$(snow sql -c "$CONN" -f sql/01_bronze/05_validate_bronze.sql 2>&1)
b=$(printf '%s' "$bout" | grep -c '| PASS')
bf=$(printf '%s' "$bout" | grep -c '| FAIL')
[ "$bf" = "0" ] && ok "bronze: $b invariants pass, 0 fail" || bad "bronze: $bf FAILING"
# Captured ONCE. Running it twice and grepping each run separately reported a
# pass count and a fail count from two different executions.
gout=$(snow sql -c "$CONN" -f sql/03_gold/03_validate_canonical.sql 2>&1)
g=$(printf '%s' "$gout" | grep -c '| PASS')
gf=$(printf '%s' "$gout" | grep -c '| FAIL')
[ "$gf" = "0" ] && ok "gold: $g invariants pass, 0 fail" || bad "gold: $gf FAILING"
expect "unclassified ground-truth labels" "0" \
       "SELECT COUNT(*) FROM silver.v_label_classification WHERE classification='UNCLASSIFIED'"
expect "coverage misses" "0" \
       "SELECT COUNT(*) FROM silver.v_rule_coverage WHERE outcome='MISSED'"

head_ "5 · Referential integrity actually holds"
expect "transactions with a dangling order_key" "0" \
       "SELECT COUNT(*) FROM gold.fact_transaction f WHERE f.order_key IS NOT NULL AND NOT EXISTS (SELECT 1 FROM gold.fact_order o WHERE o.order_key=f.order_key)"
expect "line items with a dangling order_key" "0" \
       "SELECT COUNT(*) FROM gold.fact_order_item i WHERE i.order_key IS NOT NULL AND NOT EXISTS (SELECT 1 FROM gold.fact_order o WHERE o.order_key=i.order_key)"
expect "payments with a dangling order_key" "0" \
       "SELECT COUNT(*) FROM gold.fact_payment p WHERE p.order_key IS NOT NULL AND NOT EXISTS (SELECT 1 FROM gold.fact_order o WHERE o.order_key=p.order_key)"
expect "line items not from the surviving copy" "0" \
       "SELECT COUNT(*) FROM silver.transaction_items_clean i WHERE NOT EXISTS (SELECT 1 FROM silver.transactions_clean t WHERE t.source_system=i.source_system AND t.transaction_id=i.transaction_id AND t.document_position=i.document_position)"
expect "duplicate surrogate keys anywhere" "0" \
       "SELECT (SELECT COUNT(*) FROM (SELECT customer_key FROM gold.dim_customer GROUP BY 1 HAVING COUNT(*)>1)) + (SELECT COUNT(*) FROM (SELECT transaction_key FROM gold.fact_transaction GROUP BY 1 HAVING COUNT(*)>1)) + (SELECT COUNT(*) FROM (SELECT order_key FROM gold.fact_order GROUP BY 1 HAVING COUNT(*)>1)) + (SELECT COUNT(*) FROM (SELECT payment_key FROM gold.fact_payment GROUP BY 1 HAVING COUNT(*)>1))"

head_ "6 · The design decisions still hold"
expect "Client A payments with an invented status" "0" \
       "SELECT COUNT(*) FROM gold.fact_payment WHERE source_system='CLIENT_A' AND status IS NOT NULL"
expect "Client B orders with an invented channel" "0" \
       "SELECT COUNT(*) FROM gold.fact_order WHERE source_system='CLIENT_B' AND channel IS NOT NULL"
expect "tiers ranked without keeping the original" "0" \
       "SELECT COUNT(*) FROM gold.dim_customer WHERE tier_rank IS NOT NULL AND tier_raw IS NULL"
# Restricted to surviving copies on BOTH sides. fact_transaction only counts
# rejected lines belonging to a transaction that survived, so comparing against
# every REJECT row in quarantine compares two different populations — it passes
# today only because no discarded copy happens to carry a rejected line.
expect "rejected_line_count vs distinct rejected lines" \
       "$(qv "SELECT COUNT(DISTINCT q.natural_key||'|'||q.document_position||'|'||q.line_number)
              FROM   silver.dq_quarantine AS q
              WHERE  q.entity = 'transaction_item' AND q.severity = 'REJECT'
                AND  EXISTS (SELECT 1 FROM silver.transactions_clean AS t
                             WHERE t.source_system     = q.source_system
                               AND t.transaction_id    = q.natural_key
                               AND t.document_position = q.document_position)")" \
       "SELECT SUM(rejected_line_count) FROM gold.fact_transaction"

head_ "7 · Documentation matches the warehouse"
check_doc() {  # check_doc <file> <regex> <expected value from db>
    if grep -qE "$2" "$1"; then ok "$1 states $3"; else bad "$1 does NOT state $3"; fi
}
inv=$(qv "SELECT COUNT(*) FROM gold.v_canonical_validation")
cov=$(qv "SELECT COUNT(*) FROM silver.v_rule_coverage")
findings=$(qv "SELECT COUNT(*) FROM silver.dq_quarantine")
items=$(qv "SELECT COUNT(*) FROM gold.fact_order_item")
check_doc README.md "$inv / $inv passing"    "$inv invariants"
check_doc README.md "$cov / $cov"            "$cov/$cov coverage"
check_doc README.md "\*\*$findings\*\*"      "$findings findings"
check_doc knowledge-base/README.md "$inv invariants" "$inv invariants"
check_doc knowledge-base/README.md "$cov/$cov"       "$cov/$cov coverage"
# anomaly-handling.md is a named deliverable and was the one document the gate
# did not read — which is where a stale invariant count survived.
check_doc docs/anomaly-handling.md "to $inv"         "$inv invariants"
check_doc docs/anomaly-handling.md "$findings total" "$findings findings"
# The published variance must be the warehouse's current value, and any other
# figure may appear ONLY inside the history table that explains it. The allowed
# list below holds figures used to ILLUSTRATE a specific case in the prose —
# TXN-1001's 97.48/6.48/91.00, C-TXN-3001's 149.99, TXN-1011's 9.99, TXN-1026's
# 19.99. Adding a worked example means adding its numbers here, which is the
# intended friction: an unexplained figure in a deliverable should cost
# something. Banning the
# old number outright was wrong: recording how a figure changed, and why, is the
# point of the anomaly notes — the earlier check could not tell "published as
# current" from "documented as superseded".
var_a=$(qv "SELECT TO_VARCHAR(ROUND(SUM(IFF(variance_is_comparable, ABS(COALESCE(amount_variance,0)), 0)),2)) FROM gold.fact_transaction WHERE source_system='CLIENT_A'")
grep -q "$var_a" docs/anomaly-handling.md \
    && ok "anomaly notes publish the current variance ($var_a)" \
    || bad "anomaly notes do NOT publish the current variance ($var_a)"
# Any variance-shaped number outside the history table must be the current one.
stray=$(awk '/^\| First published/,/^\| \*\*Current\*\*/ {next} /[0-9]+\.[0-9]{2}/ {print}' \
        docs/anomaly-handling.md | grep -oE '[0-9]+\.[0-9]{2}' \
        | grep -vE "^($var_a|53\.94|149\.99|97\.48|91\.00|6\.48|9\.99|19\.99)$" | head -3)
[ -z "$stray" ] \
    && ok "no stray variance figures outside the history table" \
    || bad "unexplained figures outside the history table: $(echo "$stray" | tr '\n' ' ')"

head_ "8 · The dashboard can be rebuilt from the repository"
python3 -c "import json; json.load(open('dashboard/data.json'))" 2>/dev/null \
    && ok "data.json parses" || bad "data.json is NOT valid JSON"
python3 dashboard/build.py >/dev/null 2>&1 \
    && ok "build.py regenerates index.html" || bad "build.py FAILED"

head_ "9 · Lint"
sqlfluff lint sql/ >/dev/null 2>&1 && ok "sqlfluff clean" || bad "sqlfluff violations"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
exit $(( fail > 0 ))
