/* ============================================================================
   03 · GOLD — CANONICAL DATA MODEL (DDL)
   ----------------------------------------------------------------------------
   One structure representing every client's data. No per-client conditionals
   live here: the client-specific shape was resolved in silver, and gold sees a
   single conformed model with a source_system column. A fourth client changes
   silver only.

   SURROGATE KEYS are deterministic hashes — MD5(source_system || '|' || id) —
   not sequences. Rebuilding gold from bronze produces identical keys, so the
   model is reproducible and anything referencing it keeps working. IDENTITY
   columns would renumber on every rebuild.

   The hash includes the source system even though natural keys do not currently
   collide (CUST-A-0001 against C-CUST-5001). Relying on a prefix convention a
   future client is free to ignore is not a design.

   CONSTRAINTS are declared but NOT enforced — Snowflake enforces only NOT NULL.
   They document intent and inform the optimizer. Uniqueness is *produced* by
   silver's deduplication, never assumed from a constraint here.
   ========================================================================= */

USE ROLE ingestion_engineer;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA gold;

/* ---------------------------------------------------------------------------
   dim_source_system — the extension point
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE dim_source_system (
    source_system_key   VARCHAR      NOT NULL,
    source_system       VARCHAR      NOT NULL,
    client_label        VARCHAR,
    delivery_format     VARCHAR,
    notes               VARCHAR,
    CONSTRAINT pk_dim_source_system PRIMARY KEY (source_system_key)
)
COMMENT = 'One row per delivering client. Adding a client adds a row, not a column.';

/* ---------------------------------------------------------------------------
   dim_customer
   ----------------------------------------------------------------------------
   Conflict #1 — name. Client A splits first/last, Client B delivers one field.
   full_name is always populated; the parts are nullable and only present where
   the source provided them. Composing a full name is lossless; splitting one
   is guesswork.

   Conflict #2 — tier. Client A's loyalty_tier is GOLD/SILVER, Client B's
   segment is VIP/REGULAR. These are DIFFERENT TAXONOMIES and no mapping was
   provided, so tier_raw keeps the original verbatim and tier_rank carries a
   comparable ordinal. Asserting GOLD = VIP would invent a business rule nobody
   authorised, and it is unrecoverable once the original is gone.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE dim_customer (
    customer_key        VARCHAR      NOT NULL,
    source_system       VARCHAR      NOT NULL,
    customer_id         VARCHAR      NOT NULL,
    full_name           VARCHAR,
    first_name          VARCHAR,           -- NULL for Client B: not delivered
    last_name           VARCHAR,           -- NULL for Client B: not delivered
    email               VARCHAR,
    email_is_valid      BOOLEAN,
    tier_raw            VARCHAR,           -- GOLD/SILVER or VIP/REGULAR, verbatim
    tier_rank           NUMBER,            -- comparable ordinal, 1 = highest
    signup_source       VARCHAR,           -- Client A only
    is_active           BOOLEAN,
    loaded_at           TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    CONSTRAINT pk_dim_customer PRIMARY KEY (customer_key)
);

/* ---------------------------------------------------------------------------
   dim_product
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE dim_product (
    product_key         VARCHAR      NOT NULL,
    source_system       VARCHAR      NOT NULL,
    sku                 VARCHAR      NOT NULL,
    product_name        VARCHAR,
    category            VARCHAR,
    list_unit_price     NUMBER(18,2),
    currency            VARCHAR,
    is_active           BOOLEAN,
    loaded_at           TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    CONSTRAINT pk_dim_product PRIMARY KEY (product_key)
);

/* ---------------------------------------------------------------------------
   fact_order
   ----------------------------------------------------------------------------
   Conflict #4 — channel. Client A delivers Web/Mobile; Client B does not
   deliver the field at all. Nullable, and the absence is documented rather than
   imputed: "unknown" and "not collected by this client" are different facts.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE fact_order (
    order_key           VARCHAR      NOT NULL,
    source_system       VARCHAR      NOT NULL,
    order_id            VARCHAR      NOT NULL,
    customer_key        VARCHAR,
    order_date          DATE,
    order_status        VARCHAR,
    channel             VARCHAR,           -- NULL for Client B: not delivered
    loaded_at           TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    CONSTRAINT pk_fact_order PRIMARY KEY (order_key),
    CONSTRAINT fk_fact_order_customer FOREIGN KEY (customer_key)
        REFERENCES dim_customer (customer_key)
);

/* ---------------------------------------------------------------------------
   fact_transaction
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE fact_transaction (
    transaction_key     VARCHAR      NOT NULL,
    source_system       VARCHAR      NOT NULL,
    transaction_id      VARCHAR      NOT NULL,
    order_key           VARCHAR,
    customer_key        VARCHAR,
    transaction_date    DATE,
    line_count          NUMBER,
    gross_line_amount   NUMBER(18,2),      -- SUM(quantity * unit_price)
    payment_amount      NUMBER(18,2),      -- as stated by the source
    amount_variance     NUMBER(18,2),      -- payment minus lines; 0 when they agree
    -- Lines this pipeline REJECTed and therefore did not sum. Without it,
    -- amount_variance conflates two different things: a source that disagrees
    -- with itself, and a source we could not fully read. A transaction whose
    -- only line was rejected for a missing SKU shows 100% variance — a break the
    -- source never had.
    rejected_line_count NUMBER,
    variance_is_comparable BOOLEAN,        -- FALSE when lines were rejected
    currency            VARCHAR,
    has_quality_warning BOOLEAN,           -- carries at least one WARN finding
    loaded_at           TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    CONSTRAINT pk_fact_transaction PRIMARY KEY (transaction_key),
    CONSTRAINT fk_fact_transaction_order FOREIGN KEY (order_key)
        REFERENCES fact_order (order_key),
    CONSTRAINT fk_fact_transaction_customer FOREIGN KEY (customer_key)
        REFERENCES dim_customer (customer_key)
);

/* ---------------------------------------------------------------------------
   fact_order_item — the grain that matters
   ----------------------------------------------------------------------------
   Conflict #5 — currency. Client A carries it as an XML attribute on both the
   item price and the payment; Client B nests it under price{} on items and
   omits it entirely on the payment node. Resolved by a coalesce cascade:
   line → product master → transaction. Recorded per line rather than assumed
   uniform, because a delivery mixing currencies would otherwise be silently
   summed together.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE fact_order_item (
    order_item_key      VARCHAR      NOT NULL,
    source_system       VARCHAR      NOT NULL,
    transaction_key     VARCHAR,
    order_key           VARCHAR,
    product_key         VARCHAR,
    sku                 VARCHAR,
    line_number         NUMBER,
    description         VARCHAR,
    quantity            NUMBER,
    unit_price          NUMBER(18,2),
    line_amount         NUMBER(18,2),      -- quantity * unit_price
    currency            VARCHAR,
    is_return_line      BOOLEAN,           -- negative quantity, flagged not dropped
    loaded_at           TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    CONSTRAINT pk_fact_order_item PRIMARY KEY (order_item_key),
    CONSTRAINT fk_fact_order_item_transaction FOREIGN KEY (transaction_key)
        REFERENCES fact_transaction (transaction_key),
    CONSTRAINT fk_fact_order_item_product FOREIGN KEY (product_key)
        REFERENCES dim_product (product_key)
);

/* ---------------------------------------------------------------------------
   fact_payment
   ----------------------------------------------------------------------------
   Conflict #3 — payment shape. Client B delivers a payments file with a
   payment_id and a status. Client A embeds payment inside each transaction with
   neither. A surrogate payment_id is generated where absent, and status stays
   NULL with the reason recorded in payment_status_source — a fabricated
   'UNKNOWN' would read as a real status the client never sent.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE fact_payment (
    payment_key         VARCHAR      NOT NULL,
    source_system       VARCHAR      NOT NULL,
    payment_id          VARCHAR,           -- surrogate where the source has none
    payment_id_is_surrogate BOOLEAN,
    order_key           VARCHAR,
    transaction_key     VARCHAR,
    payment_method      VARCHAR,
    amount              NUMBER(18,2),
    currency            VARCHAR,
    status              VARCHAR,           -- NULL for Client A: not delivered
    status_source       VARCHAR,           -- how status was obtained, or why absent
    is_refund           BOOLEAN,           -- negative amount, flagged not dropped
    -- TRUE when the payment's order carries more than one transaction, so which
    -- transaction it belongs to is this pipeline's choice rather than the
    -- source's statement. Every other ambiguity in this model is flagged —
    -- payment_id_is_surrogate, status_source, variance_is_comparable — and this
    -- one was silent. Two Client A orders already carry two transactions each;
    -- Client B has none today, which is what makes it worth recording now.
    transaction_attribution_is_arbitrary BOOLEAN,
    loaded_at           TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE(),
    CONSTRAINT pk_fact_payment PRIMARY KEY (payment_key)
);

/* ---------------------------------------------------------------------------
   dq_summary — the quality picture, alongside the data rather than beside it
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE dq_summary (
    source_system       VARCHAR,
    entity              VARCHAR,
    severity            VARCHAR,
    rule_code           VARCHAR,
    finding_count       NUMBER,
    loaded_at           TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE()
);

SHOW TABLES IN SCHEMA gold;
