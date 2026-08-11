#!/usr/bin/env bash
#
# Invariants for data/. Runs identically in CI and locally — one source of truth,
# so a check cannot pass in one place and fail in the other.
#
#   ./scripts/check-data-integrity.sh
#
# WHY THIS FILE EXISTS
#
# Deliveries under data/ must survive `git add`, and credentials must never be
# committed to this public repository. Earlier attempts pursued both with
# .gitignore name patterns alone, and that mechanism cannot work: it decides by
# guessing what a filename means, and BOTH mistakes are silent.
#
#   Too broad  → `*token*` swallowed PaymentTokens.csv and, worse, a whole
#                delivery under data/tokens/. `git add data` skipped it without a
#                word, the manifest stayed byte-identical, every gate went green,
#                and the records never reached Snowflake.
#   Too narrow → secrets.json and password.txt stayed committable while the
#                comment above them promised full coverage.
#
# Nine review rounds moved that line back and forth, each fix breaking the other
# side. So the mechanism changed rather than the patterns:
#
#   · Under data/, nothing is ignored by NAME. Only extensions that are never
#     data (.key, .pem, .p8, .env) are ignored, so a delivery cannot vanish
#     whatever it is called.
#   · A credential carrying a DATA extension — credentials.csv, api_secret.json —
#     is caught here instead, and fails the build loudly. A human then decides.
#
# Failing loudly is strictly better than ignoring silently: a false positive
# costs one conversation, a false negative costs a lost delivery or a published
# secret.

set -uo pipefail

failed=0
checks=0

fail() { echo "::error::$1"; echo "  FAIL  $1"; failed=1; }
pass() { checks=$((checks + 1)); }

# Pinned: the guard exists because a case-sensitive filesystem distinguishes
# Credentials.csv from credentials.csv. Left to the local git config it would
# pass vacuously on macOS — the platform the documentation tells people to run
# this on.
ignored() {
    git -c core.ignorecase=false check-ignore --no-index -q "$1"
    case "$?" in
        0) return 0 ;;   # ignored
        1) return 1 ;;   # not ignored
        *) fail "git check-ignore errored on $1"; return 1 ;;
    esac
}

must_be_visible() {
    if ignored "$1"; then
        fail "$2: $1 is ignored, so a delivery with that path would be invisible to every other check"
    else
        pass
    fi
}

must_be_ignored() {
    if ignored "$1"; then
        pass
    else
        fail "$2: $1 is not ignored and could be committed to this public repository"
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
# Nested paths matter: git does not descend into an excluded directory, so no
# !data/**/*.ext negation can rescue a file inside one.
for p in \
    Orders.csv Orders.CSV Transactions.xml transactions.json Transactions.txt \
    tmp/Orders.csv .snowflake/Orders.csv .vscode/Orders.csv .idea/Orders.csv \
    sub/dir/Orders.csv \
    PaymentTokens.csv card_tokens.csv payment_token.json card_token.json \
    TokenizedCards.csv password_reset_events.csv api_secret_events.csv \
    tokens/Orders.csv tokenized_client/Orders.csv credentials/Orders.csv \
    rsa_key/Orders.csv secrets/Orders.csv
do
    must_be_visible "data/probe_client/$p" "plausible delivery"
done

echo "== 3. Non-data extensions stay ignored under data/ =="
# These extensions are never a delivered record, so ignoring them by extension
# costs nothing and cannot swallow payload.
for p in signing.key Signing.KEY secrets.pem Secrets.PEM rsa_key.p8 RSA_KEY.P8 \
         .env .env.local .ENV
do
    must_be_ignored "data/probe_client/$p" "non-data extension"
done

echo "== 4. Credential-shaped names are not committed under data/ =="
# The loud half. Nothing above stops a file called credentials.csv from being
# staged — deliberately, since a broad ignore rule is what swallowed deliveries.
# Instead it fails here, visibly, and a human decides.
suspicious='(^|[/_.-])([Cc]redential|CREDENTIAL|[Ss]ecret|SECRET|[Pp]assword|PASSWORD|[Aa]pi[_-]?[Kk]ey|APIKEY|[Aa]uth[_-]?[Tt]oken|[Pp]rivate[_-]?[Kk]ey|[Rr]sa[_-]?[Kk]ey)'
while IFS= read -r f; do
    [ -z "$f" ] && continue
    base=$(basename "$f")
    if printf '%s' "$base" | grep -qE "$suspicious"; then
        fail "tracked file looks like a credential: $f — if it is genuinely delivered data, rename it; if it is a secret, remove it from history"
    else
        pass
    fi
done <<< "$tracked"

echo
if [ "$failed" -eq 0 ]; then
    echo "OK — $checks invariants hold."
else
    echo "FAILED — see the errors above."
fi
exit "$failed"
