# Financial Data Ingestion & Canonical Modeling — Snowflake

Ingestion of multi-format financial transaction data (XML, JSON, CSV) from
multiple clients into a canonical data model on Snowflake, **using SQL only** —
no Python, no external ETL tooling.

**[→ Pipeline results dashboard](https://santiagov1998.github.io/financial-data-ingestion-snowflake/)**

---

## The four deliverables

| | Where |
|---|---|
| **Raw ingestion DDL** | [`sql/01_bronze/`](sql/01_bronze/) |
| **Canonical DDL** | [`sql/03_gold/01_canonical_ddl.sql`](sql/03_gold/01_canonical_ddl.sql) |
| **Transformation SQL** | [`sql/02_silver/`](sql/02_silver/) · [`sql/03_gold/02_transform_to_canonical.sql`](sql/03_gold/02_transform_to_canonical.sql) |
| **Anomaly-handling notes** | [`docs/anomaly-handling.md`](docs/anomaly-handling.md) |

---

## The constraint that shapes everything

The source files in [`data/`](data/) are committed **byte-identical to how they
were delivered**. Nothing was cleaned, renamed or reformatted outside Snowflake —
and CI enforces it, so the claim is checkable rather than asserted.

That matters because **none of them parses with Snowflake's native readers**:

| File | Why the native parser rejects it |
|---|---|
| `ClientA_Transactions_1..7` | Fragments of one XML document, unevenly split. File 1 opens `<SalesData>` **and closes it**; file 7 closes it **again** without opening it. One opening tag against two closing ones, so plain concatenation gives a premature close mid-document and a duplicate close at the end. File 4 carries a `.txt` extension while containing XML. |
| `Client B/transactions.json` | Contains `//` comments, which are not legal JSON. |
| All 15 files | Exporter banners (`----- START OF FILE -----`) and, in the CSVs, footers and **annotations inside field values**. |

Repairing them in SQL, inside the warehouse, is the exercise. The obvious
shortcut — fix the files, then load them — answers a different question.

---

## Architecture

```
data/  (15 files, byte-identical to delivery)
  │  PUT — the only step that is not in-warehouse SQL
  ▼
@raw_files  internal stage
  │
  ▼
BRONZE   raw bytes + lineage · no transformation · replayable
SILVER   parsed · typed · deduplicated · validated + DQ quarantine
GOLD     canonical model conformed across all clients
```

Detail in [`knowledge-base/ARCHITECTURE.md`](knowledge-base/ARCHITECTURE.md);
the reasoning behind each decision, including the ones rejected, in
[`knowledge-base/DECISIONS.md`](knowledge-base/DECISIONS.md).

---

## Results

| | |
|---|---|
| Transactions | 57 parsed → **46 canonical** |
| Line items | 58 parsed → **43 canonical** |
| Quality findings | **170** — 11 reject, 159 warn |
| **Labelled anomalies detected** | **83 / 83 (100%)** — transactions *and* master data |
| Canonical model invariants | **32 / 32 passing** |

### The rules are measured, not asserted

The delivery labels its own anomalies — `<!-- TXN-1008: missing order date,
negative quantity -->` — and bronze keeps every line verbatim, so those labels are
recoverable as **ground truth** — from the XML comments and from the JSON's `//`
comments alike. Every label is classified and the totals reconcile: 45 mapped to
a rule, 7 schema variation handled by design, **0 unclassified**.

The comparison found a real gap: four transactions labelled `duplicate customer`
with no rule behind them. That rule now exists.

---

## The five conflicts between the client schemas

Resolved by preserving what the source said and exposing a normalized reading
beside it — never by inventing a value the client did not send.

| # | Client A | Client B | Resolution |
|---|---|---|---|
| 1 | `first_name` + `last_name` | one `customer_name` | `full_name` always; parts nullable, never split on whitespace |
| 2 | `loyalty_tier` GOLD/SILVER | `segment` VIP/REGULAR | `tier_raw` verbatim + `tier_rank` ordinal. **Nothing asserts GOLD = VIP** |
| 3 | payment embedded, no id, no status | payments file with both | Surrogate id **flagged as such**; status NULL with the reason recorded |
| 4 | `channel` Web/Mobile | not delivered | Nullable. "Unknown" ≠ "not collected by this client" |
| 5 | currency as XML attribute | nested in `price{}`, absent on payments | Coalesce cascade line → product → transaction, recorded per line |

Several canonical validations assert these **decisions** rather than the
mechanics: if someone later collapses the tier mapping into an equivalence, or
defaults a missing status to `'UNKNOWN'`, the build fails.

---

## Reproducing

Requires a Snowflake account and the
[Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index).
Run **from the repository root** — the upload step uses relative `PUT` paths.

```bash
snow sql -c <connection> -f sql/00_setup/01_infrastructure.sql

snow sql -c <connection> -f sql/01_bronze/01_stage_and_file_formats.sql
snow sql -c <connection> -f sql/01_bronze/02_upload_files.sql
snow sql -c <connection> -f sql/01_bronze/03_raw_ingestion_ddl.sql
snow sql -c <connection> -f sql/01_bronze/04_load_bronze.sql
snow sql -c <connection> -f sql/01_bronze/05_validate_bronze.sql      # 14 checks

snow sql -c <connection> -f sql/02_silver/01_parse_documents.sql       # asserts 46 + 11
snow sql -c <connection> -f sql/02_silver/02_extract_transactions.sql
snow sql -c <connection> -f sql/02_silver/03_extract_master_data.sql
snow sql -c <connection> -f sql/02_silver/04_data_quality.sql
snow sql -c <connection> -f sql/02_silver/05_validate_rules.sql        # ground truth
snow sql -c <connection> -f sql/02_silver/06_deduplicate.sql

snow sql -c <connection> -f sql/03_gold/01_canonical_ddl.sql
snow sql -c <connection> -f sql/03_gold/02_transform_to_canonical.sql
snow sql -c <connection> -f sql/03_gold/03_validate_canonical.sql      # 32 invariants
```

The **load** scripts are idempotent — each truncates before copying, and the
upload clears stale compressed copies first. The **DDL** scripts use
`CREATE OR REPLACE TABLE` and are destructive: re-running one empties its layer,
so the scripts after it must follow.

Validation scripts **raise** on failure rather than printing a report, because a
run that loads nothing otherwise looks exactly like a run that loads everything.

---

## Quality gates

Both run in CI on every pull request:

```bash
sqlfluff lint sql/                      # dialect snowflake
./scripts/check-data-integrity.sh       # data/ invariants
shasum -a 256 -c data/CHECKSUMS.sha256  # bytes match the manifest
```

The integrity gate compares `data/` against the base branch with the manifest
digest pinned in the workflow, so regenerating the manifest cannot launder an
edit to a source file. It was verified by opening pull requests that attempted
exactly that.

---

## Layout

```
data/            source files exactly as received (+ SHA-256 manifest)
sql/00_setup     role, warehouse, database, medallion schemas
sql/01_bronze    stage, file formats, raw DDL, load, validation
sql/02_silver    parsing, typing, quality rules, ground truth, deduplication
sql/03_gold      canonical DDL, transformation, validation
dashboard/       results page (export → build → static HTML)
docs/            anomaly-handling notes
knowledge-base/  architecture, source-file anatomy, design decisions
scripts/         data/ integrity invariants, shared by CI and local runs
CLAUDE.md        operating context
```
