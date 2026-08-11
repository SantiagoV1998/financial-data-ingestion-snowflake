/* ============================================================================
   02 · SILVER — PARSE THE UNPARSEABLE DOCUMENTS
   ----------------------------------------------------------------------------
   Turns the raw text lines landed in bronze into one VARIANT per transaction.
   This is where the SQL-only constraint is actually paid for: neither document
   can be read by Snowflake's native parsers, and both are repaired here.

   CLIENT A — seven XML fragments of one document
     File 1 opens <SalesData> AND closes it; file 7 closes it again without
     opening it; files 2-6 carry neither tag. One opening tag against two
     closing ones, so concatenating them yields a premature close mid-document
     and a duplicate close at the end. Both original root tags are discarded and
     a synthetic root wraps the surviving <Transaction> elements.

     Fragments are ordered by a number parsed out of the filename, not
     lexically: _10 would otherwise sort between _1 and _2.

   CLIENT B — JSON with // comments
     Comments are not legal JSON and no file format option accepts them. They
     are stripped per line, with a guard so that "https://..." survives.

   The transaction-level VARIANT is materialised rather than left as a view.
   Two reasons: PARSE_XML over a 46 KB LISTAGG is not free to repeat, and
   quarantine needs the original payload to remain available after a row is
   rejected.
   ========================================================================= */

USE ROLE ingestion_engineer;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA silver;

/* ---------------------------------------------------------------------------
   Client A — one row per <Transaction>
   ----------------------------------------------------------------------------
   FLATTEN over the document root returns 92 children, not 46: XML comments are
   nodes too, and every transaction in this file is preceded by one annotating
   its intended anomaly. Filtering on the element name is what keeps the count
   honest — without it every figure in the deliverable doubles.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE parsed_client_a_transactions AS
WITH fragment_lines AS (
    SELECT
        REGEXP_SUBSTR(source_file, 'ClientA_Transactions_(\\d+)', 1, 1, 'e', 1)::NUMBER
            AS fragment_seq,
        file_row_number,
        line_text
    FROM   bronze.raw_text_lines
    WHERE  source_file ILIKE '%ClientA_Transactions%'
      AND  NOT REGEXP_LIKE(line_text, '^\\s*-{3,}.*OF FILE.*$')     -- exporter banners
      AND  NOT REGEXP_LIKE(TRIM(line_text), '^</?SalesData.*>$')    -- unbalanced roots
),
document AS (
    SELECT PARSE_XML(
             '<SalesData>' ||
             LISTAGG(line_text, '\n') WITHIN GROUP (ORDER BY fragment_seq, file_row_number) ||
             '</SalesData>'
           ) AS doc
    FROM fragment_lines
)
SELECT
    ROW_NUMBER() OVER (ORDER BY f.index)  AS document_position,
    f.value                               AS transaction_xml,
    'CLIENT_A'                            AS source_system,
    SYSDATE()                             AS parsed_at
FROM   document,
       LATERAL FLATTEN(INPUT => doc:"$") f
WHERE  f.value:"@"::VARCHAR = 'Transaction';

/* ---------------------------------------------------------------------------
   Client B — one row per transaction object
   ----------------------------------------------------------------------------
   The (^|[^:]) guard on the comment strip is not decoration: a naive '//.*'
   destroys every URL in the payload. Nothing in this delivery carries one, but
   the next one might, and the cost of the guard is nothing.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE parsed_client_b_transactions AS
WITH cleaned_lines AS (
    SELECT file_row_number,
           REGEXP_REPLACE(line_text, '(^|[^:])//.*$', '\\1') AS line_text
    FROM   bronze.raw_text_lines
    WHERE  source_file ILIKE '%transactions.json'
      AND  NOT REGEXP_LIKE(line_text, '^\\s*-{3,}.*OF FILE.*$')
),
document AS (
    SELECT TRY_PARSE_JSON(
             LISTAGG(line_text, '\n') WITHIN GROUP (ORDER BY file_row_number)
           ) AS doc
    FROM cleaned_lines
)
SELECT
    f.index + 1  AS document_position,
    f.value      AS transaction_json,
    'CLIENT_B'   AS source_system,
    SYSDATE()    AS parsed_at
FROM   document,
       LATERAL FLATTEN(INPUT => doc:transactions) f;

/* ---------------------------------------------------------------------------
   Parse assertions
   ----------------------------------------------------------------------------
   A parse that silently returns fewer rows than the source contains is the
   worst failure available here, because everything downstream still runs. The
   expected counts come from the files themselves:
       grep -c '<Transaction>' data/client_a/*  -> 46
       transactions in the JSON array           -> 11
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_parse_validation AS
SELECT 'client_a_transactions' AS check_name, 46 AS expected,
       (SELECT COUNT(*) FROM parsed_client_a_transactions) AS actual
UNION ALL
SELECT 'client_b_transactions', 11,
       (SELECT COUNT(*) FROM parsed_client_b_transactions)
UNION ALL
-- Every parsed row must be a real element, never NULL from a failed cast.
SELECT 'client_a_no_null_payloads', 0,
       (SELECT COUNT(*) FROM parsed_client_a_transactions WHERE transaction_xml IS NULL)
UNION ALL
SELECT 'client_b_no_null_payloads', 0,
       (SELECT COUNT(*) FROM parsed_client_b_transactions WHERE transaction_json IS NULL);

SELECT check_name, expected, actual,
       IFF(actual = expected, 'PASS', 'FAIL') AS status
FROM   v_parse_validation
ORDER  BY status, check_name;

EXECUTE IMMEDIATE $$
DECLARE
    failed INTEGER;
    parse_validation_failed EXCEPTION (-20002, 'Document parsing did not produce the expected row counts');
BEGIN
    SELECT COUNT(*) INTO :failed
    FROM v_parse_validation WHERE actual <> expected;
    IF (failed > 0) THEN
        RAISE parse_validation_failed;
    END IF;
    RETURN 'Both documents parsed to the expected counts';
END;
$$;
