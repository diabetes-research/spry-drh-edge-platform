-- ==============================================================================
-- DUCKDB JSON INGEST AND EXPORT (v1.4.1+)
-- This script dynamically generates an INSERT statement to move metadata and
-- raw CGM data (as JSON arrays) from various SQLite tables into a single DuckDB
-- table, executes it, and exports the final generated SQL string.
-- ==============================================================================

-- 1. Setup and Attach SQLite DB
INSTALL sqlite;
LOAD sqlite;
SET autoload_known_extensions=1;

-- This attachment is essential for accessing the source metadata and raw data tables.
ATTACH 'resource-surveillance.sqlite.db' AS drh (TYPE sqlite);
---------------------------------------
-- 2. ULID-LIKE GENERATOR (DuckDB-safe)
---------------------------------------
CREATE OR REPLACE MACRO gen_ulid() AS (
    -- Generates a 26-character string, time-prefix for sortability.
    SUBSTRING(
        REPLACE(
            STRFTIME(NOW(), '%Y%m%d%H%M%S%f') || CAST(ABS(random()) * 1e16 AS VARCHAR),
            '.', '' 
        ), 1, 26
    )
);


-- 1. Generate the single, constant db_file_id for the entire batch
CREATE OR REPLACE TEMPORARY VIEW constant_batch_ids AS
SELECT
    gen_ulid() AS db_file_id_constant;
    
---------------------------------------
-- 3. VERIFY REQUIRED TABLE EXISTS
---------------------------------------
CREATE OR REPLACE TEMP TABLE metadata_exists AS
SELECT COUNT(*) AS exists_flag
FROM pragma_table_info('drh.uniform_resource_cgm_file_metadata');

-- Show a warning if table not found (no RAISE_ERROR in 1.4.1)
-- SELECT
--  CASE WHEN exists_flag = 0 THEN '⚠️ Table "drh.uniform_resource_cgm_file_metadata" not found in SQLite DB'
--    ELSE '✅ CGM Metadata table found'
--  END AS status
-- FROM metadata_exists;


-- 2. DDL for the Target Ingest Table
-- UPDATED: Removed tenant_id and tenant_name columns.
CREATE TABLE IF NOT EXISTS file_meta_ingest_data (
  file_meta_id text not null,
  db_file_id TEXT NOT NULL,
  participant_display_id text NOT NULL,
  file_meta_data TEXT NULL,
  cgm_data TEXT -- Stores the raw CGM rows as a JSON array
);

-- 3. Define a temporary view containing the necessary IDs and metadata
-- UPDATED: Removed selection of tenant_id and study_id.
CREATE OR REPLACE TEMPORARY VIEW cgm_metadata_local AS
SELECT
(select db_file_id_constant from constant_batch_ids limit 1) AS db_file_id,
gen_ulid() AS file_meta_id,
device_id,
file_name,
devicename,
file_format,
source_platform,
file_upload_date,
map_field_of_cgm_date,
map_field_of_cgm_value,
map_field_of_patient_id,
patient_id
FROM drh.uniform_resource_cgm_file_metadata AS T1;


-- 4. Generate the FULL, Executable INSERT INTO Query String (Dynamic Step)
CREATE OR REPLACE TEMPORARY VIEW json_insert_generator AS
SELECT
-- UPDATED: Removed tenant_id and tenant_name from the INSERT header.
'INSERT INTO file_meta_ingest_data (file_meta_id, db_file_id, participant_display_id, file_meta_data, cgm_data) '
|| STRING_AGG(
 'SELECT '
 -- Manual string concatenation (' || ... || ') ensures values are quoted in the generated SQL
 || '''' || T1.file_meta_id || ''' AS file_meta_id, ' -- file_meta_id
 || '''' || T1.db_file_id || ''' AS db_file_id, '  -- db_file_id
 -- REMOVED: Tenant ID and Tenant Name columns from SELECT list.
 || '''' || T1.patient_id || ''' AS participant_display_id, ' -- participant_display_id

 -- file_meta_data JSON object (Native JSON output)
 || 'JSON_OBJECT('
 || '''device_id'', '     || '''' || T1.device_id     || ''', ' -- Fixed with manual quoting
 || '''file_name'', '     || '''' || T1.file_name     || ''', ' -- Fixed with manual quoting
 || '''devicename'', '     || '''' || T1.devicename     || ''', ' -- Fixed with manual quoting
 || '''file_format'', '    || '''' || T1.file_format     || ''', ' -- Fixed with manual quoting
 || '''source_platform'', '  || '''' || T1.source_platform   || ''', ' -- Fixed with manual quoting
 || '''file_upload_date'', '  || '''' || T1.file_upload_date  || ''', ' -- Fixed with manual quoting
 || '''map_field_of_cgm_date'', ' || '''' || T1.map_field_of_cgm_date || ''', ' -- Fixed with manual quoting
 || '''map_field_of_cgm_value'', ' || '''' || T1.map_field_of_cgm_value || ''', ' -- Fixed with manual quoting
 || '''map_field_of_patient_id'', '|| '''' || T1.map_field_of_patient_id  -- Fixed with manual quoting
 || ''') AS file_meta_data, ' -- Added final closing quote for the string

-- cgm_data JSON array (Selects from the dynamically named raw data table)
 -- FINAL FIX FOR 1.4.1: Use STRING_AGG and manual bracket wrapping to create the JSON array.
 || '(SELECT ''['' || STRING_AGG(TO_JSON(T2), '','') || '']'' FROM drh."uniform_resource_'
 || REPLACE(REGEXP_REPLACE(TRIM(LOWER(T1.file_name)), '\\.[^\\.]+$', '', 'g'), '-', '_')
 || '" AS T2) AS cgm_data'

 , ' UNION ALL ' -- Aggregate multiple SELECTs with UNION ALL
) AS final_json_insert_query
FROM cgm_metadata_local AS T1;


-- -- 5. Execute the Generated INSERT Statement
-- -- This is the step that inserts the data into file_meta_ingest_data
-- EXECUTE (SELECT final_json_insert_query FROM json_insert_generator);

-- 6. Final Output: Write the generated SQL string to the specified path
COPY (
SELECT final_json_insert_query FROM json_insert_generator
) TO '02-file-meta-ingest-data-json.sql' (HEADER FALSE, DELIMITER '' , QUOTE '');


---------------------------------------
-- 7. EXECUTE THE GENERATED SQL (via .read)
---------------------------------------
.read 02-file-meta-ingest-data-json.sql

---------------------------------------
-- 8. CHECK RECORD COUNT IN COMBINED VIEW
---------------------------------------
CREATE OR REPLACE TEMP VIEW metadata_count_check AS
SELECT COUNT(*) AS record_count FROM file_meta_ingest_data;

---------------------------------------
-- 9. EXPORT TO SQLITE ONLY IF DATA EXISTS
---------------------------------------
CREATE OR REPLACE TABLE drh.file_meta_ingest_data AS
SELECT *
FROM file_meta_ingest_data
WHERE (SELECT record_count FROM metadata_count_check) > 0;

---------------------------------------
-- 10. SUMMARY
---------------------------------------
-- SELECT
--  (SELECT COUNT(*) FROM file_meta_ingest_data) AS total_records_in_file_meta_ingest_data,
--  (SELECT COUNT(*) FROM drh.file_meta_ingest_data) AS total_records_exported_to_sqlite;


---------------------------------------
-- 11. CLEANUP: DROP TEMP OBJECTS + DELETE TEMP FILE
---------------------------------------
DROP VIEW IF EXISTS cgm_metadata_local;
DROP VIEW IF EXISTS json_insert_generator;
DROP VIEW IF EXISTS metadata_count_check;
DROP TABLE IF EXISTS metadata_exists;