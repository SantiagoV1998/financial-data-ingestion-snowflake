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
| `ClientA_Transactions_1..7` | Fragments of a single XML document, unevenly split. File 1 opens `<SalesData>` **and closes it**; file 7 closes it **again** without opening it; files 2–6 carry neither tag. One opening tag against two closing ones, so plain concatenation yields a premature close mid-document and a duplicate close at the end. File 4 also carries a `.txt` extension while containing XML. |
| `Client B/transactions.json` | Contains `//` comments, which are not legal JSON. |
| Exporter artefacts | Nine of the fifteen files open with `----- START OF FILE: … -----`; every CSV also ends with `----- END OF FILE -----`. `SKIP_HEADER` handles the banner, but there is no `SKIP_FOOTER`, and `COPY INTO` rejects a `WHERE` clause — so the footer loads as a phantom row unless removed explicitly. |

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
CLAUDE.md      operating context, loaded automatically by Claude Code
knowledge-base/  architecture, source-file anatomy, design decisions
data/          source files exactly as received
sql/00_setup   warehouse, database, medallion schemas
sql/01_bronze  stage, file formats, raw DDL, COPY INTO
sql/02_silver  XML/JSON parsing, dedup, data-quality rules
sql/03_gold    canonical DDL and transformations
sql/04_analysis  validation and reporting queries
dashboard/     results dashboard
```

## Reproducing

Requires a Snowflake account and the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index).
Scripts run in numeric order, **from the repository root** — the upload step
uses relative `PUT` paths.

```bash
snow sql -c <connection> -f sql/00_setup/01_infrastructure.sql
snow sql -c <connection> -f sql/01_bronze/01_stage_and_file_formats.sql
snow sql -c <connection> -f sql/01_bronze/02_upload_files.sql
snow sql -c <connection> -f sql/01_bronze/03_raw_ingestion_ddl.sql
snow sql -c <connection> -f sql/01_bronze/04_load_bronze.sql
snow sql -c <connection> -f sql/01_bronze/05_validate_bronze.sql   # must print 13 PASS
```

The **load** scripts are idempotent — each truncates before copying, and the
upload clears the stage first, so re-running is safe. The **DDL** scripts use
`CREATE OR REPLACE TABLE` and are destructive: re-running `03` empties bronze,
so `04` and `05` must follow it.
