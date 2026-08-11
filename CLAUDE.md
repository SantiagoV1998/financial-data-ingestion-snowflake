# CLAUDE.md

Operating context for this repository. Read `knowledge-base/README.md` next — it
carries the detail this file only points at.

## What this is

An offline technical exercise: ingest multi-format financial transaction data
(XML, JSON, CSV) from several clients into a canonical model on Snowflake,
**using SQL only** — no Python, no external ETL tooling. The deliverable is a
public repository containing raw ingestion DDL, canonical DDL, transformation
SQL, and notes on anomaly handling.

## The constraint that governs every decision

**Nothing is cleaned outside Snowflake.** The 15 source files in `data/` are
byte-identical to how they were delivered, and every repair — stripping exporter
banners, reassembling fragmented XML, removing JSON comments — happens in SQL
inside the warehouse.

This is not pedantry. It is the actual difficulty of the exercise: none of the
files parses with Snowflake's native readers, and the obvious shortcut (fix the
files first, then load them) fails the brief. If you are tempted to preprocess a
file, you have misread the task.

## Connecting

```bash
snow sql -c nuaav -q "SELECT CURRENT_VERSION()"
snow sql -c nuaav -f sql/01_bronze/04_load_bronze.sql
```

Connection `nuaav` is defined in `~/.snowflake/config.toml`, authenticating with
an RSA key pair at `~/.snowflake/keys/` (Snowflake blocks password-only
programmatic sign-in). Neither the config nor the key lives in this repo, and
`.gitignore` keeps it that way.

Target: database `financial_ingestion`, warehouse `wh_ingestion`, schemas
`bronze` / `silver` / `gold`, role **`ingestion_engineer`**.

`ACCOUNTADMIN` appears only in `sql/00_setup/01_infrastructure.sql`, to create
the role and warehouse, and is dropped immediately. Never create pipeline
objects with it: it becomes their owner, and every other role — SYSADMIN
included — then gets "does not exist or not authorized" on objects that plainly
do exist.

## Running the pipeline

Scripts are numbered and run in sequence. `sql/01_bronze/02_upload_files.sql`
must run **from the repository root** — its `PUT` paths are relative, and from
elsewhere it fails with `File doesn't exist`.

Re-running is supported, with one caveat worth knowing: the *load* scripts are
idempotent (each `TRUNCATE`s before its `COPY`), but the *DDL* scripts use
`CREATE OR REPLACE TABLE` and are therefore destructive — re-running `03`
empties bronze, so `04` must follow it. Since bronze is the replay source for
silver, dropping it means a full re-stage and reload before silver can be
rebuilt.

`sql/01_bronze/05_validate_bronze.sql` asserts the load actually produced what
it claims. Run it after any change: it raises on failure rather than passing
quietly, because a run that loads nothing otherwise looks exactly like a run
that loads everything.

## Quality gates

```bash
sqlfluff lint sql/                      # dialect snowflake, config in .sqlfluff
shasum -a 256 -c data/CHECKSUMS.sha256  # bytes match the manifest
diff <(git -c core.quotePath=false ls-files data | grep -vx 'data/CHECKSUMS\.sha256' | sort) \
     <(sed 's/^[0-9a-f]\{64\}  //' data/CHECKSUMS.sha256 | sort)  # manifest coverage
./scripts/check-data-integrity.sh       # data/ invariants (prints its own count)
```

CI runs the same five steps: the manifest's pinned digest (0), the checksums
(1), manifest coverage (2), the `data/` invariants (2b), and a diff of the
source files against the base (3). Everything except step 3 runs locally —
step 3 is the only one needing the base ref. `check-data-integrity.sh` is
literally the script CI invokes, so it cannot pass here and fail there.

Run the local four before pushing. Step 2b in particular catches something no CI
step can: a delivered file sitting on disk that `git add` would skip. It is
absent from the index, therefore absent from the manifest, the coverage diff and
the base comparison alike — and absent from a fresh CI checkout too, so CI is
structurally blind to it.

**What these gates guarantee.** That the delivered files are ingested exactly as
received: unchanged bytes, none lost. That is the exercise's central claim, and
without enforcement someone could quietly "fix" a source file — close the XML
root, strip the banner — and the pipeline would pass while the exercise had been
sidestepped.

**What they do not.** They do not identify secrets. `.gitignore` carries ordinary
hygiene rules, and neither it nor the script tries to recognise a credential by
filename — that approach was removed after it repeatedly either swallowed
deliveries or missed obvious names; the script header explains why it cannot
work. Secret detection is GitHub secret scanning with push protection, whose
scope and limits are recorded in `knowledge-base/DECISIONS.md` D17.

Coverage is bounded and worth knowing precisely: the re-inclusions under `data/`
name the five delivered formats, so a delivery arriving as `Payments.tmp` or
`config.toml` would still be skipped by `git add`. Step 2b's working-tree check
catches exactly that, but only when run locally before committing.

## Conventions

- **SQL**: keywords uppercase, identifiers `snake_case` and never quoted
  (unquoted identifiers fold to uppercase in Snowflake; mixing quoted and
  unquoted styles is the most common source of "object does not exist").
- **Comments explain why, not what.** A comment restating the SQL below it is
  noise. A comment recording why an option is set the way it is, is the point.
- **Never assert something in a comment without verifying it.** Several early
  comments described the source files from assumption and were wrong; the SQL
  built on them would have been wrong too. Query the data, then write the claim.
- **Git**: branch `feature/<short-description>`, small conventional commits,
  always a PR into `main`, never a direct push. Run `/code-review` on each PR,
  agree on the findings, apply fixes, then merge.
- **Documentation lives with the code it describes.** A PR that changes a layer
  updates `knowledge-base/` in the same PR — a knowledge base that lags is worse
  than none, because the next session trusts it.

## Language

Conversation with the repository owner is in Spanish. Everything committed —
code, comments, documentation, commit messages, PR descriptions — is in English.
