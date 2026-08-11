# Decisions

Design decisions and the reasoning behind them. Each records what was chosen,
what was rejected, and why — so a future session can tell a deliberate choice
from an accident.

---

## D1 · Land files untouched, repair in SQL

**Decision**: source files are staged byte-identical and every repair happens in
SQL inside Snowflake.

**Rejected**: pre-cleaning the files (removing banners, stitching the XML,
stripping JSON comments) before upload.

**Why**: the brief requires SQL-only ingestion. Pre-cleaning would technically
produce loadable files, but it moves the actual work outside the warehouse and
answers a different question than the one asked. The difficulty *is* that the
files do not parse; solving that in SQL is the exercise. A checksum comparison
against the delivered files is part of the deliverable.

---

## D2 · Load unparseable files line-by-line, not whole-file

**Decision**: `ff_raw_text` reads one row per physical line.

**Rejected**: `FIELD_DELIMITER = NONE` + `RECORD_DELIMITER = NONE`, which pulls
an entire file into a single VARCHAR.

**Why**: whole-file loading risks the 16 MB VARCHAR default and, more
importantly, discards ordering. `METADATA$FILE_ROW_NUMBER` is what makes
reassembling seven fragments in their original order possible at all. It also
lets per-line repairs (comment stripping, banner removal) run as simple
predicates instead of multiline regex against one huge string.

---

## D3 · Discard both original XML root tags

**Decision**: filter out every `<SalesData>` and `</SalesData>` line and wrap
the surviving `<Transaction>` elements in a synthetic root.

**Rejected**: concatenating the fragments as-is.

**Why**: the fragments contain one opening tag and **two** closing tags — file 1
both opens and closes the root, file 7 closes it again. Concatenation yields a
premature close mid-document and a duplicate close at the end. Neither parses,
and there is no `TRY_PARSE_XML` to fail softly.

**Cost**: the root's attributes (`client="ClientA"`,
`generatedAt="2025-11-12T10:45:00Z"`) are dropped by this filter. If that
metadata is wanted, extract it separately before discarding the line.

---

## D4 · Remove the exporter footer in bronze, not silver

**Decision**: `DELETE` the `----- END OF FILE -----` row immediately after each
CSV `COPY`.

**Rejected**: carrying it through bronze and filtering it in silver as a DQ rule.

**Why**: the banner and the footer are the same kind of thing — exporter
metadata — and `SKIP_HEADER` already discards the banner. Removing both is
reading the format correctly, not cleansing data. Left in bronze it becomes a
business key indistinguishable from a real record, and every intermediate count
is wrong by one per table. `COPY INTO` rejects a `WHERE` clause, so the `DELETE`
is the only mechanism available.

`raw_text_lines` is deliberately *not* filtered this way: its rows are lines,
not business records, and its banner lines create no false key.

---

## D5 · `TRUNCATE` before `COPY`, not `FORCE` alone

**Decision**: every load truncates its target first.

**Why**: `FORCE = TRUE` disables the load-metadata guard that would skip
already-loaded files — so on its own it makes the load *append*, not replace. A
second run doubles every table. For `raw_text_lines` that is fatal rather than
merely wrong: the XML reassembly stitches lines in file order, so duplicated
lines emit `<Transaction><Transaction>` and `PARSE_XML` raises.

Verified by running the load three times and confirming identical counts.

---

## D6 · Preserve original values, expose normalized ones alongside

**Decision**: for client-specific taxonomies — Client A's `loyalty_tier`
(GOLD/SILVER) versus Client B's `segment` (VIP/REGULAR) — gold keeps `tier_raw`
verbatim and adds a numeric `tier_rank`. It does **not** map GOLD onto VIP.

**Why**: those are different business taxonomies and no mapping was provided.
Asserting `GOLD = VIP` invents a business rule nobody authorised, and it is
unrecoverable downstream once the original value is gone. The same principle
governs Client A's missing payment `status`: NULL with a recorded reason, not a
fabricated `'UNKNOWN'` that reads as real data.

---

## D7 · Quarantine, never delete

**Decision**: rows failing DQ rules are written to `dq_quarantine` with a rule
code, reason, severity and the raw payload.

**Why**: "we dropped 14 rows" is not an acceptable answer to an auditor.
Retaining the payload as VARIANT also means a rule can be corrected and the data
replayed without returning to the source files.

`REJECT` and `WARN` are kept distinct: a negative quantity may be a legitimate
return rather than corruption, and deciding that is a business call. Flag it,
state the ambiguity, and let it through marked rather than silently discarding
revenue.

---

## D8 · Report dataset inconsistencies rather than resolving them

**Decision**: the "Client B contains clientC data" mismatch, the missing third
client, and the truncated JSON are documented as findings. No renaming, no
synthesised records.

**Why**: each would require guessing which side is authoritative. The canonical
model keys on `source_system` so a third client costs no schema change, and
generating the ~110 missing JSON records would inflate every metric in the final
report with invented data.

---

## D9 · Verify claims about data before writing them down

**Decision**: no comment or document asserts a property of the source data that
has not been queried.

**Why**: this was learned the expensive way. Three early comments described the
files from assumption — "only file 1 opens the root", "every file opens with a
banner" — and both were wrong; silver was about to be written from them. In the
other direction, one code-review finding (CRLF leaving a trailing `\r`) was
plausible, well-argued, and false, disproved by loading the data both ways.

Claims about data are cheap to check and expensive to get wrong. A comment
asserting something untrue is worse than no comment, because it is trusted.

---

## D10 · A dedicated role owns everything; ACCOUNTADMIN only bootstraps

**Decision**: `ingestion_engineer` owns the database, schemas, stage, file
formats and tables. `ACCOUNTADMIN` appears only in `00_setup`, to create the
role and warehouse, and is dropped immediately.

**Why**: Snowflake advises against creating objects with `ACCOUNTADMIN` because
it becomes their owner. Any other role — SYSADMIN included — then gets "does
not exist or not authorized" on objects that plainly do exist, and cannot grant
itself access. The pipeline stops being transferable to another engineer.

This was not theoretical here: the first attempt to create schemas as the new
role failed with *"primary role INGESTION_ENGINEER must have CREATE SCHEMA
granted on DATABASE"* — Snowflake stating the problem directly. Ownership has to
transfer before the role creates anything inside the database.

The transfer is done with `GRANT OWNERSHIP ... COPY CURRENT GRANTS` rather than
by creating as the role, because `CREATE ... IF NOT EXISTS` is a no-op on an
existing object and would silently leave the old owner in place. Transferring
afterwards is correct for a fresh account and a pre-existing one alike.

---

## D11 · Assert the load, do not assume it

**Decision**: `05_validate_bronze.sql` checks 14 invariants and raises if any
fails.

**Why**: the pipeline has a silent-failure mode. If `PUT` stages nothing — wrong
working directory — or a `PATTERN` matches no files, every `COPY` still reports
success and every table ends up empty. A run that loads nothing looks exactly
like a run that loads everything.

Checks cover staged file count, per-table row counts, and three invariants that
encode bugs already found and fixed: no exporter footer surviving into a
business key, no NULL text lines, no carriage returns. That makes them
regression tests, not decoration — if a future change reintroduces one of those
defects, the script says which.

The raise was itself verified by forcing a FAIL and confirming the block aborts.
An assertion never seen to fail is not known to work.

---

## D12 · Rejected: snapshot-before-truncate

**Rejected**: cloning each bronze table before `TRUNCATE` so a failed reload
could be recovered.

**Why rejected**: the risk is real — `TRUNCATE` auto-commits, so a `COPY` that
fails afterwards leaves bronze empty. But the recovery it protects is already
trivial: the source files are 70 KB, committed in this repo and present in the
stage, and a full reload takes seconds. Clone-and-swap would add tables and
steps to explain for a recovery path cheaper to simply re-run.

Worth revisiting if the source data ever grows large enough that re-staging is
expensive. At this size it is ceremony.

---

## D13 · Lineage timestamps in UTC, not session-local

**Decision**: `loaded_at` defaults to `SYSDATE()`, not `CURRENT_TIMESTAMP()`.

**Why**: `CURRENT_TIMESTAMP()` returns `TIMESTAMP_LTZ`, so writing it into a
`TIMESTAMP_NTZ` column stores whatever the session's `TIMEZONE` parameter makes
of it. Measured on the same physical instant:

| Session timezone | Value stored |
|---|---|
| `America/Bogota` | `2026-08-10 14:46:43` |
| `Asia/Tokyo` | `2026-08-11 04:46:43` |
| `SYSDATE()` | `2026-08-10 19:46:43` (both) |

Fourteen hours apart, on different calendar days. Two engineers reloading bronze
from different locations would produce lineage that cannot be ordered — and
ordering loads is the entire purpose of the column. `SYSDATE()` returns
`TIMESTAMP_NTZ` in UTC unconditionally.

---

## D14 · The stage is cleared before every upload

**Decision**: `02_upload_files.sql` runs `REMOVE` before `PUT`.

**Why**: `OVERWRITE = TRUE` only replaces a file of the same name. A path
previously staged with `AUTO_COMPRESS = TRUE` leaves `Customer.csv.gz` beside
the new `Customer.csv`. The `COPY` statements match stage paths as prefixes and
the raw-text `PATTERN` accepts an optional `.gz`, so both names match and every
row loads twice. `REMOVE` makes the staged state a function of `data/` alone
rather than of upload history.

---

## D15 · Both file formats treat invalid bytes identically

**Decision**: `REPLACE_INVALID_CHARACTERS = FALSE` on `ff_client_csv` as well as
`ff_raw_text`.

**Why**: the two formats had opposite settings with no stated reason. Both land
in bronze, which is declared the replay source for everything downstream, and
nothing in the validation can detect a substitution after the fact. A Latin-1
`é` in a customer name would abort loudly on the XML path and silently become
`Jos�` on the CSV path, with the original byte unrecoverable. Divergent
handling of the same class of corruption within the same layer is not a
defensible contract.

---

## D16 · Branch protection, and the guarantee it does not give

**Decision**: `main` is protected — force-pushes and deletions rejected, both CI
checks required, `enforce_admins` on, a pull request required to merge. The
repository is public, which is what makes protection available at all (GitHub
gates it behind public or Pro).

**What this actually guarantees**: no code reaches `main` without passing CI, the
history cannot be rewritten, and the branch cannot be deleted. That is worth
having and it is enforced.

**What it does not guarantee, despite an earlier version of this entry claiming
otherwise**: that every change was read by a reviewer. This repository has one
collaborator, and no configuration produces that property with one person:

| Setting | Result |
|---|---|
| 1 approval required | Nobody can approve, so `main` freezes — nothing can merge |
| 0 approvals required | Does not block a direct push, verified below |

**Verified, and it failed**: with `required_pull_request_reviews` present at 0
approvals and `enforce_admins: true`, `git push origin <green-PR-head>:main` was
**accepted** and merged PR #2 without going through the pull request. A commit
that already carries green check runs satisfies the required contexts, so the
protection has nothing left to object to. An earlier note in this file recorded
`GH006: Protected branch update failed` as proof the hole was closed — that test
used a *fresh* commit with no check runs, which is a different case, and
generalising from it was wrong.

**Consequence for the re-delivery exception** (step 3 of the integrity gate; it lives in `ci.yml` and `CLAUDE.md`, not in a D-entry):
its stated justification was "the exception lands in a diff a reviewer reads".
For a solo repository that is a convention, not a control. The exception is still
narrow — it requires the pinned digest to change in the same commit — but it is
honest to say it is enforced by discipline rather than by GitHub.

**How to make it a real control**: add a second collaborator and require one
approving review. That is a team property, not a configuration trick, and it is
the only thing that closes it.

**Last updated**: 2026-08-10 · after PR #7, eighth review round
