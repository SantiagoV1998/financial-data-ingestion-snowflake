# Data Sources

Anatomy of the 15 delivered files. Everything here was verified against the
bytes, not inferred from the brief — several early assumptions turned out to be
wrong and the SQL built on them would have been wrong too.

Files live in `data/`, byte-identical to delivery (verified by checksum).

---

## Inventory

### Client A — `data/client_a/` (10 files)

| File | Format | Content |
|---|---|---|
| `ClientA_Transactions_1..7` | XML fragments | 46 `<Transaction>` elements total |
| `Customer.csv` | CSV | 23 customers |
| `Orders.csv` | CSV | 21 orders |
| `Products.csv` | CSV | 22 products |

`ClientA_Transactions_4` carries a **`.txt` extension while containing XML**.

Client A has **no payments file** — payment is embedded inside each transaction.

### Client B — `data/client_b/` (5 files)

| File | Format | Content |
|---|---|---|
| `transactions.json` | JSON | 11 transactions (10 distinct) |
| `Customer.CSV` | CSV | 22 customers |
| `Order.csv` | CSV | 21 orders |
| `Product.csv` | CSV | 18 products |
| `Payments.csv` | CSV | 21 payments |

Note the naming drift against Client A: uppercase `.CSV`, singular `Order` and
`Product` where Client A uses plural.

---

## Finding: "Client B" contains Client C data

The folder is named **Client B**, but every file inside identifies itself as
`clientC_*` in its banner line, and every identifier is prefixed `C-`
(`C-CUST-5001`, `C-ORD-9001`, `C-TXN-3001`).

The brief also refers to "all three clients' data" — but only two clients were
delivered. Either Client B is missing and this folder is Client C misfiled, or
the folder name is simply wrong.

**How this is handled**: not silently resolved. Bronze table names follow the
folder (`raw_client_b_*`); the identifiers keep their own `C-` prefix. The
canonical model keys on `source_system`, so a third client needs no schema
change. The discrepancy is reported as a finding rather than papered over —
guessing which name is authoritative would be inventing information.

---

## Finding: the JSON is deliberately truncated

`transactions.json` ends with a comment describing data that is not there:

```
// Continue pattern up to C-TXN-3120:
// - 100 valid records
// - 20–30 anomaly records
// - duplicates of id
// - missing fields
// - negative qty or price
// - invalid emails
// - extra nested fields like "metadata", "tags", "shipping"
// - inconsistent nesting across records
```

11 transactions were delivered, not ~120. The file is a representative sample.
**Decision**: work with what was delivered and document the gap. Synthesising
the missing ~110 records would inflate every metric in the deliverable with
data we invented.

---

## Why no file parses natively

### Exporter artefacts

Nine of the fifteen files open with `----- START OF FILE: <name> -----`: the
seven CSVs, `ClientA_Transactions_1`, and `transactions.json`.
`ClientA_Transactions_2..7` have **none** — logic that blindly drops each file's
first line deletes a real `<Transaction>` line from six fragments.

Every CSV, plus three other files, **ends** with `----- END OF FILE -----`.
`SKIP_HEADER` handles the opener; there is no `SKIP_FOOTER`, and `COPY INTO`
rejects a `WHERE` clause, so the footer loads as a data row whose business key
is the literal footer text. It is removed by explicit `DELETE` after loading.

All 15 files use **CRLF** line endings. Snowflake resolves `\r\n` to a single
record delimiter, both by default and with an explicit `'\n'` — verified by
loading both ways and finding zero carriage returns in the result.

### The XML fragments are unevenly split

| Fragment | `<SalesData>` | `</SalesData>` |
|---|---|---|
| `_1.xml` | ✅ opens | ✅ **also closes** |
| `_2..6` | — | — |
| `_7.xml` | — | ✅ closes again |

One opening tag against **two** closing tags. Concatenating the fragments in
order produces a premature close mid-document and a duplicate close at the end —
invalid either way.

**Resolution**: discard both original root tags and wrap the surviving
`<Transaction>` elements in a synthetic root. Ordering comes from
`METADATA$FILE_ROW_NUMBER` within a fragment sequence parsed out of the
filename numerically, so `_10` would not sort between `_1` and `_2`.

### The JSON contains comments

`//` comments appear both inline (`"id": "C-TXN-3001",   // duplicate`) and on
their own lines. Comments are not legal JSON and no file-format option enables
them.

**Resolution**: strip per line with
`REGEXP_REPLACE(line_text, '(^|[^:])//.*$', '\\1')`. The `(^|[^:])` guard
matters — a naive `'//.*'` destroys every URL in a payload.

---

## Schema divergence between clients

This is the actual modeling problem, and it is what gold has to reconcile.

| Concept | Client A | Client B | Canonical resolution |
|---|---|---|---|
| Customer name | `first_name` + `last_name` | `customer_name` (single) | `full_name` always; `first_name`/`last_name` nullable, derived where possible |
| Customer tier | `loyalty_tier`: GOLD / SILVER | `segment`: VIP / REGULAR | `tier_raw` preserved verbatim + numeric `tier_rank`. **Not** mapped onto each other — they are different business taxonomies and no mapping was provided |
| Payment | Embedded in transaction; no id, no status | Own file, with `payment_id` and `status` | Surrogate `payment_id` where absent; `status` NULL with a recorded reason rather than a fabricated default |
| Order channel | `channel` (Web / Mobile) | absent | Nullable column; absence documented, not imputed |
| Currency | XML attribute `@currency` | Inside `price{amount, currency}`; absent on JSON `payment` | `COALESCE` cascade: payment → item → product → client default |

---

## Anomalies present in the data

The XML fragments carry comments naming each intended anomaly, which makes them
a usable ground truth for validating the DQ rules:

- Duplicate transaction ids, duplicate order ids, duplicate customers
- Negative quantities, negative unit prices, negative amounts
- Missing fields: email, SKU, order date, order id, transaction id, payment
  method, payment amount, customer name, customer id, item description
- Invalid email formats (`noemail@`)
- Invalid SKUs; a customer id with no matching master record (`C-CUST-9999`)
- **Unexpected extra nested elements, different in nearly every record**:
  `Notes`, `Meta`, `Shipping`, `GiftOptions`, `Warranty`, `Tags`, `Coupons`,
  `ReturnPolicy`, `Audit`, `Preferences`, `metadata`

That last one is the hardest to model and the reason the raw VARIANT is retained
in quarantine: the schema is not stable across records, so unselected paths must
survive for audit rather than being dropped at parse time.

**Last updated**: 2026-08-10 · after PR #1 (bronze)
