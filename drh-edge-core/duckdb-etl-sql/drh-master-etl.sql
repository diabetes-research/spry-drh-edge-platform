-- =============================================================================
-- MASTER DUCKDB ETL SCRIPT (v1.4.1+): CORRECTED & CONSOLIDATED
-- Ensures all final tables (CGM Ingest, CGM Tracing, Meal, Fitness) are
-- created with the correct schema, even if source metadata is empty (0 rows).
-- =============================================================================

---------------------------------------
-- SHARED SETUP & ATTACHMENTS
---------------------------------------
INSTALL sqlite;
LOAD sqlite;
INSTALL json;
LOAD json;
SET autoload_known_extensions=1;

-- This attachment is essential for accessing the source metadata and raw data tables.
ATTACH 'resource-surveillance.sqlite.db' AS drh (TYPE sqlite);

---------------------------------------
-- ULID-LIKE GENERATOR (from all scripts)
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

-- Generate the single, constant db_file_id for the entire batch
CREATE OR REPLACE TEMPORARY VIEW constant_batch_ids AS
SELECT
    gen_ulid() AS db_file_id_constant;


-- =============================================================================
-- PHASE 1: FILE METADATA AND RAW JSON INGESTION (from 02-create-file-meta-ingest-data.sql)
-- Ensures drh.file_meta_ingest_data is created (empty or populated).
-- =============================================================================

---------------------------------------
-- 3. VERIFY REQUIRED TABLE EXISTS (from 02)
---------------------------------------
CREATE OR REPLACE TEMP TABLE metadata_exists AS
SELECT COUNT(*) AS exists_flag
FROM pragma_table_info('drh.uniform_resource_cgm_file_metadata');

-- Show a warning if table not found (from 02)
SELECT
CASE WHEN exists_flag = 0 THEN '⚠️ Table "drh.uniform_resource_cgm_file_metadata" not found in SQLite DB'
 ELSE '✅ Metadata table found. Ingesting raw JSON data...'
END AS status
FROM metadata_exists;

-- 2. DDL for the Target Ingest Table (from 02)
-- This table will temporarily hold the ingested data before final export
CREATE TABLE IF NOT EXISTS file_meta_ingest_data (
 file_meta_id text not null,
 db_file_id TEXT NOT NULL,
 participant_display_id text NOT NULL,
 file_meta_data TEXT NULL,
 cgm_data TEXT -- Stores the raw CGM rows as a JSON array
);

-- 3. Define a temporary view containing the necessary IDs and metadata (from 02)
CREATE OR REPLACE TEMPORARY VIEW cgm_metadata_local AS
SELECT
    (select db_file_id_constant from constant_batch_ids limit 1) AS db_file_id,
    gen_ulid() AS file_meta_id,
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
FROM drh.uniform_resource_cgm_file_metadata AS T1;


--------------------------------------
-- CRITICAL STEP: CHECKPOINT METADATA & GENERATED IDs
---------------------------------------
-- Store the temporary view data (including generated IDs) into a DUCKDB TEMPORARY TABLE.
-- This table is safe from DETACH/ATTACH and ensures ID consistency.
CREATE OR REPLACE TEMPORARY TABLE cgm_metadata_checkpoint AS
SELECT * FROM cgm_metadata_local;
DROP VIEW IF EXISTS cgm_metadata_local; -- Clean up temporary view


-- 4.1. Generate the FULL, Executable INSERT INTO Query String (from 02)
CREATE OR REPLACE TEMPORARY VIEW json_insert_generator AS
SELECT
    'INSERT INTO file_meta_ingest_data (file_meta_id, db_file_id, participant_display_id, file_meta_data, cgm_data) '
    -- CRITICAL FIX: Add COALESCE with a fallback empty SELECT to ensure an executable file is always created.
    || COALESCE(
        STRING_AGG(
            'SELECT '
            || '''' || T1.file_meta_id || ''' AS file_meta_id, '
            || '''' || T1.db_file_id || ''' AS db_file_id, '
            || '''' || T1.patient_id || ''' AS participant_display_id, '
            || 'JSON_OBJECT('
            || '''device_id'', '   || '''' || T1.device_id   || ''', '
            || '''file_name'', '   || '''' || T1.file_name   || ''', '
            || '''devicename'', '   || '''' || T1.devicename   || ''', '
            || '''file_format'', '  || '''' || T1.file_format   || ''', '
            || '''source_platform'', ' || '''' || T1.source_platform  || ''', '
            || '''file_upload_date'', ' || '''' || T1.file_upload_date || ''', '
            || '''map_field_of_cgm_date'', ' || '''' || T1.map_field_of_cgm_date || ''', '
            || '''map_field_of_cgm_value'', ' || '''' || T1.map_field_of_cgm_value || ''', '
            || '''map_field_of_patient_id'', '|| '''' || T1.map_field_of_patient_id
            || ''') AS file_meta_data, '
            || '(SELECT ''['' || STRING_AGG(TO_JSON(T2), '','') || '']'' FROM drh."uniform_resource_'
            || REPLACE(REGEXP_REPLACE(TRIM(LOWER(T1.file_name)), '\\.[^\\.]+$', '', 'g'), '-', '_')
            || '" AS T2) AS cgm_data'
        , ' UNION ALL '
        ),
        -- Fallback empty SELECT (if no metadata is found)
        'SELECT NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT WHERE 1=0'
    ) AS final_json_insert_query
FROM cgm_metadata_checkpoint AS T1;


-- 4.2. Final Output: Write the generated SQL string to the specified path (from 02)
COPY (
SELECT final_json_insert_query FROM json_insert_generator
) TO '02-file-meta-ingest-data-json.sql' (HEADER FALSE, DELIMITER '' , QUOTE '');


---------------------------------------
-- 4.3. EXECUTE THE GENERATED SQL (via .read) (from 02)
---------------------------------------
-- This will run the INSERT INTO file_meta_ingest_data command (which may be empty)
.read 02-file-meta-ingest-data-json.sql

---------------------------------------
-- 4.4. CHECK RECORD COUNT IN TEMP TABLE (from 02)
---------------------------------------
CREATE OR REPLACE TEMP VIEW metadata_count_check AS
SELECT COUNT(*) AS record_count FROM file_meta_ingest_data;

---------------------------------------
-- 5. EXPORT FINAL CGM METADATA TO SQLITE (from 02)
---------------------------------------
-- Creates drh.file_meta_ingest_data with 0 rows if record_count is 0, or with data.
CREATE OR REPLACE TABLE drh.file_meta_ingest_data AS
SELECT *
FROM file_meta_ingest_data; -- Always creates the table with the correct schema, even if 0 rows.


-- IMMEDIATE CLEANUP: Drop the temporary table now that the data is safely exported.
DROP TABLE IF EXISTS file_meta_ingest_data;
DROP VIEW IF EXISTS json_insert_generator;

---------------------------------------
-- CRITICAL FIX: DETACH/ATTACH TO CLEAR LOCKS
---------------------------------------
DETACH drh;
ATTACH 'resource-surveillance.sqlite.db' AS drh (TYPE sqlite);


-- =============================================================================
-- PHASE 2: COMBINED CGM TRACING (from 01-generate-execute-export-combined-cgm-tracing.sql)
-- Ensures drh.combined_cgm_tracing_cached is created (empty or populated).
-- =============================================================================

-- DDL: Create the target VIEW (which will be overwritten by the .read)
CREATE OR REPLACE VIEW combined_cgm_tracing AS
SELECT
    NULL::VARCHAR AS tenant_id,
    NULL::VARCHAR AS study_id,
    NULL::VARCHAR AS participant_id,
    NULL::TIMESTAMP AS Date_Time,
    NULL::REAL AS CGM_Value
WHERE 1=0;


---------------------------------------
-- 5.1. GENERATE UNION QUERY TEXT (from 01)
---------------------------------------

CREATE OR REPLACE TEMP VIEW union_query_generator AS
SELECT
 'CREATE OR REPLACE VIEW combined_cgm_tracing AS ' ||
 COALESCE( -- <<< CRITICAL FIX: COALESCE for empty metadata
  STRING_AGG(
   'SELECT ' ||
   '''' || T2.tenant_id || ''' AS tenant_id, ' ||
   '''' || T2.study_id || ''' AS study_id, ' ||
   '''' || T2.patient_id || ''' AS participant_id, ' ||
   'TRY_CAST(STRFTIME(''%Y-%m-%d %H:%M:%S'', TRY_CAST("' || T2.map_field_of_cgm_date || '" AS TIMESTAMP)) AS TIMESTAMP) AS Date_Time, ' ||
   'TRY_CAST("' || T2.map_field_of_cgm_value || '" AS REAL) AS CGM_Value ' ||
   'FROM drh.uniform_resource_' ||
   REPLACE(REGEXP_REPLACE(TRIM(LOWER(T2.file_name)), '\.[^\.]+$', '', 'g'), '-', '_'),
   ' UNION ALL '
  ),
    -- Fallback empty SELECT: Ensures the view schema is correct
  'SELECT NULL::VARCHAR AS tenant_id, NULL::VARCHAR AS study_id, NULL::VARCHAR AS participant_id, NULL::TIMESTAMP AS Date_Time, NULL::REAL AS CGM_Value WHERE 1=0'
 ) AS final_union_query
FROM cgm_metadata_checkpoint AS T2;

---------------------------------------
-- 5.2. EXPORT THE UNION SQL TO A TEMP FILE (from 01)
---------------------------------------
COPY (
 SELECT final_union_query FROM union_query_generator
) TO '01-execute-cgm-tracing.sql' (HEADER FALSE, DELIMITER '\t', QUOTE '');

---------------------------------------
-- 5.3. EXECUTE THE GENERATED SQL (via .read) (from 01)
---------------------------------------
-- This overwrites the dummy view created earlier with the UNION ALL query or the empty fallback.
.read 01-execute-cgm-tracing.sql

---------------------------------------
-- 6. EXPORT FINAL CGM TRACING TO SQLITE (from 01)
---------------------------------------
CREATE OR REPLACE TABLE drh.combined_cgm_tracing_cached AS
SELECT *
FROM combined_cgm_tracing; -- Always creates the table with the correct schema, even if 0 rows.



---------------------------------------
-- CRITICAL FIX 2: DETACH/ATTACH TO CLEAR LOCKS BEFORE MEAL/FITNESS
---------------------------------------
DETACH drh;
ATTACH 'resource-surveillance.sqlite.db' AS drh (TYPE sqlite);


-- =============================================================================
-- PHASE 3: MEAL & FITNESS DATA PROCESSING (from 03-generate-export-meal-fitness.sql)
-- (No change needed here as the COALESCE logic was already present)
-- =============================================================================

-- MEAL DATA PROCESSING
---------------------------------------
-- 3M. VERIFY REQUIRED MEAL METADATA TABLE EXISTS (from 03)
---------------------------------------
CREATE OR REPLACE TEMP TABLE metadata_meal_exists AS
SELECT COUNT(*) AS exists_flag
FROM pragma_table_info('drh.uniform_resource_meal_file_metadata');

-- Show a warning if table not found (from 03)
SELECT
 CASE WHEN exists_flag = 0 THEN '⚠️ Table "uniform_resource_meal_file_metadata" not found in SQLite DB'
   ELSE '✅ Meal Metadata table found. Processing meal data...'
 END AS status
FROM metadata_meal_exists;

-- DDL: Create the target VIEW (which will be overwritten by the .read)
CREATE OR REPLACE VIEW combined_meal_metadata AS
SELECT NULL;


---------------------------------------
-- 4M. PREPARE LOCAL MEAL METADATA VIEW (from 03)
---------------------------------------
CREATE OR REPLACE TEMP VIEW metadata_meal_local AS
SELECT
 meal_meta_id,
 (select party_id from drh.party limit 1) AS tenant_id,
 (select study_id from drh.uniform_resource_study limit 1 )AS study_id,
 file_name,
 file_format,
 source,
 participant_id
FROM drh.uniform_resource_meal_file_metadata
WHERE (SELECT exists_flag FROM metadata_meal_exists) > 0;

---------------------------------------
-- 5M. GENERATE MEAL UNION QUERY TEXT (from 03)
---------------------------------------
CREATE OR REPLACE TEMP VIEW union_query_meal_generator AS
SELECT
 'CREATE OR REPLACE VIEW combined_meal_metadata AS ' ||
 COALESCE(
  STRING_AGG(
   'SELECT ' ||
   '''' || tenant_id || ''' AS tenant_id, ' ||
   '''' || study_id || ''' AS study_id, ' ||
   '''' || participant_id || ''' AS participant_id, ' ||
   'TRY_CAST(STRFTIME(''%Y-%m-%d %H:%M:%S'', TRY_CAST("meal_time" AS TIMESTAMP)) AS TIMESTAMP) AS meal_time, ' ||
   'TRY_CAST("calories" AS REAL) AS Calories, ' ||
   'TRY_CAST("meal_type" AS VARCHAR) AS meal_type' ||
   ' FROM drh.uniform_resource_' ||
   REPLACE(REGEXP_REPLACE(TRIM(LOWER(file_name)), '\.[^\.]+$', '', 'g'), '-', '_'),
   ' UNION ALL '
  ),
  'SELECT NULL::VARCHAR AS tenant_id, NULL::VARCHAR AS study_id, NULL::VARCHAR AS participant_id, NULL::TIMESTAMP AS meal_time, NULL::REAL AS Calories,NULL::VARCHAR AS meal_type WHERE 1=0'
 ) AS final_union_query
FROM metadata_meal_local;

---------------------------------------
-- 6M. EXPORT THE MEAL UNION SQL TO A TEMP FILE (from 03)
---------------------------------------
COPY (
 SELECT final_union_query FROM union_query_meal_generator
) TO '04-execute-meal-tracing.sql' (HEADER FALSE, DELIMITER '\t', QUOTE '');

---------------------------------------
-- 7M. EXECUTE THE GENERATED MEAL SQL (via .read) (from 03)
---------------------------------------
.read 04-execute-meal-tracing.sql

---------------------------------------
-- 9M. EXPORT MEAL DATA TO SQLITE (from 03)
---------------------------------------
CREATE OR REPLACE TABLE drh.combined_meal_metadata_cached AS
SELECT *
FROM combined_meal_metadata;


-- FITNESS DATA PROCESSING
---------------------------------------
-- 3F. VERIFY REQUIRED FITNESS METADATA TABLE EXISTS (from 03)
---------------------------------------
CREATE OR REPLACE TEMP TABLE metadata_fitness_exists AS
SELECT COUNT(*) AS exists_flag
FROM pragma_table_info('drh.uniform_resource_fitness_file_metadata');

-- Show a warning if table not found (from 03)
SELECT
 CASE WHEN exists_flag = 0 THEN '⚠️ Table "uniform_resource_fitness_file_metadata" not found in SQLite DB'
   ELSE '✅ Fitness Metadata table found. Processing fitness data...'
 END AS status
FROM metadata_fitness_exists;

-- DDL: Create the target VIEW
CREATE OR REPLACE VIEW combined_fitness_metadata AS
SELECT NULL;

---------------------------------------
-- 4F. PREPARE LOCAL FITNESS METADATA VIEW (from 03)
---------------------------------------
CREATE OR REPLACE TEMP VIEW metadata_fitness_local AS
SELECT
 fitness_meta_id,
 (select party_id from drh.party limit 1) AS tenant_id,
 (select study_id from drh.uniform_resource_study limit 1 )AS study_id,
 file_name,
 file_format,
 source,
 participant_id
FROM drh.uniform_resource_fitness_file_metadata
WHERE (SELECT exists_flag FROM metadata_fitness_exists) > 0;

---------------------------------------
-- 5F. GENERATE FITNESS UNION QUERY TEXT (from 03)
---------------------------------------
CREATE OR REPLACE TEMP VIEW union_query_fitness_generator AS
SELECT
 'CREATE OR REPLACE VIEW combined_fitness_metadata AS ' ||
 COALESCE(
  STRING_AGG(
   'SELECT ' ||
   '''' || tenant_id || ''' AS tenant_id, ' ||
   '''' || study_id || ''' AS study_id, ' ||
   '''' || participant_id || ''' AS participant_id, ' ||
   'TRY_CAST("date" AS DATE) AS Date, ' ||
   'TRY_CAST("steps" AS REAL) AS Steps, ' ||
   'TRY_CAST("exercise_minutes" AS REAL) AS Exercise_Minutes, ' ||
   'TRY_CAST("calories_burned" AS REAL) AS Calories_Burned, ' ||
   'TRY_CAST("distance" AS REAL) AS Distance, ' ||
   'TRY_CAST("heart_rate" AS REAL) AS Heart_Rate' ||
   ' FROM drh.uniform_resource_' ||
   REPLACE(REGEXP_REPLACE(TRIM(LOWER(file_name)), '\.[^\.]+$', '', 'g'), '-', '_'),
   ' UNION ALL '
  ),
  'SELECT NULL::VARCHAR AS tenant_id, NULL::VARCHAR AS study_id, NULL::VARCHAR AS participant_id, NULL::DATE AS Date, NULL::REAL AS Steps, NULL::REAL AS Exercise_Minutes, NULL::REAL AS Calories_Burned, NULL::REAL AS Distance, NULL::REAL AS Heart_Rate WHERE 1=0'
 ) AS final_union_query
FROM metadata_fitness_local;

---------------------------------------
-- 6F. EXPORT THE FITNESS UNION SQL TO A TEMP FILE (from 03)
---------------------------------------
COPY (
 SELECT final_union_query FROM union_query_fitness_generator
) TO '05-execute-fitness-tracing.sql' (HEADER FALSE, DELIMITER '\t', QUOTE '');

---------------------------------------
-- 7F. EXECUTE THE GENERATED FITNESS SQL (via .read) (from 03)
---------------------------------------
.read 05-execute-fitness-tracing.sql

---------------------------------------
-- 9F. EXPORT FITNESS DATA TO SQLITE (from 03)
---------------------------------------
CREATE OR REPLACE TABLE drh.combined_fitness_metadata_cached AS
SELECT *
FROM combined_fitness_metadata;


-- =============================================================================
-- FINAL SUMMARIES & CLEANUP
-- =============================================================================
SELECT 'Summary of Exports' AS Status;

SELECT
(SELECT COUNT(*) FROM drh.file_meta_ingest_data) AS total_records_exported_to_sqlite_cgm_meta_ingest,
(SELECT COUNT(*) FROM drh.combined_cgm_tracing_cached) AS total_combined_cgm_records_exported_to_sqlite,
(SELECT COUNT(*) FROM drh.combined_meal_metadata_cached) AS total_meal_records_exported_to_sqlite,
(SELECT COUNT(*) FROM drh.combined_fitness_metadata_cached) AS total_fitness_records_exported_to_sqlite;


---------------------------------------
-- 11. CLEANUP: DROP TEMP OBJECTS + DELETE TEMP FILES
---------------------------------------
DROP VIEW IF EXISTS metadata_meal_local;
DROP VIEW IF EXISTS union_query_meal_generator;
DROP TABLE IF EXISTS metadata_meal_exists;
DROP VIEW IF EXISTS metadata_fitness_local;
DROP VIEW IF EXISTS union_query_fitness_generator;
DROP TABLE IF EXISTS metadata_fitness_exists;
DROP VIEW IF EXISTS cgm_metadata_local;
DROP VIEW IF EXISTS json_insert_generator;
DROP TABLE IF EXISTS metadata_exists;
DROP VIEW IF EXISTS union_query_generator;
DROP VIEW IF EXISTS combined_cgm_tracing;
DROP VIEW IF EXISTS combined_meal_metadata;
DROP VIEW IF EXISTS combined_fitness_metadata;
DROP MACRO IF EXISTS gen_ulid;

