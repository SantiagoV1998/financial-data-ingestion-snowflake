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

# ignorecase is pinned to TRUE — the permissive, and here the conservative,
# direction. On a case-insensitive checkout git ignores strictly more paths
# (Orders.TMP, CONFIG.TOML, .DS_STORE), so asserting under `false` would certify
# a path safe that real `git add` silently drops on macOS, the platform the docs
# send people to. Pinning it at all matters because leaving it to local config
# makes the same script behave differently here and on the runner.
#
# check-ignore exits 0 = ignored, 1 = not ignored, 128 = error. An error must
# never read as "not ignored": that is a failure counted as a satisfied
# invariant, in a script whose entire job is failing closed.
must_be_visible() {
    git -c core.ignorecase=true check-ignore --no-index -q "$1"
    # Captured immediately: inside the case, $? is the status of the case itself.
    local rc=$?
    case "$rc" in
        0) fail "$2: $1 is ignored, so a delivery with that path would be invisible to every other check" ;;
        1) pass ;;
        *) fail "git check-ignore errored on $1 (exit $rc) — refusing to treat that as a satisfied invariant" ;;
    esac
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
# stderr is NOT discarded and the exit status is checked. Swallowing a git
# failure here would leave `hidden` empty and report a pass for the only check
# that inspects the working tree — the one the script exists for.
if ! hidden=$(git ls-files --others --ignored --exclude-standard -- data/); then
    fail "git ls-files failed while scanning for ignored files in data/"
    hidden=""
fi
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
