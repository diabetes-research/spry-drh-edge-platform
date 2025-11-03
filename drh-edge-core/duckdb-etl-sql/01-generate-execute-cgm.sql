-- =====================================================================
-- PURE DUCKDB SQL ETL: Combined CGM Tracing Builder + EXECUTE
-- Uses pragma_execute() to run the dynamically generated UNION query.
-- Compatible with: DuckDB v1.4.1 + SQLite v3.39+
-- =====================================================================

---------------------------------------
-- 0. EXTENSIONS
---------------------------------------
INSTALL sqlite;
LOAD sqlite;
INSTALL json;
LOAD json;

---------------------------------------
-- 1. ATTACH THE SQLITE SOURCE DATABASE
---------------------------------------
ATTACH 'resource-surveillance.sqlite.db' AS drh (TYPE sqlite);

---------------------------------------
-- 2. ULID-LIKE GENERATOR (DuckDB-safe)
---------------------------------------
CREATE OR REPLACE MACRO gen_ulid() AS (
STRFTIME(NOW(), '%Y%m%d%H%M%S') || '-' || CAST(ABS(random()) * 1e16 AS VARCHAR)
);

---------------------------------------
-- 3. VERIFY REQUIRED TABLE EXISTS
---------------------------------------
CREATE OR REPLACE TEMP TABLE metadata_exists AS
SELECT COUNT(*) AS exists_flag
FROM pragma_table_info('drh.uniform_resource_cgm_file_metadata');

-- Show a warning if table not found
SELECT
 CASE WHEN exists_flag = 0 THEN '⚠️ Table "uniform_resource_cgm_file_metadata" not found in SQLite DB'
   ELSE '✅ Metadata table found'
 END AS status
FROM metadata_exists;

---------------------------------------
-- 4. PREPARE LOCAL METADATA VIEW
---------------------------------------
CREATE OR REPLACE TEMP VIEW metadata_local AS
SELECT
 gen_ulid() AS db_file_id,
 gen_ulid() || '-' || CAST(row_number() OVER (ORDER BY file_name) AS TEXT) AS file_meta_id,
 (select party_id from drh.party limit 1) AS tenant_id,
 (select study_id from drh.uniform_resource_study limit 1 )AS study_id,
 device_id,
 file_name,
 devicename,
 file_format,
 source_platform,
 file_upload_date,
 map_field_of_cgm_date,
 map_field_of_cgm_value,
 map_field_of_patient_id,
 patient_id,
  -- Pre-calculate the source table name
  'drh.uniform_resource_' ||
  REPLACE(REGEXP_REPLACE(TRIM(LOWER(file_name)), '\.[^\.]+$', '', 'g'), '-', '_') AS source_table_name
FROM drh.uniform_resource_cgm_file_metadata;

---------------------------------------
-- 5. GENERATE UNION QUERY TEXT
---------------------------------------
CREATE OR REPLACE TEMP VIEW union_query_generator AS
SELECT
 'CREATE OR REPLACE VIEW combined_cgm_tracing AS ' ||
 STRING_AGG(
  'SELECT ' ||
  '''' || tenant_id || ''' AS tenant_id, ' ||
  '''' || study_id || ''' AS study_id, ' ||
  '''' || patient_id || ''' AS participant_id, ' ||
  'TRY_CAST(STRFTIME(''%Y-%m-%d %H:%M:%S'', TRY_CAST("' || map_field_of_cgm_date || '" AS TIMESTAMP)) AS TIMESTAMP) AS Date_Time, ' ||
  'TRY_CAST("' || map_field_of_cgm_value || '" AS REAL) AS CGM_Value ' ||
  'FROM ' || source_table_name,
  ' UNION ALL '
 ) AS final_union_query
FROM metadata_local;

---------------------------------------
-- 6. EXECUTE THE GENERATED SQL (Replaces COPY + .read)
---------------------------------------
-- SELECT
--  'Executing dynamic UNION query via pragma_execute...' AS status,
--  -- EXECUTE is used here to run the SQL string stored in final_union_query
--  pragma_execute(final_union_query) AS execution_result
-- FROM union_query_generator;


   -- OR
   EXECUTE IMMEDIATE (SELECT final_union_query FROM union_query_generator LIMIT 1);
   
---------------------------------------
-- 7. CHECK RECORD COUNT IN COMBINED VIEW
---------------------------------------
CREATE OR REPLACE TEMP VIEW cgm_count_check AS
SELECT COUNT(*) AS record_count FROM combined_cgm_tracing;

---------------------------------------
-- 8. EXPORT TO SQLITE ONLY IF DATA EXISTS
---------------------------------------
-- DuckDB will create the table in the attached SQLite DB (drh)
CREATE OR REPLACE TABLE drh.combined_cgm_tracing_cached AS
SELECT *
FROM combined_cgm_tracing
WHERE (SELECT record_count FROM cgm_count_check) > 0;

---------------------------------------
-- 9. SUMMARY
---------------------------------------
SELECT
 (SELECT COUNT(*) FROM combined_cgm_tracing) AS total_records_in_combined_view,
 (SELECT COUNT(*) FROM drh.combined_cgm_tracing_cached) AS total_records_exported_to_sqlite;


---------------------------------------
-- 10. CLEANUP: DROP TEMP OBJECTS + DETACH
---------------------------------------
DROP VIEW IF EXISTS metadata_local;
DROP VIEW IF EXISTS union_query_generator;
DROP VIEW IF EXISTS cgm_count_check;
DROP TABLE IF EXISTS metadata_exists;

-- Optional: Clean up the attachment
DETACH drh;