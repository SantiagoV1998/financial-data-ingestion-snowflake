/* ============================================================================
   02 · SILVER — EXTRACT TRANSACTIONS TO TABULAR FORM
   ----------------------------------------------------------------------------
   Flattens the parsed VARIANT documents into typed columns: one table for
   transaction headers, one for line items, per client.

   Everything is TRY_CAST. A malformed date or a non-numeric quantity must
   become a row in quarantine with a reason, never an aborted statement — and
   the raw text is kept alongside the cast value so the quarantine rule can
   report what was actually received.

   The client-specific shape stays here. Gold sees one conformed structure.

   TWO XML TRAPS, both of which produce wrong numbers rather than errors:

   1. XMLGET returns an ELEMENT, never a scalar. Text extraction is always two
      steps — XMLGET(v,'tag'):"$"::VARCHAR. Without the cast the value carries
      its JSON quotes ("John" not John) and every downstream join misses.

   2. A repeated element with exactly ONE occurrence is not an array. For 44 of
      the 46 transactions here, Items:"$" is a bare XML element, and FLATTEN
      over it iterates that element's CHILDREN (SKU, Quantity, …) rather than
      the items. Flattening naively yields 4 line items out of 48 — silently,
      with no error. TO_ARRAY normalises both shapes; OUTER => TRUE then keeps
      transactions that have no items at all, which Client B genuinely has.
   ========================================================================= */

USE ROLE ingestion_engineer;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA silver;

/* ---------------------------------------------------------------------------
   Client A · transaction headers
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE stg_client_a_transactions AS
SELECT
    document_position,
    source_system,

    NULLIF(TRIM(XMLGET(transaction_xml, 'TransactionID'):"$"::VARCHAR), '')   AS transaction_id,

    NULLIF(TRIM(XMLGET(XMLGET(transaction_xml, 'Order'), 'OrderID'):"$"::VARCHAR), '')
                                                                             AS order_id,
    XMLGET(XMLGET(transaction_xml, 'Order'), 'OrderDate'):"$"::VARCHAR       AS order_date_raw,
    TRY_TO_DATE(NULLIF(TRIM(XMLGET(XMLGET(transaction_xml, 'Order'), 'OrderDate'):"$"::VARCHAR), ''),
                'YYYY-MM-DD')                                                AS order_date,

    NULLIF(TRIM(XMLGET(XMLGET(XMLGET(transaction_xml, 'Order'), 'Customer'), 'CustomerID'):"$"::VARCHAR), '')
                                                                             AS customer_id,
    NULLIF(
        TRIM(
            XMLGET(
                XMLGET(XMLGET(XMLGET(transaction_xml, 'Order'), 'Customer'), 'Name'), 'FirstName'
            ):"$"::VARCHAR
        ),
        ''
    )
                                                                             AS first_name,
    NULLIF(
        TRIM(
            XMLGET(
                XMLGET(XMLGET(XMLGET(transaction_xml, 'Order'), 'Customer'), 'Name'), 'LastName'
            ):"$"::VARCHAR
        ),
        ''
    )
                                                                             AS last_name,
    NULLIF(TRIM(XMLGET(XMLGET(XMLGET(transaction_xml, 'Order'), 'Customer'), 'Email'):"$"::VARCHAR), '')
                                                                             AS email,
    -- Present in only 1 of 46 transactions; the real tier lives in Customer.csv.
    NULLIF(TRIM(XMLGET(XMLGET(XMLGET(transaction_xml, 'Order'), 'Customer'), 'LoyaltyTier'):"$"::VARCHAR), '')
                                                                             AS loyalty_tier,

    NULLIF(TRIM(XMLGET(XMLGET(transaction_xml, 'Payment'), 'Method'):"$"::VARCHAR), '')
                                                                             AS payment_method,
    XMLGET(XMLGET(transaction_xml, 'Payment'), 'Amount'):"$"::VARCHAR        AS payment_amount_raw,
    TRY_TO_NUMBER(NULLIF(TRIM(XMLGET(XMLGET(transaction_xml, 'Payment'), 'Amount'):"$"::VARCHAR), ''), 18, 2)
                                                                             AS payment_amount,
    -- Currency is an XML ATTRIBUTE here, reached with "@", not an element.
    NULLIF(TRIM(XMLGET(XMLGET(transaction_xml, 'Payment'), 'Amount'):"@currency"::VARCHAR), '')
                                                                             AS payment_currency,

    -- Kept whole: the extra nested elements differ per record (Audit, Shipping,
    -- Notes, Meta, Tags, Coupons, Preferences…) and quarantine needs the
    -- original payload to remain inspectable after a row is rejected.
    transaction_xml                                                          AS raw_payload
FROM parsed_client_a_transactions;

/* ---------------------------------------------------------------------------
   Client A · line items
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE stg_client_a_transaction_items AS
SELECT
    t.document_position,
    t.source_system,
    NULLIF(TRIM(XMLGET(t.transaction_xml, 'TransactionID'):"$"::VARCHAR), '') AS transaction_id,
    i.index + 1                                                              AS line_number,

    NULLIF(TRIM(XMLGET(i.value, 'SKU'):"$"::VARCHAR), '')                    AS sku,
    NULLIF(TRIM(XMLGET(i.value, 'Description'):"$"::VARCHAR), '')            AS description,

    XMLGET(i.value, 'Quantity'):"$"::VARCHAR                                 AS quantity_raw,
    TRY_TO_NUMBER(NULLIF(TRIM(XMLGET(i.value, 'Quantity'):"$"::VARCHAR), ''))         AS quantity,

    XMLGET(i.value, 'UnitPrice'):"$"::VARCHAR                                AS unit_price_raw,
    TRY_TO_NUMBER(NULLIF(TRIM(XMLGET(i.value, 'UnitPrice'):"$"::VARCHAR), ''), 18, 2) AS unit_price,
    NULLIF(TRIM(XMLGET(i.value, 'UnitPrice'):"@currency"::VARCHAR), '')      AS currency,

    i.value                                                                  AS raw_payload
FROM       parsed_client_a_transactions AS t,
LATERAL FLATTEN(INPUT => TO_ARRAY(XMLGET(t.transaction_xml, 'Items'):"$"), OUTER => TRUE) AS i
WHERE  i.value IS NULL OR i.value:"@"::VARCHAR = 'Item';

/* ---------------------------------------------------------------------------
   Client B · transaction headers
   ----------------------------------------------------------------------------
   JSON needs none of the XML gymnastics: an array is always an array, and path
   access returns scalars directly. The one shared hazard is the cast — an
   uncast VARIANT string renders with its quotes.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE stg_client_b_transactions AS
SELECT
    document_position,
    source_system,

    NULLIF(TRIM(transaction_json:id::VARCHAR), '')                    AS transaction_id,

    NULLIF(TRIM(transaction_json:order.id::VARCHAR), '')              AS order_id,
    transaction_json:order.date::VARCHAR                              AS order_date_raw,
    TRY_TO_DATE(NULLIF(TRIM(transaction_json:order.date::VARCHAR), ''), 'YYYY-MM-DD')
                                                                      AS order_date,

    NULLIF(TRIM(transaction_json:order.customer.id::VARCHAR), '')     AS customer_id,
    -- One field, unlike Client A's first_name + last_name. Conforming the two
    -- is gold's problem; silver records what arrived.
    NULLIF(TRIM(transaction_json:order.customer.name::VARCHAR), '')   AS customer_name,
    NULLIF(TRIM(transaction_json:order.customer.email::VARCHAR), '')  AS email,

    NULLIF(TRIM(transaction_json:payment.method::VARCHAR), '')        AS payment_method,
    transaction_json:payment.total::VARCHAR                           AS payment_amount_raw,
    TRY_TO_NUMBER(NULLIF(TRIM(transaction_json:payment.total::VARCHAR), ''), 18, 2)
                                                                      AS payment_amount,
    -- No currency on the JSON payment node at all; Client A carries one as an
    -- attribute. Gold resolves this with a coalesce cascade.
    NULL::VARCHAR                                                     AS payment_currency,

    transaction_json                                                  AS raw_payload
FROM parsed_client_b_transactions;

/* ---------------------------------------------------------------------------
   Client B · line items
   ----------------------------------------------------------------------------
   OUTER => TRUE is load-bearing: one transaction in this delivery has
   "items": [], and without it that transaction would vanish from the item
   table entirely rather than appearing with no lines.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE stg_client_b_transaction_items AS
SELECT
    t.document_position,
    t.source_system,
    NULLIF(TRIM(t.transaction_json:id::VARCHAR), '')          AS transaction_id,
    i.index + 1                                               AS line_number,

    NULLIF(TRIM(i.value:sku::VARCHAR), '')                    AS sku,
    NULLIF(TRIM(i.value:description::VARCHAR), '')            AS description,

    i.value:qty::VARCHAR                                      AS quantity_raw,
    TRY_TO_NUMBER(NULLIF(TRIM(i.value:qty::VARCHAR), ''))     AS quantity,

    i.value:price.amount::VARCHAR                             AS unit_price_raw,
    TRY_TO_NUMBER(NULLIF(TRIM(i.value:price.amount::VARCHAR), ''), 18, 2) AS unit_price,
    NULLIF(TRIM(i.value:price.currency::VARCHAR), '')         AS currency,

    i.value                                                   AS raw_payload
FROM       parsed_client_b_transactions AS t,
LATERAL FLATTEN(INPUT => t.transaction_json:items, OUTER => TRUE) AS i;
