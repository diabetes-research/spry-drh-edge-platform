-- =====================================================================
-- PURE DUCKDB SQL ETL: Combined CGM, Meal, Fitness Builder + Export to SQLite
-- CONSOLIDATED VERSION: Removed Redundant ATTACH/MACRO definitions
-- =====================================================================

---------------------------------------
-- 0. INITIAL SETUP & EXTENSIONS
---------------------------------------
INSTALL sqlite;
LOAD sqlite;
INSTALL json;
LOAD json;
SET autoload_known_extensions=1;

---------------------------------------
-- 1. ATTACH THE SQLITE SOURCE DATABASE (Initial Attach)
---------------------------------------
ATTACH 'resource-surveillance.sqlite.db' AS drh (TYPE sqlite);

---------------------------------------
-- 2. GLOBAL UTILITY MACRO
---------------------------------------
-- CREATE OR REPLACE MACRO gen_ulid() AS (
--     -- Generates a 26-character string, time-prefix for sortability.
--     SUBSTRING(
--         REPLACE(
--             STRFTIME(NOW(), '%Y%m%d%H%M%S%f') || CAST(ABS(random()) * 1e16 AS VARCHAR),
--             '.', '' 
--         ), 1, 26
--     )
-- );

CREATE OR REPLACE MACRO gen_ulid() AS (
    SUBSTRING(
        REPLACE(
            STRFTIME(CAST(NOW() AS TIMESTAMP), '%Y%m%d%H%M%S%f')
            || CAST(ABS(random()) * 1e16 AS VARCHAR),
            '.',
            ''
        ), 
        1, 
        26
    )
);


---
-- =====================================================================
-- PHASE 1: CGM TRACING DATA AGGREGATION
-- =====================================================================

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
-- 10. CLEANUP (CGM Tracing)
---------------------------------------
-- Final detach to ensure the write in Section 8 is committed and the lock is fully released
DETACH drh; 

DROP TABLE IF EXISTS combined_cgm_tracing_materialized;
DROP VIEW IF EXISTS metadata_local;
DROP VIEW IF EXISTS union_query_generator;
DROP TABLE IF EXISTS metadata_check;
DROP TABLE IF EXISTS metadata_table_exists;

---
-- =====================================================================
-- PHASE 2: CGM JSON INGEST DATA GENERATION
-- =====================================================================

-- RE-ATTACH DB FOR NEXT PHASE
ATTACH 'resource-surveillance.sqlite.db' AS drh (TYPE sqlite);

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


-- 5. Final Output: Write the generated SQL string to the specified path
COPY (
SELECT final_json_insert_query FROM json_insert_generator
) TO '02-file-meta-ingest-data-json.sql' (HEADER FALSE, DELIMITER '' , QUOTE '');


---------------------------------------
-- 6. EXECUTE THE GENERATED SQL (via .read)
---------------------------------------
.read 02-file-meta-ingest-data-json.sql

---------------------------------------
-- 7. CHECK RECORD COUNT IN COMBINED VIEW
---------------------------------------
CREATE OR REPLACE TEMP VIEW metadata_count_check AS
SELECT COUNT(*) AS record_count FROM file_meta_ingest_data;

---------------------------------------
-- 8. EXPORT TO SQLITE ONLY IF DATA EXISTS
---------------------------------------
-- Explicitly detach/re-attach is not strictly necessary here, but often done to ensure 
-- the write lock is cleanly managed if prior steps used a lot of memory.
DETACH drh;
ATTACH 'resource-surveillance.sqlite.db' AS drh (TYPE sqlite);

CREATE OR REPLACE TABLE drh.file_meta_ingest_data AS
SELECT *
FROM file_meta_ingest_data
WHERE (SELECT record_count FROM metadata_count_check) > 0;


---------------------------------------
-- 9. CLEANUP: DROP TEMP OBJECTS
---------------------------------------
DROP VIEW IF EXISTS cgm_metadata_local;
DROP VIEW IF EXISTS json_insert_generator;
DROP VIEW IF EXISTS metadata_count_check;
DROP TABLE IF EXISTS metadata_exists;
DROP VIEW IF EXISTS constant_batch_ids;

---
-- =====================================================================
-- PHASE 3: MEAL AND FITNESS DATA AGGREGATION
-- =====================================================================

-- DETACH and RE-ATTACH to ensure clean state for the next read-heavy operation
DETACH drh;
ATTACH 'resource-surveillance.sqlite.db' AS drh (TYPE sqlite);

---------------------------------------
-- MEAL DATA PROCESSING
---------------------------------------

---------------------------------------
-- 3M. VERIFY REQUIRED MEAL METADATA TABLE EXISTS
---------------------------------------
CREATE OR REPLACE TEMP TABLE metadata_meal_exists AS
SELECT COUNT(*) AS exists_flag
FROM pragma_table_info('drh.uniform_resource_meal_file_metadata');

---------------------------------------
-- 4M. PREPARE LOCAL MEAL METADATA VIEW
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
-- 5M. GENERATE MEAL UNION QUERY TEXT
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
    -- Safe query to create an empty view with the correct schema if no metadata is found
    'SELECT NULL::VARCHAR AS tenant_id, NULL::VARCHAR AS study_id, NULL::VARCHAR AS participant_id, NULL::TIMESTAMP AS meal_time, NULL::REAL AS Calories,NULL::VARCHAR AS  meal_type WHERE 1=0'
  ) AS final_union_query
FROM metadata_meal_local;

---------------------------------------
-- 6M. EXPORT THE MEAL UNION SQL TO A TEMP FILE
---------------------------------------
COPY (
  SELECT final_union_query FROM union_query_meal_generator
) TO '03-execute-meal-tracing.sql' (HEADER FALSE, DELIMITER '\t', QUOTE '');

---------------------------------------
-- 7M. EXECUTE THE GENERATED MEAL SQL (via .read)
---------------------------------------
.read 03-execute-meal-tracing.sql

---------------------------------------
-- 8M. CHECK RECORD COUNT IN COMBINED MEAL VIEW (Unused in logic, kept for logging)
---------------------------------------
CREATE OR REPLACE TEMP VIEW meal_count_check AS
SELECT COUNT(*) AS record_count FROM combined_meal_metadata;

---------------------------------------
-- 9M. EXPORT MEAL DATA TO SQLITE (Always creates the table structure)
---------------------------------------
CREATE OR REPLACE TABLE drh.combined_meal_metadata_cached AS
SELECT *
FROM combined_meal_metadata;

---
---------------------------------------
-- FITNESS DATA PROCESSING
---------------------------------------

---------------------------------------
-- 3F. VERIFY REQUIRED FITNESS METADATA TABLE EXISTS
---------------------------------------
CREATE OR REPLACE TEMP TABLE metadata_fitness_exists AS
SELECT COUNT(*) AS exists_flag
FROM pragma_table_info('drh.uniform_resource_fitness_file_metadata');

---------------------------------------
-- 4F. PREPARE LOCAL FITNESS METADATA VIEW
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
-- 5F. GENERATE FITNESS UNION QUERY TEXT
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
      -- Date and Time field (based on DDL 'date')
      'TRY_CAST("date" AS DATE) AS Date, ' ||
      -- Numeric fields (based on DDL and image)
      'TRY_CAST("steps" AS REAL) AS Steps, ' ||
      'TRY_CAST("exercise_minutes" AS REAL) AS Exercise_Minutes, ' ||
      'TRY_CAST("calories_burned" AS REAL) AS Calories_Burned, ' ||
      'TRY_CAST("distance" AS REAL) AS Distance, ' ||
      'TRY_CAST("heart_rate" AS REAL) AS Heart_Rate' ||
      ' FROM drh.uniform_resource_' ||
      REPLACE(REGEXP_REPLACE(TRIM(LOWER(file_name)), '\.[^\.]+$', '', 'g'), '-', '_'),
      ' UNION ALL '
    ),
    -- Safe query to create an empty view with the correct schema if no metadata is found
    'SELECT NULL::VARCHAR AS tenant_id, NULL::VARCHAR AS study_id, NULL::VARCHAR AS participant_id, NULL::DATE AS Date, NULL::REAL AS Steps, NULL::REAL AS Exercise_Minutes, NULL::REAL AS Calories_Burned, NULL::REAL AS Distance, NULL::REAL AS Heart_Rate WHERE 1=0'
  ) AS final_union_query
FROM metadata_fitness_local;

---------------------------------------
-- 6F. EXPORT THE FITNESS UNION SQL TO A TEMP FILE (CORRECTED FILENAME)
---------------------------------------
COPY (
  SELECT final_union_query FROM union_query_fitness_generator
) TO '04-execute-fitness-tracing.sql' (HEADER FALSE, DELIMITER '\t', QUOTE '');

---------------------------------------
-- 7F. EXECUTE THE GENERATED FITNESS SQL (via .read)
---------------------------------------
.read 04-execute-fitness-tracing.sql

---------------------------------------
-- 8F. CHECK RECORD COUNT IN COMBINED FITNESS VIEW (Unused in logic, kept for logging)
---------------------------------------
CREATE OR REPLACE TEMP VIEW fitness_count_check AS
SELECT COUNT(*) AS record_count FROM combined_fitness_metadata;

---------------------------------------
-- 9F. EXPORT FITNESS DATA TO SQLITE (Always creates the table structure)
---------------------------------------
CREATE OR REPLACE TABLE drh.combined_fitness_metadata_cached AS
SELECT *
FROM combined_fitness_metadata;

---
---------------------------------------
-- 10. CLEANUP (Meal and Fitness Tracing)
---------------------------------------
DROP VIEW IF EXISTS combined_meal_metadata;
DROP VIEW IF EXISTS combined_fitness_metadata;
DROP VIEW IF EXISTS metadata_meal_local;
DROP VIEW IF EXISTS union_query_meal_generator;
DROP VIEW IF EXISTS meal_count_check;
DROP TABLE IF EXISTS metadata_meal_exists;
DROP VIEW IF EXISTS metadata_fitness_local;
DROP VIEW IF EXISTS union_query_fitness_generator;
DROP VIEW IF EXISTS fitness_count_check;
DROP TABLE IF EXISTS metadata_fitness_exists;

---
-- ==============================================================================
-- PHASE 4: DYNAMIC PARTICIPANT DATA AGGREGATION
-- ==============================================================================

-- DETACH and RE-ATTACH to ensure clean state for the final JSON aggregation
DETACH drh;
ATTACH 'resource-surveillance.sqlite.db' AS drh (TYPE sqlite);

-- Generate constant IDs for the batch, prioritizing db_file_id from file_meta_ingest_data
CREATE OR REPLACE TEMPORARY VIEW constant_batch_ids AS
SELECT
    -- Prioritize existing db_file_id, fallback to ULID generation if table is empty/missing
    COALESCE((SELECT db_file_id FROM drh.file_meta_ingest_data LIMIT 1), gen_ulid()) AS db_file_id,
    COALESCE((SELECT party_id FROM drh.party LIMIT 1), 'UNKNOWN') AS tenant_id,
    COALESCE((SELECT study_id FROM drh.uniform_resource_study LIMIT 1), 'UNKNOWN') AS study_display_id;

---------------------------------------
-- Target Table DDL (Ensures it exists)
---------------------------------------
CREATE TABLE IF NOT EXISTS participant_meal_fitness_data (
    db_file_id TEXT,
    tenant_id TEXT,
    study_display_id TEXT,
    fitness_meal_id TEXT,
    participant_display_id TEXT NOT NULL,
    meal_data TEXT DEFAULT '[]',
    fitness_data TEXT DEFAULT '[]',
    fitness_file_metadata TEXT DEFAULT '[]',
    meal_file_metadata TEXT DEFAULT '[]'
);

---------------------------------------
-- 2. Prepare Combined Metadata View (Raw file-level metadata)
---------------------------------------
CREATE OR REPLACE TEMPORARY VIEW combined_meal_fitness_metadata AS
-- 2a. MEAL METADATA
SELECT
    T1.participant_id AS participant_display_id,
    'meal' AS data_type,
    'uniform_resource_' || REPLACE(REGEXP_REPLACE(TRIM(LOWER(T1.file_name)), '\\.[^\\.]+$', '', 'g'), '-', '_') AS raw_data_table_name,
    JSON_OBJECT(
        'meal_meta_id', T1.meal_meta_id,
        'file_name', T1.file_name,
        'source', T1.source,
        'file_format', T1.file_format
    ) AS metadata_json_object
FROM drh.uniform_resource_meal_file_metadata AS T1

UNION ALL

-- 2b. FITNESS METADATA
SELECT
    T2.participant_id AS participant_display_id,
    'fitness' AS data_type,
    'uniform_resource_' || REPLACE(REGEXP_REPLACE(TRIM(LOWER(T2.file_name)), '\\.[^\\.]+$', '', 'g'), '-', '_') AS raw_data_table_name,
    JSON_OBJECT(
        'fitness_meta_id', T2.fitness_meta_id,
        'file_name', T2.file_name,
        'source', T2.source,
        'file_format', T2.file_format
    ) AS metadata_json_object
FROM drh.uniform_resource_fitness_file_metadata AS T2;

---------------------------------------
-- 3. Group by Participant and Aggregate Table Names/Metadata
---------------------------------------
CREATE OR REPLACE TEMPORARY VIEW participant_data_grouping AS
SELECT
    participant_display_id,
    ARRAY_AGG(raw_data_table_name) FILTER (WHERE data_type = 'meal') AS meal_tables,
    ARRAY_AGG(raw_data_table_name) FILTER (WHERE data_type = 'fitness') AS fitness_tables,
    
    -- Aggregate metadata JSON objects into single JSON arrays (string format)
    '[' || STRING_AGG(REPLACE(metadata_json_object::VARCHAR, '''', ''''''), ',') FILTER (WHERE data_type = 'meal') || ']' AS aggregated_meal_metadata_json,
    '[' || STRING_AGG(REPLACE(metadata_json_object::VARCHAR, '''', ''''''), ',') FILTER (WHERE data_type = 'fitness') || ']' AS aggregated_fitness_metadata_json
FROM combined_meal_fitness_metadata
GROUP BY 1;

---------------------------------------
-- 4. Generate Dynamic SQL Fragments (Meal/Fitness Data)
---------------------------------------
CREATE OR REPLACE TEMPORARY VIEW json_insert_fragments AS
SELECT
    T4.participant_display_id,
    T4.aggregated_meal_metadata_json,
    T4.aggregated_fitness_metadata_json,

    -- meal_data: Generate the subquery string or literal '[]'
    CASE WHEN ARRAY_LENGTH(T4.meal_tables) > 0 THEN
        ' (SELECT ''['' || STRING_AGG(TO_JSON(T2), '','') || '']'' FROM ('
        || ARRAY_TO_STRING(
            ARRAY_TRANSFORM(T4.meal_tables, table_name -> 'SELECT * FROM drh."' || table_name || '"'), 
            ' UNION ALL '
        )
        || ') AS T2) '
    ELSE
        '''[]''' 
    END AS meal_data_sql,

    -- fitness_data: Generate the subquery string or literal '[]'
    CASE WHEN ARRAY_LENGTH(T4.fitness_tables) > 0 THEN
        ' (SELECT ''['' || STRING_AGG(TO_JSON(T3), '','') || '']'' FROM ('
        || ARRAY_TO_STRING(
            ARRAY_TRANSFORM(T4.fitness_tables, table_name -> 'SELECT * FROM drh."' || table_name || '"'),
            ' UNION ALL '
        )
        || ') AS T3) '
    ELSE
        '''[]''' 
    END AS fitness_data_sql
FROM participant_data_grouping AS T4;

---------------------------------------
-- 5. Generate the Final Dynamic Insert Query (Combining all fragments)
---------------------------------------
CREATE OR REPLACE TEMPORARY VIEW final_insert_query_generator AS
SELECT
'INSERT INTO participant_meal_fitness_data (db_file_id, tenant_id, study_display_id, fitness_meal_id, participant_display_id, meal_data, fitness_data, meal_file_metadata, fitness_file_metadata) '
|| STRING_AGG(
    'SELECT '
    || '(SELECT db_file_id FROM constant_batch_ids) AS db_file_id, '
    || '(SELECT tenant_id FROM constant_batch_ids) AS tenant_id, '
    || '(SELECT study_display_id FROM constant_batch_ids) AS study_display_id, '
    || '''' || gen_ulid() || ''' AS fitness_meal_id, '
    || '''' || T4.participant_display_id || ''' AS participant_display_id, '
    
    || T4.meal_data_sql || ' AS meal_data, '
    || T4.fitness_data_sql || ' AS fitness_data, '
    
    -- Metadata is already correctly formatted as escaped string literals
    || '''' || T4.aggregated_meal_metadata_json || ''' AS meal_file_metadata, '
    || '''' || T4.aggregated_fitness_metadata_json || ''' AS fitness_file_metadata'

, ' UNION ALL '
) AS final_json_insert_query
FROM json_insert_fragments AS T4;

---------------------------------------
-- 6. Execute the Generated INSERT Statement
---------------------------------------

-- Write the generated SQL string to the specified path
COPY (
SELECT final_json_insert_query FROM final_insert_query_generator
) TO '05-participant-meal-fitness-data-dynamic.sql' (HEADER FALSE, DELIMITER '' , QUOTE '');

-- Execute the generated SQL
.read 05-participant-meal-fitness-data-dynamic.sql

---------------------------------------
-- 7. EXPORT TO SQLITE 
---------------------------------------
-- Create or replace the table in the attached SQLite database
CREATE OR REPLACE TABLE drh.participant_meal_fitness_data AS
SELECT *
FROM participant_meal_fitness_data
;

---------------------------------------
-- 8. FINAL CLEANUP
---------------------------------------
DROP VIEW IF EXISTS constant_batch_ids;
DROP VIEW IF EXISTS combined_meal_fitness_metadata; 
DROP VIEW IF EXISTS participant_data_grouping;
DROP VIEW IF EXISTS json_insert_fragments;
DROP VIEW IF EXISTS final_insert_query_generator;
DETACH drh;