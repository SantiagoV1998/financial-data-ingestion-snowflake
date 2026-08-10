/* ============================================================================
   01 · BRONZE — STAGE AND FILE FORMATS
   ----------------------------------------------------------------------------
   The source files are staged EXACTLY as received. Nothing is cleaned, renamed
   or reformatted outside Snowflake — the brief requires SQL-only ingestion, so
   every repair happens downstream in SQL.

   That constraint is not cosmetic. None of these files parses with Snowflake's
   native semi-structured readers:

     · Every file opens with a banner line:  ----- START OF FILE: x -----
       TYPE = CSV can skip it. TYPE = XML and TYPE = JSON cannot.

     · The seven ClientA_Transactions_* files are fragments of ONE document.
       Only file 1 opens <SalesData>; only file 7 closes it. Files 2-6 are bare
       <Transaction> siblings with no root. TYPE = XML rejects all of them.
       (File 4 also carries a .txt extension while containing XML.)

     · The ClientC transactions.json contains // comments. Comments are not
       legal JSON and no file format option enables them, so TYPE = JSON fails.

   Strategy: land every file as TEXT, one row per physical line, then repair and
   parse in SQL. Reading line-by-line rather than whole-file is deliberate —
   METADATA$FILE_ROW_NUMBER preserves original ordering, which is what makes
   reassembling the seven fragments possible at all.
   ========================================================================= */

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA bronze;

/* ---------------------------------------------------------------------------
   Internal stage — the landing zone for untouched source files
   ------------------------------------------------------------------------ */
CREATE STAGE IF NOT EXISTS raw_files
    DIRECTORY = (ENABLE = TRUE)
    COMMENT   = 'Source files as received from each client. Never modified.';

/* ---------------------------------------------------------------------------
   FILE FORMAT · raw text
   Reads any file as one row per line, with no interpretation whatsoever.
   Used for the XML fragments and the comment-laden JSON.

   Every option here exists to prevent the loader from "helpfully" altering
   bytes:
     FIELD_DELIMITER = NONE          never split a line into columns
     RECORD_DELIMITER = '\n'         one row per physical line
     SKIP_BLANK_LINES = FALSE        blank lines may be structurally relevant
     FIELD_OPTIONALLY_ENCLOSED_BY = NONE   quotes are payload, not syntax
     ESCAPE_UNENCLOSED_FIELD = NONE  default is backslash, which would silently
                                     eat backslashes inside the payload
     TRIM_SPACE = FALSE              indentation is part of the document
   ------------------------------------------------------------------------ */
CREATE OR REPLACE FILE FORMAT ff_raw_text
    TYPE                         = CSV
    FIELD_DELIMITER              = NONE
    RECORD_DELIMITER             = '\n'
    SKIP_BLANK_LINES             = FALSE
    FIELD_OPTIONALLY_ENCLOSED_BY = NONE
    ESCAPE_UNENCLOSED_FIELD      = NONE
    TRIM_SPACE                   = FALSE
    REPLACE_INVALID_CHARACTERS   = TRUE
    COMMENT = 'One row per line, zero interpretation. For files no parser accepts.';

/* ---------------------------------------------------------------------------
   FILE FORMAT · client CSV
   The CSVs are conventional apart from the banner line, so the native reader
   works. SKIP_HEADER = 2 drops the banner and the real header; it counts
   CRLF-delimited lines and ignores the delimiters while doing so.
   SKIP_BLANK_LINES absorbs the empty line that follows the header.

   ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE is a data-quality decision, not
   laziness: a short or long row must reach the quarantine table with a reason
   attached, not abort the batch.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE FILE FORMAT ff_client_csv
    TYPE                           = CSV
    FIELD_DELIMITER                = ','
    SKIP_HEADER                    = 2
    SKIP_BLANK_LINES               = TRUE
    FIELD_OPTIONALLY_ENCLOSED_BY   = '"'
    TRIM_SPACE                     = TRUE
    EMPTY_FIELD_AS_NULL            = TRUE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    REPLACE_INVALID_CHARACTERS     = TRUE
    COMMENT = 'Client master-data CSVs. Skips the exporter banner plus header.';

SHOW FILE FORMATS IN SCHEMA bronze;
