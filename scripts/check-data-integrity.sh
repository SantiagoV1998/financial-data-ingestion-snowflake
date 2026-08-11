#!/usr/bin/env bash
#
# Invariants for data/. Runs identically in CI and locally — one source of truth,
# so a check cannot pass in one place and fail in the other.
#
#   ./scripts/check-data-integrity.sh
#
# SCOPE
#
# This script answers one question: can a delivered file be silently lost?
#
# Both the checksum manifest and the coverage comparison derive from the git
# index, so a file that `git add` skips is invisible to every other gate — it
# never reaches Snowflake while CI reports green and the documentation asserts
# the delivery is complete. That is the failure this guards against.
#
# It does NOT try to identify secrets. An earlier version did, by matching
# filenames, and it could not be made to work: too broad and it swallowed
# deliveries whole (an entire bundle under data/tokens/ disappeared with every
# check green), too narrow and API_KEY.csv sailed past. Filename guessing has no
# floor. Secret detection is GitHub secret scanning with push protection, which
# recognises credential material by content and blocks the push.

set -uo pipefail

failed=0
checks=0

fail() { echo "::error::$1"; echo "  FAIL  $1"; failed=1; }
pass() { checks=$((checks + 1)); }

# Two ignorecase settings on purpose.
#
# Visibility is asserted under the PERMISSIVE setting (true, the macOS default),
# because a path that git would drop on a case-insensitive checkout must be
# reported as at-risk. Asserting under false would certify a path safe that real
# `git add` silently skips on the platform the docs tell people to use.
visible_check() { git -c core.ignorecase=true check-ignore --no-index -q "$1"; }

must_be_visible() {
    if visible_check "$1"; then
        fail "$2: $1 is ignored, so a delivery with that path would be invisible to every other check"
    else
        pass
    fi
}

echo "== 1. Every tracked delivery stays visible =="
# Real paths, not synthetic ones: a directory-scoped pattern such as
# data/client_a/*.xml shadows the seven fragments while every synthetic probe
# stays green.
tracked=$(git -c core.quotePath=false ls-files data | grep -vx 'data/CHECKSUMS\.sha256')
if [ -z "$tracked" ]; then
    fail "no tracked files under data/ — refusing to report success having verified nothing"
else
    while IFS= read -r f; do
        must_be_visible "$f" "tracked delivery"
    done <<< "$tracked"
fi

echo "== 2. Any plausible delivery path stays visible =="
# Nested paths matter most: git does not descend into an excluded directory, so
# a re-inclusion cannot rescue a file inside one. Business vocabulary matters
# too — this is a payments repository, where "token" and "password" name
# records, not secrets.
for p in \
    Orders.csv Orders.CSV Transactions.xml transactions.json Transactions.txt \
    tmp/Orders.csv .snowflake/Orders.csv .vscode/Orders.csv .idea/Orders.csv \
    sub/dir/Orders.csv deep/nested/path/Orders.csv \
    PaymentTokens.csv card_tokens.csv payment_token.json card_token.json \
    TokenizedCards.csv password_reset_events.csv api_secret_events.csv \
    tokens/Orders.csv tokenized_client/Orders.csv credentials/Orders.csv \
    rsa_key/Orders.csv secrets/Orders.csv \
    Facturación.csv "Q1 Transactions.csv" Customer.CSV
do
    must_be_visible "data/probe_client/$p" "plausible delivery"
done

echo "== 3. Nothing is sitting in data/ ignored =="
# The only check that looks at the working tree rather than at patterns. It
# catches the case the others structurally cannot: a file physically present but
# skipped by `git add`, which is absent from the index and therefore from the
# manifest, the coverage diff and the base comparison alike.
#
# In CI this is normally a no-op — a fresh checkout holds only tracked files —
# but it is the whole point of running this script locally before committing.
hidden=$(git ls-files --others --ignored --exclude-standard -- data/ 2>/dev/null)
if [ -n "$hidden" ]; then
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        fail "present in data/ but ignored, so it will not be committed and will never reach Snowflake: $f"
    done <<< "$hidden"
else
    pass
fi

echo
if [ "$failed" -eq 0 ]; then
    echo "OK — $checks invariants hold."
else
    echo "FAILED — see the errors above."
fi
exit "$failed"
