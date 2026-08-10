/* ============================================================================
   01 · BRONZE — VALIDATION
   ----------------------------------------------------------------------------
   Asserts that the load actually produced what it claims to. Without this, the
   pipeline has a silent-failure mode: if PUT stages nothing (wrong working
   directory) or a PATTERN matches no files, every COPY still reports success
   and every table ends up empty. A run that loads nothing is indistinguishable
   from a run that loads everything, unless something checks.

   Two parts:
     · a view any caller can query to see each check's status
     · a block that raises if any check fails, so the script cannot pass quietly

   Expected counts are hard-coded because the source files are fixed inputs to
   this exercise. That makes this a regression test: if a future change alters
   how many rows survive ingestion, this fails and says which check broke.
   ========================================================================= */

USE ROLE ingestion_engineer;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA bronze;

-- The directory table backs the staged-file check; refresh it before reading.
ALTER STAGE raw_files REFRESH;

CREATE OR REPLACE VIEW v_bronze_validation
COMMENT = 'PASS/FAIL per bronze load invariant. All rows must be PASS.'
AS
WITH checks AS (
    SELECT 'staged_files'            AS check_name, 15   AS expected,
           (SELECT COUNT(*) FROM DIRECTORY(@raw_files))                    AS actual
    UNION ALL
    SELECT 'text_files_loaded',       8,
           (SELECT COUNT(DISTINCT source_file) FROM raw_text_lines)
    UNION ALL
    SELECT 'text_lines',              1701,
           (SELECT COUNT(*) FROM raw_text_lines)
    UNION ALL
    SELECT 'client_a_customers',      23, (SELECT COUNT(*) FROM raw_client_a_customers)
    UNION ALL
    SELECT 'client_a_orders',         21, (SELECT COUNT(*) FROM raw_client_a_orders)
    UNION ALL
    SELECT 'client_a_products',       22, (SELECT COUNT(*) FROM raw_client_a_products)
    UNION ALL
    SELECT 'client_b_customers',      22, (SELECT COUNT(*) FROM raw_client_b_customers)
    UNION ALL
    SELECT 'client_b_orders',         21, (SELECT COUNT(*) FROM raw_client_b_orders)
    UNION ALL
    SELECT 'client_b_products',       18, (SELECT COUNT(*) FROM raw_client_b_products)
    UNION ALL
    SELECT 'client_b_payments',       21, (SELECT COUNT(*) FROM raw_client_b_payments)
    UNION ALL
    -- No exporter footer survived into a business key anywhere.
    SELECT 'no_footer_rows',          0,
           (SELECT COUNT(*) FROM raw_client_a_customers WHERE REGEXP_LIKE(customer_id, '.*OF FILE.*'))
         + (SELECT COUNT(*) FROM raw_client_a_orders    WHERE REGEXP_LIKE(order_id,    '.*OF FILE.*'))
         + (SELECT COUNT(*) FROM raw_client_a_products  WHERE REGEXP_LIKE(sku,         '.*OF FILE.*'))
         + (SELECT COUNT(*) FROM raw_client_b_customers WHERE REGEXP_LIKE(customer_id, '.*OF FILE.*'))
         + (SELECT COUNT(*) FROM raw_client_b_orders    WHERE REGEXP_LIKE(order_id,    '.*OF FILE.*'))
         + (SELECT COUNT(*) FROM raw_client_b_products  WHERE REGEXP_LIKE(sku,         '.*OF FILE.*'))
         + (SELECT COUNT(*) FROM raw_client_b_payments  WHERE REGEXP_LIKE(payment_id,  '.*OF FILE.*'))
    UNION ALL
    -- Blank lines must arrive as '' and not NULL, or the verbatim guarantee the
    -- XML reassembly relies on is not actually held.
    SELECT 'no_null_text_lines',      0,
           (SELECT COUNT(*) FROM raw_text_lines WHERE line_text IS NULL)
    UNION ALL
    -- No carriage returns survived the CRLF source files, on either path.
    SELECT 'no_carriage_returns_text', 0,
           (SELECT COUNT(*) FROM raw_text_lines WHERE CONTAINS(line_text, CHR(13)))
    UNION ALL
    -- The CSVs are the same CRLF files read through a different format, which
    -- also leaves RECORD_DELIMITER unpinned. A stray \r would land on the last
    -- column of each row ('true\r', 'SETTLED\r') and pass every count check.
    SELECT 'no_carriage_returns_csv',  0,
           (SELECT COUNT(*) FROM raw_client_a_customers WHERE CONTAINS(is_active,    CHR(13)))
         + (SELECT COUNT(*) FROM raw_client_a_orders    WHERE CONTAINS(channel,      CHR(13)))
         + (SELECT COUNT(*) FROM raw_client_a_products  WHERE CONTAINS(is_active,    CHR(13)))
         + (SELECT COUNT(*) FROM raw_client_b_customers WHERE CONTAINS(is_active,    CHR(13)))
         + (SELECT COUNT(*) FROM raw_client_b_orders    WHERE CONTAINS(order_status, CHR(13)))
         + (SELECT COUNT(*) FROM raw_client_b_products  WHERE CONTAINS(is_active,    CHR(13)))
         + (SELECT COUNT(*) FROM raw_client_b_payments  WHERE CONTAINS(status,       CHR(13)))
)
SELECT check_name,
       expected,
       actual,
       IFF(actual = expected, 'PASS', 'FAIL') AS status
FROM   checks;

SELECT * FROM v_bronze_validation ORDER BY status, check_name;

/* Fail loudly if anything is off — a green exit code must mean a good load. */
EXECUTE IMMEDIATE $$
DECLARE
    failed  INTEGER;
    bronze_validation_failed EXCEPTION (-20001, 'Bronze validation failed');
BEGIN
    SELECT COUNT(*) INTO :failed FROM v_bronze_validation WHERE status = 'FAIL';
    IF (failed > 0) THEN
        RAISE bronze_validation_failed;
    END IF;
    RETURN 'All bronze checks passed';
END;
$$;
