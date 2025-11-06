-- =====================================================================
-- PURE DUCKDB SQL ETL: Combined CGM Tracing Builder + Export to SQLite
-- FINAL ROBUST CLI VERSION: Materializes data internally to break the lock
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

---
---------------------------------------
-- 2. VERIFY REQUIRED TABLE EXISTS AND COUNT METADATA
---------------------------------------
-- Step 2a: Check if the table exists
CREATE OR REPLACE TEMP TABLE metadata_table_exists AS
SELECT 
  (SELECT COUNT(*) FROM pragma_table_info('drh.uniform_resource_cgm_file_metadata')) AS table_exists_flag;

-- Step 2b: Count records and combine checks 
CREATE OR REPLACE TEMP TABLE metadata_check AS
SELECT 
  T1.table_exists_flag,
  CASE WHEN T1.table_exists_flag > 0 THEN 
    (SELECT COUNT(*) FROM drh.uniform_resource_cgm_file_metadata)
  ELSE 0 END AS metadata_count
FROM metadata_table_exists AS T1;

-- Show status
SELECT 
  CASE 
    WHEN table_exists_flag = 0 THEN '❌ Table "uniform_resource_cgm_file_metadata" not found. Creating empty view.'
    WHEN metadata_count = 0 THEN '⚠️ Metadata table found but is empty. Creating empty view.'
    ELSE '✅ Metadata records found (' || metadata_count || '). Proceeding with dynamic union.'
  END AS status
FROM metadata_check;

---
---------------------------------------
-- 3. PREPARE LOCAL METADATA VIEW
---------------------------------------
CREATE OR REPLACE TEMP VIEW metadata_local AS
SELECT  
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
  patient_id
FROM drh.uniform_resource_cgm_file_metadata
WHERE (SELECT metadata_count FROM metadata_check) > 0; 

---
---------------------------------------
-- 4. GENERATE UNION QUERY TEXT OR EMPTY VIEW QUERY (WITH QUOTE FIX)
---------------------------------------

CREATE OR REPLACE TEMP VIEW union_query_generator AS
SELECT
    CASE 
        WHEN (SELECT metadata_count FROM metadata_check) > 0 THEN 
            'CREATE OR REPLACE VIEW combined_cgm_tracing AS ' ||
            STRING_AGG(
                'SELECT ' ||
                '''' || T1.tenant_id || ''' AS tenant_id, ' ||
                '''' || T1.study_id || ''' AS study_id, ' ||
                '''' || T1.patient_id || ''' AS participant_id, ' ||
                CASE
                    WHEN T1.map_field_of_cgm_date LIKE '%/%' THEN 
                        'TRY_CAST(STRFTIME(''%Y-%m-%d %H:%M:%S'', datetime('
                        || SPLIT_PART(T1.map_field_of_cgm_date, '/', 1) || ' || ''-'' || printf(''%02d'', ' || SPLIT_PART(T1.map_field_of_cgm_date, '/', 2) || ') || ''-'' || printf(''%02d'', ' || SPLIT_PART(T1.map_field_of_cgm_date, '/', 3) || ')'
                        || ')) AS TIMESTAMP) AS Date_Time'           
                    ELSE            
                        'TRY_CAST(STRFTIME(''%Y-%m-%d %H:%M:%S'', TRY_CAST("' || T1.map_field_of_cgm_date || '" AS TIMESTAMP)) AS TIMESTAMP) AS Date_Time'
                END
                || ', '            
                || 'TRY_CAST("' || T1.map_field_of_cgm_value || '" AS REAL) AS CGM_Value' 
                -- FIX APPLIED HERE: Using single quotes to contain the table name string literal, 
                -- which correctly includes the necessary double quotes for the SQL parser.
                || ' FROM drh."' || 
                'uniform_resource_' || 
                REPLACE(REGEXP_REPLACE(TRIM(LOWER(T1.file_name)), '\.[^\.]+$', '', 'g'), '-', '_') || '"' 
                , ' UNION ALL '
            )
        ELSE 
            'CREATE OR REPLACE VIEW combined_cgm_tracing AS ' ||
            'SELECT ' ||
            'CAST(NULL AS VARCHAR) AS tenant_id, ' ||
            'CAST(NULL AS VARCHAR) AS study_id, ' ||
            'CAST(NULL AS VARCHAR) AS participant_id, ' ||
            'CAST(NULL AS TIMESTAMP) AS Date_Time, ' ||
            'CAST(NULL AS REAL) AS CGM_Value ' ||
            'LIMIT 0'
    END AS final_union_query
FROM metadata_check AS T2 
LEFT JOIN metadata_local AS T1 ON TRUE
GROUP BY T2.metadata_count;
---
---------------------------------------
-- 5. EXPORT THE GENERATED SQL TO A TEMP FILE
---------------------------------------
COPY (
  SELECT final_union_query FROM union_query_generator
) TO '01-execute-cgm-tracing.sql' (HEADER FALSE, DELIMITER '\t', QUOTE '');

---
---------------------------------------
-- 6. EXECUTE THE GENERATED SQL (via .read)
---------------------------------------
.read 01-execute-cgm-tracing.sql

---
---------------------------------------
-- 7. MATERIALIZE AND BREAK DEPENDENCY 💥
---------------------------------------
-- 1. Create a temporary, materialized table in DuckDB (in memory/main db)
--    This reads all data from the view (and therefore the SQLite file) one final time.
CREATE OR REPLACE TEMP TABLE combined_cgm_tracing_materialized AS
SELECT * FROM combined_cgm_tracing;

-- 2. Drop the view, which releases the read lock on the SQLite file.
DROP VIEW IF EXISTS combined_cgm_tracing; 

-- 3. Explicitly detach the SQLite file. This is now safe as no local objects reference it.
DETACH drh;

---
---------------------------------------
-- 8. EXPORT TO SQLITE (RE-ATTACH AND WRITE)
---------------------------------------
-- 1. Re-attach the SQLite DB with the same alias to prepare for writing
ATTACH 'resource-surveillance.sqlite.db' AS drh (TYPE sqlite);

-- 2. Now, drop the old table and export the materialized data (write operation)
DROP TABLE IF EXISTS drh.combined_cgm_tracing_cached;
CREATE TABLE drh.combined_cgm_tracing_cached AS
SELECT *
FROM combined_cgm_tracing_materialized;

---
---------------------------------------
-- 9. SUMMARY
---------------------------------------
SELECT
  (SELECT COUNT(*) FROM combined_cgm_tracing_materialized) AS total_records_in_combined_view,
  (SELECT COUNT(*) FROM drh.combined_cgm_tracing_cached) AS total_records_exported_to_sqlite;

---
---------------------------------------
-- 10. CLEANUP
---------------------------------------
-- Final detach to ensure the write in Section 8 is committed and the lock is fully released
DETACH drh; 

DROP TABLE IF EXISTS combined_cgm_tracing_materialized;
DROP VIEW IF EXISTS metadata_local;
DROP VIEW IF EXISTS union_query_generator;
DROP TABLE IF EXISTS metadata_check;
DROP TABLE IF EXISTS metadata_table_exists;