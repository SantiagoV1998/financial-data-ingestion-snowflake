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

**Last updated**: 2026-08-10 · after PR #1 (bronze)
