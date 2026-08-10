# Financial Data Ingestion & Canonical Modeling — Snowflake

Ingestion of multi-format financial transaction data (XML, JSON, CSV) from
multiple clients into a canonical data model on Snowflake, **using SQL only** —
no Python, no external ETL tooling.

> Work in progress. Full documentation lands with the final delivery.

## The constraint that shapes everything

The source files are committed to `data/` **byte-identical to how they were
received**. Nothing was cleaned, renamed or reformatted outside Snowflake.

This matters because none of them parses with Snowflake's native
semi-structured readers:

| File | Why the native parser rejects it |
|---|---|
| `ClientA_Transactions_1..7` | Fragments of a single XML document — only file 1 opens the root, only file 7 closes it. Files 2–6 are bare `<Transaction>` siblings. File 4 carries a `.txt` extension while containing XML. |
| `Client B/transactions.json` | Contains `//` comments, which are not legal JSON. |
| All 15 files | Open with a banner line `----- START OF FILE: … -----`. |

Repairing them in SQL, inside Snowflake, is the exercise.

## Architecture

```
Source files (untouched) ──► @raw_files stage
        │
   BRONZE   raw bytes + lineage, no transformation, fully replayable
   SILVER   parsed, typed, deduplicated, validated + DQ quarantine
   GOLD     canonical model conformed across all clients
```

## Layout

```
data/          source files exactly as received
sql/00_setup   warehouse, database, medallion schemas
sql/01_bronze  stage, file formats, raw DDL, COPY INTO
sql/02_silver  XML/JSON parsing, dedup, data-quality rules
sql/03_gold    canonical DDL and transformations
sql/04_analysis  validation and reporting queries
dashboard/     results dashboard
docs/          data model and anomaly-handling notes
```

## Reproducing

Requires a Snowflake account and the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index).
Scripts run in numeric order and are idempotent.

```bash
snow sql -c <connection> -f sql/00_setup/01_infrastructure.sql
# ... then each numbered script in sequence
```
