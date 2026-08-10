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
programmatic sign-in). Neither the config nor the key is in this repo, and
`.gitignore` is set up to keep it that way — never commit either.

Target: database `financial_ingestion`, warehouse `wh_ingestion`, schemas
`bronze` / `silver` / `gold`.

## Running the pipeline

Scripts are numbered and run in order. Every one is idempotent — re-running from
scratch is the supported path, and `sql/01_bronze/02_upload_files.sql` must run
from the repository root because its `PUT` paths are relative.

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
