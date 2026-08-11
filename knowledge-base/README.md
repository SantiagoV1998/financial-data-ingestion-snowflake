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
| Setup — role, warehouse, database, medallion schemas | ✅ Done | #1 |
| Bronze — stage, file formats, raw DDL, load, validation | ✅ Done | #1 |
| CI — SQL linting and source-integrity gates | ✅ Done | #2, #7 |
| Silver — XML/JSON parsing and typing | ✅ Done | #8 |
| Silver — quality rules, ground truth, deduplication | ✅ Done | #8 |
| Gold — canonical model and transformations | ✅ Done | #8 |
| Results dashboard | ✅ Done | #8 |
| Documentation and anomaly notes | ✅ Done | #8 |

### What exists in Snowflake right now

Database `financial_ingestion`, warehouse `wh_ingestion` (XSMALL, 60s
auto-suspend), schemas `bronze` / `silver` / `gold`, all owned by the
`ingestion_engineer` role. `ACCOUNTADMIN` only creates the role and warehouse in
`00_setup`; it never owns pipeline objects.

| Layer | State |
|---|---|
| **Bronze** | 1701 text lines from the 8 unparseable files + 148 master rows. 14 invariants asserted, all passing. |
| **Silver** | 57 transactions parsed → 46 clean; 58 line items → 43 clean; 131 quality findings quarantined. |
| **Gold** | 46 transactions, 43 line items, 43 customers, 37 products, 40 orders, 57 payments. 29 invariants asserted, all passing. |

**Rule coverage against the provider's own labels: 55/55**, across both clients —
Client A's XML comments and Client B's JSON `//` comments alike. Every label
classified: 45 mapped to a rule, 7 schema variation by design, 0 unclassified.

### Figures worth knowing

`amount_variance` — the gap between a stated payment and the sum of its own
lines — is the reconciliation the model exists to expose. It is measured and
never corrected:

| Client | Transactions | Payment ≠ lines | Total absolute variance |
|---|---|---|---|
| Client A | 37 | 9 | 694.76 |
| Client B | 9 | 1 | 53.94 |

Plus 6 transactions whose variance is **not comparable** — 5 because lines this
pipeline rejected were never summed, and TXN-1026 because it states no payment
amount at all. Reported separately so the metric does not overstate how
inconsistent the source is: a transaction we could not fully read is a different
fact from a source that disagrees with itself.

These figures were wrong twice before settling here, both times because a join
fabricated variance rather than measuring it: line items leaking between copies
of a duplicated transaction, and a deduplication tiebreaker that kept the empty
copy of C-TXN-3001 over the one carrying its only line. Both are in the traps
below.

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
6. **A repeated element with exactly one occurrence is not an array.** For 44 of
   46 transactions `Items:"$"` is a bare element, so `FLATTEN` iterates its
   *children* and yields **4 line items out of 48**, silently. `TO_ARRAY`
   normalises both shapes; `OUTER => TRUE` keeps transactions with no items.
7. **Deduplication must be position-aware end to end.** Joining line items on
   `transaction_id` alone let lines from a *discarded* copy attach to the
   surviving one — TXN-1001 gained a phantom 91.00 variance that way. The same
   applies in reverse: a REJECT matched on id alone drops every copy, clean ones
   included. Carry `document_position` through both.
8. **A derived key must resolve, not just compute.** `order_key` was
   `MD5(...order_id)` regardless of whether the order existed, so 19
   transactions carried foreign keys pointing at rows that were never created —
   invisible because no validation checked. Resolve through the dimension and
   leave NULL when absent.

---

## Repository protections

`main` is protected: force-pushes and deletions rejected, both CI checks
required, enforced for admins. A pull-request rule is configured at zero required
approvals, which does **not** block a direct push — see below.

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

**Last updated**: 2026-08-11 · after PR #8 (silver, gold, dashboard, docs)
