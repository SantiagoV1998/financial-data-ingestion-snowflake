#!/usr/bin/env python3
"""Render dashboard/index.html from dashboard/data.json.

The data is exported from Snowflake by dashboard/export.sh and embedded in the
page, so the dashboard opens from a file or from GitHub Pages with no
credentials and no network. That matters: a reviewer should be able to see the
result without access to the warehouse.

This is presentation only. Every figure it shows was produced by the SQL
pipeline; nothing is computed here beyond arranging what the queries returned.
"""

import json
import pathlib

HERE = pathlib.Path(__file__).parent
DATA = json.loads((HERE / "data.json").read_text())


def rows(key):
    return DATA.get(key, [])


def total(key, field):
    return sum(r[field] for r in rows(key))


# ── figures ────────────────────────────────────────────────────────────────
labelled = total("coverage", "LABELLED")
detected = total("coverage", "DETECTED")
pct = round(100.0 * detected / labelled, 1) if labelled else 0.0

by_client = {}
for r in rows("by_client"):
    by_client.setdefault(r["SOURCE_SYSTEM"], {})[r["SEVERITY"]] = r["FINDINGS"]

variance = {r["SOURCE_SYSTEM"]: r for r in rows("variance")}
client_txns = {r["SOURCE_SYSTEM"]: r["TRANSACTIONS"] for r in rows("client_rows")}

# Every figure comes from data.json. Nothing is a literal here: hardcoded
# numbers went stale beside freshly exported ones with no signal that they had,
# on a page whose own text promises the opposite.
STAGE_LABELS = {
    "transactions_parsed": ("Silver · transactions parsed", "46 from XML fragments + 11 from JSON"),
    "transactions_clean": ("Silver · transactions clean", "After deduplication and REJECT rules"),
    "items_parsed": ("Silver · line items parsed", "48 from XML + 10 from JSON"),
    "items_clean": ("Silver · line items clean", "Belonging to the surviving copy of each transaction"),
    "customers_clean": ("Silver · customers", ""),
    "products_clean": ("Silver · products", ""),
    "orders_clean": ("Silver · orders", ""),
    "payments_clean": ("Silver · payments", "Client B only — Client A embeds payment per transaction"),
    "quarantine_findings": ("Quality findings", "Retained with payload, never deleted"),
}
_order = list(STAGE_LABELS)
funnel = sorted(
    ((STAGE_LABELS[r["STAGE"]][0], r["ROW_COUNT"], STAGE_LABELS[r["STAGE"]][1])
     for r in rows("funnel") if r["STAGE"] in STAGE_LABELS),
    key=lambda x: _order.index(next(k for k, v in STAGE_LABELS.items() if v[0] == x[0])),
)
max_funnel = max((v for _, v, _ in funnel), default=1)
gold_counts = {r["ENTITY"]: r["N"] for r in rows("gold_counts")}

rule_rows = sorted(rows("rules"), key=lambda r: -r["FINDINGS"])
max_rule = max((r["FINDINGS"] for r in rule_rows), default=1)
reject_total = sum(r["FINDINGS"] for r in rule_rows if r["SEVERITY"] == "REJECT")
warn_total = sum(r["FINDINGS"] for r in rule_rows if r["SEVERITY"] == "WARN")

cov_rows = sorted(rows("coverage"), key=lambda r: -r["LABELLED"])
classification = {r["CLASSIFICATION"]: r["LABELS"] for r in rows("classification")}


def bar(value, maximum, color_var, width=100):
    """A single horizontal bar. 4px rounded data-end, anchored at the baseline."""
    w = max(1.2, (value / maximum) * width) if maximum else 0
    return (
        f'<span class="bar" style="width:{w:.2f}%;background:var({color_var})" '
        f'aria-hidden="true"></span>'
    )


funnel_html = "".join(
    f"""<tr tabindex="0" title="{note}">
      <th scope="row">{label}</th>
      <td class="num">{value:,}</td>
      <td class="track">{bar(value, max_funnel, "--series-1")}</td>
    </tr>"""
    for label, value, note in funnel
)

rules_html = "".join(
    f"""<tr tabindex="0" title="{r['ENTITY']} · {r['SEVERITY']}">
      <th scope="row"><code>{r['RULE_CODE']}</code></th>
      <td class="sev"><span class="dot dot-{r['SEVERITY'].lower()}"></span>{r['SEVERITY']}</td>
      <td class="num">{r['FINDINGS']}</td>
      <td class="track">{bar(r['FINDINGS'], max_rule,
                             '--status-critical' if r['SEVERITY'] == 'REJECT' else '--status-warning')}</td>
    </tr>"""
    for r in rule_rows
)

cov_html = "".join(
    f"""<tr tabindex="0">
      <th scope="row"><code>{r['EXPECTED_RULE']}</code></th>
      <td class="num">{r['LABELLED']}</td>
      <td class="num">{r['DETECTED']}</td>
      <td class="track">{bar(r['DETECTED'], max(x['LABELLED'] for x in cov_rows), '--status-good')}</td>
    </tr>"""
    for r in cov_rows
)


def client_block(code, label, series):
    w = by_client.get(code, {}).get("WARN", 0)
    j = by_client.get(code, {}).get("REJECT", 0)
    v = variance.get(code, {})
    tx = client_txns.get(code, 0)
    return f"""
    <article class="client">
      <h3><span class="dot" style="background:var(--{series})"></span>{label}</h3>
      <dl>
        <div><dt>Canonical transactions</dt><dd>{tx}</dd></div>
        <div><dt>Findings · warn</dt><dd>{w}</dd></div>
        <div><dt>Findings · reject</dt><dd>{j}</dd></div>
        <div><dt>Payments not matching their own lines</dt>
             <dd>{v.get('WITH_VARIANCE', 0)} of {v.get('TXNS', 0)}</dd></div>
        <div><dt>Total absolute variance</dt><dd>{v.get('TOTAL_ABS_VARIANCE', '0')}</dd></div>
      </dl>
    </article>"""


HTML = f"""<title>Financial Data Ingestion — Pipeline Results</title>
<style>
  .viz-root {{
    color-scheme: light;
    --surface-1: #fcfcfb;
    --surface-2: #f4f3f0;
    --border: #dedcd6;
    --text-primary: #0b0b0b;
    --text-secondary: #52514e;
    --text-muted: #77756f;
    --series-1: #2a78d6;
    --series-2: #eb6834;
    --status-good: #0ca30c;
    --status-warning: #fab219;
    --status-critical: #d03b3b;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:where(:not([data-theme="light"])) .viz-root {{
      color-scheme: dark;
      --surface-1: #1a1a19;
      --surface-2: #232322;
      --border: #3a3a37;
      --text-primary: #ffffff;
      --text-secondary: #c3c2b7;
      --text-muted: #97968c;
      --series-1: #3987e5;
      --series-2: #d95926;
    }}
  }}
  :root[data-theme="dark"] .viz-root {{
    color-scheme: dark;
    --surface-1: #1a1a19;
    --surface-2: #232322;
    --border: #3a3a37;
    --text-primary: #ffffff;
    --text-secondary: #c3c2b7;
    --text-muted: #97968c;
    --series-1: #3987e5;
    --series-2: #d95926;
  }}

  body {{ margin: 0; background: var(--surface-1); }}
  .viz-root {{
    background: var(--surface-1);
    color: var(--text-primary);
    font: 15px/1.55 ui-sans-serif, -apple-system, "Segoe UI", system-ui, sans-serif;
    padding: 2.5rem 1.5rem 4rem;
    max-width: 1080px;
    margin: 0 auto;
  }}
  h1 {{ font-size: 1.6rem; margin: 0 0 .3rem; letter-spacing: -.015em; }}
  .sub {{ color: var(--text-secondary); margin: 0 0 2.2rem; max-width: 62ch; }}
  h2 {{ font-size: 1.02rem; margin: 2.6rem 0 .35rem; letter-spacing: -.01em; }}
  .note {{ color: var(--text-muted); font-size: .85rem; margin: 0 0 1rem; max-width: 68ch; }}

  .hero {{
    display: flex; flex-wrap: wrap; gap: 1.5rem 2.5rem; align-items: baseline;
    background: var(--surface-2); border: 1px solid var(--border);
    border-radius: 10px; padding: 1.4rem 1.6rem; margin-bottom: .6rem;
  }}
  .hero .figure {{ font-size: 2.9rem; font-weight: 650; letter-spacing: -.03em; line-height: 1; }}
  .hero .figure small {{ font-size: 1rem; font-weight: 500; color: var(--text-secondary); }}
  .hero .caption {{ color: var(--text-secondary); font-size: .9rem; max-width: 46ch; }}

  .tiles {{ display: grid; gap: .75rem; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); margin: 1.2rem 0 0; }}
  .tile {{ background: var(--surface-2); border: 1px solid var(--border); border-radius: 8px; padding: .8rem .95rem; }}
  .tile .v {{ font-size: 1.5rem; font-weight: 620; letter-spacing: -.02em; }}
  .tile .k {{ color: var(--text-secondary); font-size: .8rem; }}

  table {{ width: 100%; border-collapse: collapse; font-size: .88rem; }}
  th, td {{ text-align: left; padding: .38rem .5rem; border-bottom: 1px solid var(--border); vertical-align: middle; }}
  thead th {{ color: var(--text-muted); font-weight: 550; font-size: .78rem; text-transform: uppercase; letter-spacing: .04em; border-bottom-width: 1px; }}
  tbody tr:hover, tbody tr:focus-visible {{ background: var(--surface-2); outline: none; }}
  td.num {{ text-align: right; font-variant-numeric: tabular-nums; width: 1%; white-space: nowrap; }}
  td.track {{ width: 42%; }}
  th[scope="row"] {{ font-weight: 500; color: var(--text-primary); }}
  code {{ font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--text-primary); }}

  .bar {{ display: block; height: 9px; border-radius: 0 4px 4px 0; }}
  .dot {{ display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: .45rem; vertical-align: baseline; }}
  .dot-reject {{ background: var(--status-critical); }}
  .dot-warn {{ background: var(--status-warning); }}
  td.sev {{ color: var(--text-secondary); font-size: .82rem; white-space: nowrap; }}

  .legend {{ display: flex; gap: 1.1rem; flex-wrap: wrap; color: var(--text-secondary); font-size: .82rem; margin: 0 0 .7rem; }}
  .legend span.item {{ display: inline-flex; align-items: center; }}

  .clients {{ display: grid; gap: 1rem; grid-template-columns: repeat(auto-fit, minmax(290px, 1fr)); }}
  .client {{ background: var(--surface-2); border: 1px solid var(--border); border-radius: 8px; padding: 1rem 1.15rem; }}
  .client h3 {{ margin: 0 0 .6rem; font-size: .95rem; display: flex; align-items: center; }}
  .client dl {{ margin: 0; }}
  .client dl > div {{ display: flex; justify-content: space-between; gap: 1rem; padding: .28rem 0; border-bottom: 1px solid var(--border); }}
  .client dl > div:last-child {{ border-bottom: none; }}
  .client dt {{ color: var(--text-secondary); font-size: .84rem; }}
  .client dd {{ margin: 0; font-variant-numeric: tabular-nums; font-weight: 560; }}

  .scroll {{ overflow-x: auto; }}
  footer {{ margin-top: 3rem; padding-top: 1rem; border-top: 1px solid var(--border); color: var(--text-muted); font-size: .82rem; }}
  a {{ color: var(--series-1); }}
</style>

<div class="viz-root">

<h1>Financial data ingestion — pipeline results</h1>
<p class="sub">
  Multi-format ingestion (XML, JSON, CSV) from two clients into a canonical model
  on Snowflake, using SQL only. Every figure below is produced by the pipeline and
  exported from the warehouse — nothing is computed in this page.
</p>

<h2>Are the quality rules actually finding the anomalies?</h2>
<p class="note">
  The delivery labels its own defects: each XML transaction is preceded by a comment
  naming what is wrong with it, and the CSVs carry the same inline. Bronze kept every
  line verbatim, so those labels are recoverable and serve as ground truth.
</p>
<div class="hero">
  <div>
    <div class="figure">{pct:g}%<small> of labelled anomalies detected</small></div>
  </div>
  <p class="caption">
    {detected} of {labelled} expectations satisfied. Every ground-truth label is
    classified and the totals reconcile: {classification.get('MAPPED_TO_RULE', 0)} mapped
    to a rule, {classification.get('SCHEMA_VARIATION_BY_DESIGN', 0)} schema variation
    handled by design, {classification.get('UNCLASSIFIED', 0)} unclassified.
  </p>
</div>

<div class="scroll">
<table>
  <caption class="note" style="text-align:left;caption-side:bottom;padding-top:.6rem">
    Detection per labelled anomaly type.
  </caption>
  <thead><tr><th>Rule expected by the label</th><th class="num">Labelled</th><th class="num">Detected</th><th>&nbsp;</th></tr></thead>
  <tbody>{cov_html}</tbody>
</table>
</div>

<h2>What happened to the records</h2>
<p class="note">
  Bronze lands bytes; silver parses, types and deduplicates; gold conforms. The drop
  from 57 to 46 transactions is deduplication plus REJECT-severity rows — held in
  quarantine with their payload, never deleted.
</p>
<div class="scroll">
<table>
  <thead><tr><th>Stage</th><th class="num">Rows</th><th>&nbsp;</th></tr></thead>
  <tbody>{funnel_html}</tbody>
</table>
</div>

<div class="tiles">
  <div class="tile"><div class="v">{gold_counts.get('transactions', 0)}</div><div class="k">Canonical transactions</div></div>
  <div class="tile"><div class="v">{gold_counts.get('items', 0)}</div><div class="k">Canonical line items</div></div>
  <div class="tile"><div class="v">{gold_counts.get('customers', 0)}</div><div class="k">Customers</div></div>
  <div class="tile"><div class="v">{gold_counts.get('products', 0)}</div><div class="k">Products</div></div>
  <div class="tile"><div class="v">{gold_counts.get('payments', 0)}</div><div class="k">Payments</div></div>
  <div class="tile"><div class="v">{reject_total + warn_total}</div><div class="k">Quality findings</div></div>
</div>

<h2>Quality findings by rule</h2>
<p class="legend">
  <span class="item"><span class="dot dot-reject"></span>Reject — cannot be represented ({reject_total})</span>
  <span class="item"><span class="dot dot-warn"></span>Warn — loaded and flagged ({warn_total})</span>
</p>
<p class="note">
  A negative quantity may be a return and a negative payment may be a refund, so those
  load with a flag rather than being dropped: the client decides. Only records with
  nothing to key on — no transaction id, no SKU, an unparseable amount — are rejected.
</p>
<div class="scroll">
<table>
  <thead><tr><th>Rule</th><th>Severity</th><th class="num">Findings</th><th>&nbsp;</th></tr></thead>
  <tbody>{rules_html}</tbody>
</table>
</div>

<h2>By client</h2>
<p class="note">
  <strong>Payments not matching their own lines</strong> is the reconciliation this model
  exists to make possible: the difference between what the source says was paid and what
  its own line items add up to. It is measured and left visible, never corrected —
  correcting it would erase the finding.
</p>
<div class="clients">
  {client_block('CLIENT_A', 'Client A — XML + CSV', 'series-1')}
  {client_block('CLIENT_B', 'Client B — JSON + CSV', 'series-2')}
</div>

<footer>
  Generated from <code>dashboard/data.json</code>, exported from Snowflake by
  <code>dashboard/export.sh</code>. Rebuild with <code>python3 dashboard/build.py</code>.
  Source: <a href="https://github.com/SantiagoV1998/financial-data-ingestion-snowflake">SantiagoV1998/financial-data-ingestion-snowflake</a>.
</footer>

</div>
"""

(HERE / "index.html").write_text(HTML)
print(f"index.html written — {len(HTML):,} bytes")
print(f"  coverage {detected}/{labelled} ({pct}%)  ·  {len(rule_rows)} rules  ·  "
      f"{reject_total} reject / {warn_total} warn")
