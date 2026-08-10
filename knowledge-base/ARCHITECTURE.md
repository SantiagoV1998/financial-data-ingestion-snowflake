# Architecture

```
data/  (15 files, byte-identical to delivery)
  │
  │  PUT — the only step that is not in-warehouse SQL
  ▼
@raw_files  internal stage, files untouched
  │
  ▼
┌─ BRONZE ────────────────────────────────────────────────────┐
│ raw bytes + lineage · no transformation · fully replayable  │
│                                                             │
│  raw_text_lines           1 row per line of the 8 files     │
│                           no native parser accepts          │
│  raw_client_a_customers   ┐                                 │
│  raw_client_a_orders      │                                 │
│  raw_client_a_products    │ one table per source CSV,       │
│  raw_client_b_customers   │ every column VARCHAR            │
│  raw_client_b_orders      │                                 │
│  raw_client_b_products    │                                 │
│  raw_client_b_payments    ┘                                 │
└─────────────────────────────────────────────────────────────┘
  │
  │  repair in SQL: strip banners, reassemble XML fragments,
  │  remove JSON comments, PARSE_XML / TRY_PARSE_JSON, FLATTEN
  ▼
┌─ SILVER ────────────────────────────────────────────────────┐
│ parsed · typed · deduplicated · validated                   │
│                                                             │
│  stg_*                    tabular, one row per business fact│
│  dq_quarantine            rejected rows + rejection_rule    │
└─────────────────────────────────────────────────────────────┘
  │
  │  conform across clients
  ▼
┌─ GOLD ──────────────────────────────────────────────────────┐
│ canonical model · no source-specific logic                  │
│                                                             │
│  dim_source_system  dim_customer  dim_product               │
│  fact_order  fact_transaction  fact_order_item  fact_payment│
│  dq_summary                                                 │
└─────────────────────────────────────────────────────────────┘
```

## Layer contracts

**Bronze mirrors the source.** One table per source file, every column VARCHAR,
nothing cast, nothing filtered, nothing deduplicated. Two properties matter:

- *Typing is deferred.* A malformed date is a finding to report, not a reason
  for a load to fail. `TRY_*` in silver turns a bad value into a quarantined row
  instead of an aborted batch.
- *It is replayable.* If silver logic changes, gold is rebuilt from bronze
  without re-reading source files. That property is lost the moment bronze
  reshapes or drops anything — which is why bronze is source-shaped rather than
  generic, and why conforming is silver's and gold's job.

The one exception: exporter banners and footers are removed at bronze. They are
format metadata, not data — we already discard the banner via `SKIP_HEADER`, and
leaving the footer in creates a business key that is indistinguishable from a
real record. Genuine data-quality decisions still belong in silver.

**Silver parses, types, deduplicates and validates.** Deduplication happens
**exactly once**, here, with `QUALIFY ROW_NUMBER()`. Downstream layers then
never restate that logic and cannot reintroduce duplicates. Rejected rows are
routed to `dq_quarantine` with a rule code, a human-readable reason, a severity,
and the raw payload — never deleted. Keeping the payload means a rule can be
corrected and the data replayed without returning to the source files.

**Gold is the canonical model.** Strict types, conformed keys, and no
per-client conditionals: client-specific shape is silver's problem, and gold
sees one structure with a `source_system` column. When a fourth client arrives,
only silver changes.

## Lineage

Every bronze table carries `source_file` (`METADATA$FILENAME`),
`file_row_number` (`METADATA$FILE_ROW_NUMBER`) and `loaded_at`. Retrofitting
lineage later is close to impossible, so it is captured from the first table
onward and propagated into quarantine.

## Surrogate keys

Gold uses deterministic hashes — `MD5(client_code || '|' || natural_id)` — not
sequences. Rebuilding gold from bronze produces identical keys, so the model is
reproducible. `IDENTITY` columns would generate new values on every rebuild and
break anything referencing them.

Natural keys do not currently collide across clients (`CUST-A-0001` vs
`C-CUST-5001`), but the hash includes the client code anyway: relying on a
prefix convention that a future client is free to ignore is not a design.

## Constraints

Snowflake does not enforce `PRIMARY KEY`, `FOREIGN KEY` or `UNIQUE` — only
`NOT NULL`. Keys are declared for documentation and optimizer hints, but
uniqueness is *produced* by the silver deduplication, never assumed from a
constraint.

**Last updated**: 2026-08-10 · after PR #1 (bronze)
