# Knowledge Base — financial-data-ingestion-snowflake

Durable context for this project. Written so a session with no history can pick
the work up without re-deriving what was already learned.

**Project**: Offline exercise — multi-format financial data ingestion and
canonical modeling on Snowflake, SQL only
**Repository**: https://github.com/SantiagoV1998/financial-data-ingestion-snowflake

---

## Quick navigation

| Document | Purpose |
|---|---|
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Medallion layers, tables, data flow |
| [DATA_SOURCES.md](./DATA_SOURCES.md) | Anatomy of the 15 source files and every trap in them |
| [DECISIONS.md](./DECISIONS.md) | Design decisions and the reasoning behind them |
| [.metadata.yaml](./.metadata.yaml) | Machine-readable project metadata |

Operating instructions — how to connect, how to run, conventions — live in
[`../CLAUDE.md`](../CLAUDE.md), which Claude Code loads automatically.

---

## Status

| Phase | State | PR |
|---|---|---|
| Setup — warehouse, database, medallion schemas | ✅ Done | #1 |
| Bronze — stage, file formats, raw DDL, load | ✅ Done | #1 |
| Silver — XML/JSON parsing | 🔜 Next | — |
| Silver — deduplication and DQ quarantine | ⬜ Pending | — |
| Gold — canonical model and transformations | ⬜ Pending | — |
| Results dashboard | ⬜ Pending | — |
| Documentation and anomaly notes | ⬜ Pending | — |

### What exists in Snowflake right now

Database `financial_ingestion`, warehouse `wh_ingestion` (XSMALL, 60s
auto-suspend), schemas `bronze` / `silver` / `gold`, all owned by the
`ingestion_engineer` role. `ACCOUNTADMIN` is used only to create the role and
warehouse in `00_setup`, never to own pipeline objects.

`sql/01_bronze/05_validate_bronze.sql` asserts 14 load invariants and raises on
failure. All 14 pass.

Bronze is loaded and verified:

| Table | Rows | Content |
|---|---|---|
| `raw_text_lines` | 1701 | Verbatim lines from the 7 XML fragments + the JSON |
| `raw_client_a_customers` | 23 | |
| `raw_client_a_orders` | 21 | |
| `raw_client_a_products` | 22 | |
| `raw_client_b_customers` | 22 | |
| `raw_client_b_orders` | 21 | |
| `raw_client_b_products` | 18 | |
| `raw_client_b_payments` | 21 | |

Silver and gold are empty.

### Validated in Snowflake, not yet committed

Both parsing strategies were proven against the real data before being written
into silver. The queries are in the exploration below and produce:

- **ClientA XML** — 45 859 characters reassembled from 7 fragments,
  `PARSE_XML` succeeds, **46 `<Transaction>` elements** (40 distinct ids,
  so 6 duplicates)
- **ClientB JSON** — 5 798 characters after comment removal,
  `TRY_PARSE_JSON` succeeds, **11 transactions** (10 distinct ids,
  so 1 duplicate)

Reassembling the XML:

```sql
WITH fragment_lines AS (
    SELECT REGEXP_SUBSTR(source_file, 'ClientA_Transactions_(\\d+)', 1, 1, 'e', 1)::NUMBER AS fragment_seq,
           file_row_number, line_text
    FROM   bronze.raw_text_lines
    WHERE  source_file ILIKE '%ClientA_Transactions%'
      AND  NOT REGEXP_LIKE(line_text, '^\\s*-{3,}.*OF FILE.*$')   -- exporter banners
      AND  NOT REGEXP_LIKE(TRIM(line_text), '^</?SalesData.*>$')  -- unbalanced original roots
),
document AS (
    SELECT PARSE_XML('<SalesData>' ||
             LISTAGG(line_text, '\n') WITHIN GROUP (ORDER BY fragment_seq, file_row_number) ||
           '</SalesData>') AS doc
    FROM fragment_lines
)
SELECT f.value
FROM   document, LATERAL FLATTEN(INPUT => doc:"$") f
WHERE  f.value:"@"::VARCHAR = 'Transaction';   -- excludes comment nodes
```

Cleaning the JSON:

```sql
WITH cleaned_lines AS (
    SELECT file_row_number,
           -- (^|[^:]) guard keeps "https://..." intact
           REGEXP_REPLACE(line_text, '(^|[^:])//.*$', '\\1') AS line_text
    FROM   bronze.raw_text_lines
    WHERE  source_file ILIKE '%transactions.json'
      AND  NOT REGEXP_LIKE(line_text, '^\\s*-{3,}.*OF FILE.*$')
)
SELECT TRY_PARSE_JSON(LISTAGG(line_text, '\n') WITHIN GROUP (ORDER BY file_row_number))
FROM cleaned_lines;
```

---

## Traps that cost time — read before touching silver

1. **`XMLGET` returns an element, never a scalar.** Text extraction is always
   two steps: `XMLGET(v, 'tag'):"$"::VARCHAR`. Forgetting the cast yields a
   VARIANT that renders with JSON quotes (`"John"` not `John`), which then joins
   against nothing.
2. **Flattening the XML root returns 92 children, not 46.** XML comments count
   as nodes. Filter on `f.value:"@"::VARCHAR = 'Transaction'` or every count in
   the deliverable doubles.
3. **There is no `TRY_PARSE_XML`.** Malformed XML raises and aborts the
   statement. Validate or repair the string first.
4. **`COPY INTO` rejects `WHERE`** — "COPY statement only supports simple SELECT
   from stage statements for import". Filtering at load time is not an option;
   filter after loading, or in the next layer.
5. **`COPY INTO` will not reload a file it has already loaded** (64-day load
   metadata). It reports success and loads zero rows. `FORCE = TRUE` overrides
   it — but `FORCE` alone is not idempotent, it appends. Pair it with `TRUNCATE`.

---

## Repository protections

`main` is protected: force-pushes and deletions rejected, both CI checks
required, enforced for admins, a PR required to merge.

Read D16 before relying on it. The protection guarantees that nothing reaches
`main` without passing CI — but **not** that every change was reviewed. With one
collaborator no configuration provides that, and a commit already carrying green
checks can be pushed straight to `main`; this was verified, and it succeeded.
The re-delivery exception is therefore enforced by discipline, not by GitHub.

## Working agreement

- `/code-review` runs on every PR. Findings are discussed, agreed, applied, and
  only then is the PR merged.
- **Verify before asserting.** The first review found three comments describing
  the source files from assumption rather than inspection, all wrong. One review
  finding was itself a false positive, disproved by loading the data both ways.
  Claims about data are cheap to check and expensive to get wrong.
- Documentation is updated in the same PR as the code it describes.

**Last updated**: 2026-08-10 · after PR #1 (bronze), sixth review round
