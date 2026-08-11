# Anomaly handling

How every defect in the delivery is detected, classified and treated — and, where
a decision could have gone either way, why it went the way it did.

---

## The principle

**Nothing is deleted, and nothing is invented.**

A record that fails a rule is written to `silver.dq_quarantine` with the rule
code, a human-readable reason, a severity, and **its original payload**. "We
dropped 14 rows" is not an answer to an auditor, and keeping the payload means a
rule can be corrected and the data replayed without going back to the source
files.

Equally, a value the client did not send stays NULL. A fabricated `'UNKNOWN'`
status is indistinguishable from a status the client actually sent, and that is
worse than an obvious gap.

---

## Severity: a business distinction, not a severity guess

| | Meaning | Treatment |
|---|---|---|
| **REJECT** | The record cannot be represented — nothing to key on, or nothing to load | Held back from the canonical model, retained in quarantine |
| **WARN** | The record loads, but something about it is questionable | Loaded and flagged |

The line between them is not "how bad is it" but **"can this be represented at
all"**.

A transaction with no id cannot be keyed or deduplicated: REJECT. A line with no
SKU cannot be matched to a product: REJECT. But a **negative quantity** may be a
legitimate return, and a **negative payment** may be a refund — this is a
payments dataset, where both are ordinary. Dropping them would destroy revenue
the client can still explain, so they load with `is_return_line` and `is_refund`
set, and the client decides.

---

## The rules

**13 REJECT findings · 95 WARN findings · 108 total**

### Transaction level

| Rule | Severity | Found | Why this severity |
|---|---|---|---|
| `MISSING_TRANSACTION_ID` | REJECT | 2 | Nothing to key or deduplicate on |
| `MISSING_ORDER_ID` | REJECT | 2 | Cannot attach to an order |
| `MISSING_CUSTOMER_ID` | REJECT | 1 | Cannot attach to a customer |
| `DUPLICATE_TRANSACTION_ID` | WARN | 12 | Delivery artefact; deduplicated, both copies recorded |
| `DUPLICATE_ORDER_ID` | WARN | 4 | Same order under several transaction ids — a business problem, reported separately |
| `DUPLICATE_CUSTOMER` | WARN | 8 | Customer master repeats an id, so any join against it multiplies |
| `ORPHAN_CUSTOMER` | WARN | 18 | Transaction references a customer with no master record |
| `MISSING_ORDER_DATE` | WARN | 5 | Loads; date is NULL and the raw text is retained |
| `MISSING_CUSTOMER_NAME` | WARN | 3 | |
| `MISSING_EMAIL` | WARN | 4 | |
| `INVALID_EMAIL` | WARN | 3 | e.g. `noemail@`, `jchen@@example..com` |
| `MISSING_PAYMENT_METHOD` | WARN | 1 | |
| `MISSING_PAYMENT_AMOUNT` | WARN | 1 | |
| `NEGATIVE_PAYMENT_AMOUNT` | WARN | 6 | **May be a refund** — flagged, not dropped |

### Line-item level

| Rule | Severity | Found | Why this severity |
|---|---|---|---|
| `MISSING_SKU` | REJECT | 5 | Cannot be matched to a product |
| `MISSING_QUANTITY` | REJECT | 1 | Nothing to multiply |
| `NEGATIVE_UNIT_PRICE` | REJECT | 2 | **No reading makes this valid** — prices are not signed |
| `NEGATIVE_QUANTITY` | WARN | 9 | **May be a return line** — flagged, not dropped |
| `MISSING_DESCRIPTION` | WARN | 1 | Cosmetic; the SKU carries the identity |
| `ORPHAN_SKU` | WARN | 20 | SKU has no product master record |

Two duplicate rules exist rather than one because they are **different defects**:
a repeated transaction id is a delivery artefact, while the same order billed
under two transaction ids is a business problem. Collapsing them into one
`PARTITION BY` would hide the second.

---

## The rules are measured, not asserted

The delivery **labels its own anomalies**. Each XML transaction is preceded by a
comment naming what is wrong with it, and the CSVs carry the same inline:

```xml
<!-- TXN-1008: missing order date, negative quantity -->
```
```csv
CUST-A-0033,Julia,Chen,jchen@@example..com,SILVER,Web,true <-- invalid email
```

Bronze keeps every line verbatim, so those labels are recoverable — and that turns
"I wrote some quality rules" into something measurable.

**Result: 49 of 49 expectations detected.**

Every ground-truth label is classified, and the totals reconcile:

| Bucket | Labels |
|---|---|
| Mapped to a rule | 39 |
| Schema variation, handled by design | 7 |
| **Unclassified** | **0** |
| | **46** = the 46 transactions |

A coverage figure that quietly drops the labels it cannot satisfy is worthless,
so nothing is left out of the denominator.

### What the comparison found

**A real gap.** Six transactions labelled `duplicate customer` had no rule behind
them, because I had not written one. `DUPLICATE_CUSTOMER` exists as a direct
result and fires on 8 rows.

**Two defects in the measurement, not in the rules** — worth recording because
both looked like coverage gaps:

- Matching the bare word `duplicate` routed `duplicate customer` and
  `duplicate order id` to `DUPLICATE_TRANSACTION_ID`, reporting six false misses.
  The phrase list is now ordered most-specific-first.
- A transaction with no id cannot be matched on `natural_key` — the quarantine row
  records the id it does not have. The rule had fired correctly; the join could
  not see it.

---

## The CSV annotations were themselves an anomaly

The `<-- invalid email` annotations sit **inside a field value**, unlike XML
comments, which are separate nodes the parser ignores. So `true   <-- duplicate`
is what reached the column, and `TRY_TO_BOOLEAN` returned NULL — which read as bad
source data and was not.

They do not always land in the last column either: `CUST-A-0040,,,,,false` carries
six fields for seven columns, so its annotation ends up in `signup_source`. Every
text field is cleaned, not just the last.

28 annotations across the seven CSVs, stripped from the values and **retained** in
a `source_annotation` column — which is what makes the ground-truth comparison
above possible for the CSV side too.

---

## Structural anomalies handled by design

Not every defect needs a rule. These are handled by the shape of the pipeline,
which is why 7 ground-truth labels are classified as schema variation:

**Unexpected extra nested elements.** `Notes`, `Meta`, `Shipping`, `GiftOptions`,
`Warranty`, `Tags`, `Coupons`, `ReturnPolicy`, `Audit`, `Preferences`, `metadata`
— appearing in different records, at different levels. Nothing flags them:
unselected paths are simply not read during extraction, and the whole payload
survives in `raw_payload`. Adding a rule would report a defect where none exists.

**Inconsistent nesting across records.** `COALESCE` over the alternative paths,
rather than a `CASE` cascade per record shape.

**The seven XML fragments.** File 1 opens `<SalesData>` *and* closes it; file 7
closes it again without opening it. One opening tag against two closing ones, so
concatenating them in order produces a premature close mid-document and a
duplicate close at the end. Both original root tags are discarded and a synthetic
root wraps the surviving `<Transaction>` elements.

**JSON comments.** Stripped per line before `TRY_PARSE_JSON`, with a guard so a
`https://` URL would survive.

---

## Two traps that produce wrong numbers rather than errors

These are the ones worth knowing about, because nothing fails when you get them
wrong:

**Flattening the XML root returns 92 children, not 46.** XML comments are nodes
too. Filtering on the element name is what keeps the count honest — without it,
every figure in this document doubles.

**A repeated element with exactly one occurrence is not an array.** For 44 of the
46 transactions, `Items:"$"` is a bare element, so `FLATTEN` iterates that
element's *children* (`SKU`, `Quantity`, …) rather than the items. Done naively
this yields **4 line items out of 48**, silently. `TO_ARRAY` normalises both
shapes; `OUTER => TRUE` then keeps transactions with no items at all, which
Client B genuinely has.

Both were caught by comparing against the files — `grep -c '<Transaction>'` and
`grep -c '<Item>'` — rather than by trusting the query.

---

## Anomalies in the delivery itself

Reported rather than resolved, because resolving them means guessing which side is
authoritative:

**"Client B" contains Client C data.** The folder is named Client B, but every
file inside identifies as `clientC_*` and every identifier is prefixed `C-`. Table
names follow the folder; identifiers keep their own prefix; `dim_source_system`
records the discrepancy.

**The brief says three clients; two were delivered.** The canonical model keys on
`source_system`, so a third client costs no schema change.

**The JSON is a truncated sample.** Its trailing comment describes ~120 records
(“Continue pattern up to C-TXN-3120”) where 11 were delivered. Generating the
missing ~110 would inflate every metric in this document with invented data.

---

## What is left visible on purpose

`fact_transaction.amount_variance` — the difference between what the source says
was paid and what its own line items add up to.

| Client | Transactions | Payment ≠ lines | Total absolute variance |
|---|---|---|---|
| Client A | 37 | 9 | 694.76 |
| Client B | 9 | 1 | 53.94 |

It is **measured and left visible, never corrected**. Correcting it would erase
the finding — and reconciling a payment against its own lines is precisely what a
canonical model over multi-client financial data exists to make possible.
