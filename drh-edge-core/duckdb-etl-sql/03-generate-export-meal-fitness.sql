-- =====================================================================
-- PURE DUCKDB SQL ETL: Combined Meal and Fitness Tracing Builder + Export to SQLite
-- Compatible with: DuckDB v1.4.1 + SQLite v3.39+
-- Ensures empty target tables are created if source data is missing/empty.
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
-- CREATE OR REPLACE MACRO gen_ulid() AS (
--  STRFTIME(NOW(), '%Y%m%d%H%M%S') || '-' || CAST(ABS(random()) * 1e16 AS VARCHAR)
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


-- =====================================================================
-- MEAL DATA PROCESSING
-- =====================================================================

---------------------------------------
-- 3M. VERIFY REQUIRED MEAL METADATA TABLE EXISTS
---------------------------------------
CREATE OR REPLACE TEMP TABLE metadata_meal_exists AS
SELECT COUNT(*) AS exists_flag
FROM pragma_table_info('drh.uniform_resource_meal_file_metadata');

-- Show a warning if table not found
-- SELECT
--   CASE WHEN exists_flag = 0 THEN '⚠️ Table "uniform_resource_meal_file_metadata" not found in SQLite DB'
--        ELSE '✅ Meal Metadata table found'
--   END AS status
-- FROM metadata_meal_exists;

---------------------------------------
-- 4M. PREPARE LOCAL MEAL METADATA VIEW
---------------------------------------
CREATE OR REPLACE TEMP VIEW metadata_meal_local AS
SELECT
  -- gen_ulid() AS db_file_id,
  meal_meta_id,
  (select party_id from drh.party limit 1) AS tenant_id,
  (select study_id from drh.uniform_resource_study limit 1 )AS study_id,  
  file_name,  
  file_format,
  source,
  participant_id
FROM drh.uniform_resource_meal_file_metadata
WHERE (SELECT exists_flag FROM metadata_meal_exists) > 0; -- Only select if the table exists

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
-- 8M. CHECK RECORD COUNT IN COMBINED MEAL VIEW
---------------------------------------
CREATE OR REPLACE TEMP VIEW meal_count_check AS
SELECT COUNT(*) AS record_count FROM combined_meal_metadata;

---------------------------------------
-- 9M. EXPORT MEAL DATA TO SQLITE (Always creates the table structure)
---------------------------------------
CREATE OR REPLACE TABLE drh.combined_meal_metadata_cached AS
SELECT *
FROM combined_meal_metadata; -- If the view is empty, the table is created with 0 rows but the correct schema.

---------------------------------------
-- 10M. SUMMARY: MEAL
---------------------------------------
-- SELECT
--   (SELECT COUNT(*) FROM combined_meal_metadata) AS total_meal_records_in_combined_view,
--   (SELECT COUNT(*) FROM drh.combined_meal_metadata_cached) AS total_meal_records_exported_to_sqlite;

---
-- =====================================================================
-- FITNESS DATA PROCESSING
-- =====================================================================

---------------------------------------
-- 3F. VERIFY REQUIRED FITNESS METADATA TABLE EXISTS
---------------------------------------
CREATE OR REPLACE TEMP TABLE metadata_fitness_exists AS
SELECT COUNT(*) AS exists_flag
FROM pragma_table_info('drh.uniform_resource_fitness_file_metadata');

-- Show a warning if table not found
-- SELECT
--   CASE WHEN exists_flag = 0 THEN '⚠️ Table "uniform_resource_fitness_file_metadata" not found in SQLite DB'
--        ELSE '✅ Fitness Metadata table found'
--   END AS status
-- FROM metadata_fitness_exists;

---------------------------------------
-- 4F. PREPARE LOCAL FITNESS METADATA VIEW
---------------------------------------
CREATE OR REPLACE TEMP VIEW metadata_fitness_local AS
SELECT
  -- gen_ulid() AS db_file_id,
  fitness_meta_id,
  (select party_id from drh.party limit 1) AS tenant_id,
  (select study_id from drh.uniform_resource_study limit 1 )AS study_id,
  file_name,  
  file_format,
  source,
  participant_id
FROM drh.uniform_resource_fitness_file_metadata
WHERE (SELECT exists_flag FROM metadata_fitness_exists) > 0; -- Only select if the table exists

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
-- 6F. EXPORT THE FITNESS UNION SQL TO A TEMP FILE
---------------------------------------
COPY (
  SELECT final_union_query FROM union_query_fitness_generator
) TO '03-execute-fitness-tracing.sql' (HEADER FALSE, DELIMITER '\t', QUOTE '');

---------------------------------------
-- 7F. EXECUTE THE GENERATED FITNESS SQL (via .read)
---------------------------------------
.read 03-execute-fitness-tracing.sql

---------------------------------------
-- 8F. CHECK RECORD COUNT IN COMBINED FITNESS VIEW
---------------------------------------
CREATE OR REPLACE TEMP VIEW fitness_count_check AS
SELECT COUNT(*) AS record_count FROM combined_fitness_metadata;

---------------------------------------
-- 9F. EXPORT FITNESS DATA TO SQLITE (Always creates the table structure)
---------------------------------------
CREATE OR REPLACE TABLE drh.combined_fitness_metadata_cached AS
SELECT *
FROM combined_fitness_metadata; -- If the view is empty, the table is created with 0 rows but the correct schema.

---------------------------------------
-- 10F. SUMMARY: FITNESS
---------------------------------------
-- SELECT
--   (SELECT COUNT(*) FROM combined_fitness_metadata) AS total_fitness_records_in_combined_view,
--   (SELECT COUNT(*) FROM drh.combined_fitness_metadata_cached) AS total_fitness_records_exported_to_sqlite;

---

---------------------------------------
-- 11. CLEANUP: DROP TEMP OBJECTS + DELETE TEMP FILES
---------------------------------------
DROP VIEW IF EXISTS metadata_meal_local;
DROP VIEW IF EXISTS union_query_meal_generator;
DROP VIEW IF EXISTS meal_count_check;
DROP TABLE IF EXISTS metadata_meal_exists;
DROP VIEW IF EXISTS metadata_fitness_local;
DROP VIEW IF EXISTS union_query_fitness_generator;
DROP VIEW IF EXISTS fitness_count_check;
DROP TABLE IF EXISTS metadata_fitness_exists;