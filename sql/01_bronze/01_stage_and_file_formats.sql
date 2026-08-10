/* ============================================================================
   01 · BRONZE — STAGE AND FILE FORMATS
   ----------------------------------------------------------------------------
   The source files are staged EXACTLY as received. Nothing is cleaned, renamed
   or reformatted outside Snowflake — the brief requires SQL-only ingestion, so
   every repair happens inside the warehouse.

   That constraint is not cosmetic. None of these files parses with Snowflake's
   native semi-structured readers. What the files actually contain, verified
   against the bytes rather than assumed:

     · Exporter artefacts. Nine of the fifteen files open with a banner line
       (----- START OF FILE: x -----): the seven CSVs, ClientA_Transactions_1
       and transactions.json. ClientA_Transactions_2..7 have none. Separately,
       every CSV and three of the other files END with ----- END OF FILE -----.
       Both banner and footer are exporter metadata, not data.

     · The seven ClientA_Transactions_* files are fragments of ONE document,
       but not cleanly split. File 1 opens <SalesData> AND closes it; file 7
       closes it again without ever opening it; files 2-6 carry neither tag.
       That is one opening tag against two closing tags, so concatenating the
       fragments in order yields a premature close mid-document and a duplicate
       close at the end. Both original root tags must be discarded and a
       synthetic root wrapped around the surviving <Transaction> elements.
       (File 4 also carries a .txt extension while containing XML.)

     · transactions.json contains // comments. Comments are not legal JSON and
       no file format option enables them, so TYPE = JSON fails outright.

   Strategy: land every unparseable file as TEXT, one row per physical line,
   then repair and parse in SQL. Line-by-line rather than whole-file is
   deliberate — METADATA$FILE_ROW_NUMBER preserves original ordering, which is
   what makes reassembling the seven fragments possible at all.
   ========================================================================= */

USE ROLE ingestion_engineer;
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

   Every option here exists to stop the loader from altering bytes:
     FIELD_DELIMITER = NONE          never split a line into columns
     SKIP_BLANK_LINES = FALSE        blank lines may be structurally relevant
     FIELD_OPTIONALLY_ENCLOSED_BY = NONE   quotes are payload, not syntax
     ESCAPE_UNENCLOSED_FIELD = NONE  the default is backslash, which would
                                     silently consume backslashes in the payload
     TRIM_SPACE = FALSE              indentation is part of the document
     EMPTY_FIELD_AS_NULL = FALSE     a blank line must arrive as '', not NULL —
                                     the default TRUE turned all 55 blank lines
                                     into NULL, quietly defeating the
                                     SKIP_BLANK_LINES = FALSE two lines above
     NULL_IF = ()                    the default ('\\N') would convert a line
                                     whose entire content is \N into NULL
     REPLACE_INVALID_CHARACTERS = FALSE
                                     TRUE rewrites malformed UTF-8 to U+FFFD,
                                     silently altering bytes at the one point
                                     in the pipeline that must be lossless. A
                                     substitution here would propagate through
                                     the XML reassembly into a transaction
                                     record; better to fail loudly

   RECORD_DELIMITER is left unset. All fifteen source files use CRLF endings,
   and Snowflake resolves \r\n to a single record delimiter — verified by
   loading with the default and with an explicit '\n', both of which yield zero
   carriage returns anywhere in line_text. The parameter is omitted rather than
   pinned simply because the default already expresses the intent "whatever
   this file uses to end a line", which is the honest requirement when ingesting
   files from clients whose export tooling we do not control.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE FILE FORMAT ff_raw_text
    TYPE                         = CSV
    FIELD_DELIMITER              = NONE
    SKIP_BLANK_LINES             = FALSE
    FIELD_OPTIONALLY_ENCLOSED_BY = NONE
    ESCAPE_UNENCLOSED_FIELD      = NONE
    TRIM_SPACE                   = FALSE
    EMPTY_FIELD_AS_NULL          = FALSE
    NULL_IF                      = ()
    REPLACE_INVALID_CHARACTERS   = FALSE
    COMMENT = 'One row per line, zero interpretation. For files no parser accepts.';

/* ---------------------------------------------------------------------------
   FILE FORMAT · client CSV
   The CSVs are conventional between their banner and their footer, so the
   native reader works on the body. SKIP_HEADER = 2 drops the banner and the
   real header; it counts CRLF-delimited lines and ignores the delimiters while
   doing so. SKIP_BLANK_LINES absorbs the empty line that follows the header.

   The trailing ----- END OF FILE ----- line has no equivalent option — there is
   no SKIP_FOOTER — and COPY INTO rejects a WHERE clause in its transformation
   ("COPY statement only supports simple SELECT from stage statements"). It is
   therefore removed immediately after loading, in 04_load_bronze.sql.

   ERROR_ON_COLUMN_COUNT_MISMATCH is deliberately NOT set. Snowflake documents
   that the option "is ignored when transforming data during loading using a
   query", and all seven CSV loads use the transformation form
   FROM (SELECT $1, $2, ... FROM @stage). Setting it would assert a guard that
   does not exist. The transformation form already tolerates ragged rows on its
   own: positions past the field count resolve to NULL, and extra fields are
   simply not selected. One real row in the data relies on this —
   CUST-A-0040,,,,,false carries six fields for a seven-column table.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE FILE FORMAT ff_client_csv
    TYPE                           = CSV
    FIELD_DELIMITER                = ','
    SKIP_HEADER                    = 2
    SKIP_BLANK_LINES               = TRUE
    FIELD_OPTIONALLY_ENCLOSED_BY   = '"'
    TRIM_SPACE                     = TRUE
    EMPTY_FIELD_AS_NULL            = TRUE
    REPLACE_INVALID_CHARACTERS     = TRUE
    COMMENT = 'Client master-data CSVs. Skips the exporter banner plus header.';

SHOW FILE FORMATS IN SCHEMA bronze;
