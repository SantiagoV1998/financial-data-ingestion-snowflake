/* ============================================================================
   01 · BRONZE — UPLOAD SOURCE FILES TO THE STAGE
   ----------------------------------------------------------------------------
   Run from the repository root, with the Snowflake CLI:

       snow sql -c <connection> -f sql/01_bronze/02_upload_files.sql

   PUT reads from the client filesystem, so it needs a client with local access
   (Snowflake CLI or SnowSQL). It cannot run from a Snowsight worksheet — there
   you would upload through the stage's browser interface instead. This is the
   one step of the pipeline that is not pure in-warehouse SQL, and it is
   unavoidable: bytes have to cross the boundary somehow. Everything after this
   point is SQL.

   AUTO_COMPRESS = FALSE is deliberate. The default TRUE appends .gz to every
   staged filename, which then has to be accounted for in every PATTERN and in
   METADATA$FILENAME downstream. These files total ~70 KB; compression buys
   nothing and costs clarity.

   OVERWRITE = TRUE keeps the step re-runnable.
   ========================================================================= */

USE ROLE ingestion_engineer;
USE WAREHOUSE wh_ingestion;
USE DATABASE financial_ingestion;
USE SCHEMA bronze;

/* Clear stale compressed copies before uploading. OVERWRITE only replaces a
   file of the same name, so a path previously staged with AUTO_COMPRESS = TRUE
   would leave Customer.csv.gz sitting beside the new Customer.csv. The COPY
   statements reference stage paths as prefixes, and the raw-text PATTERN
   accepts an optional .gz, so both names would match and every row would load
   twice.

   Scoped to *.gz rather than clearing the whole path. An unqualified REMOVE
   runs before the PUTs and succeeds regardless of the working directory — so
   running this script from anywhere but the repository root, the one failure
   mode the README warns about, would empty the stage while the PUTs fail. The
   next load would then truncate all eight tables and load nothing. */
REMOVE @raw_files/client_a/ PATTERN = '.*[.]gz';
REMOVE @raw_files/client_b/ PATTERN = '.*[.]gz';

PUT 'file://data/client_a/*' @raw_files/client_a/
    AUTO_COMPRESS = FALSE
    OVERWRITE     = TRUE;

PUT 'file://data/client_b/*' @raw_files/client_b/
    AUTO_COMPRESS = FALSE
    OVERWRITE     = TRUE;

-- Expect 15 files: 10 under client_a, 5 under client_b.
LIST @raw_files;
