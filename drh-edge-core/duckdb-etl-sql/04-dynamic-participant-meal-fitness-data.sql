-- ==============================================================================
-- DUCKDB ETL: DYNAMIC PARTICIPANT DATA AGGREGATION (FINAL REVISION)
-- Aggregates all meal and fitness data/metadata into a single row for each 
-- participant_display_id using a two-step dynamic SQL generation process.
-- ==============================================================================

INSTALL sqlite;
LOAD sqlite;
SET autoload_known_extensions=1;

ATTACH 'resource-surveillance.sqlite.db' AS drh (TYPE sqlite);

---------------------------------------
-- ULID-LIKE GENERATOR
---------------------------------------
CREATE OR REPLACE MACRO gen_ulid() AS (
    SUBSTRING(
        REPLACE(
            STRFTIME(NOW(), '%Y%m%d%H%M%S%f') || CAST(ABS(random()) * 1e16 AS VARCHAR),
            '.', ''
        ), 1, 26
    )
);

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
) TO '04-participant-meal-fitness-data-dynamic.sql' (HEADER FALSE, DELIMITER '' , QUOTE '');

-- Execute the generated SQL
.read 04-participant-meal-fitness-data-dynamic.sql

---------------------------------------
-- 7. SUMMARY
---------------------------------------
SELECT COUNT(*) AS total_records_inserted_into_participant_meal_fitness_data
FROM participant_meal_fitness_data;


---------------------------------------
-- 8. EXPORT TO SQLITE 
---------------------------------------
-- Create or replace the table in the attached SQLite database
CREATE OR REPLACE TABLE drh.participant_meal_fitness_data AS
SELECT *
FROM participant_meal_fitness_data
;

---------------------------------------
-- 9. FINAL SUMMARY
---------------------------------------
SELECT
 (SELECT COUNT(*) FROM participant_meal_fitness_data) AS total_records_in_participant_meal_fitness_data,
 (SELECT COUNT(*) FROM drh.participant_meal_fitness_data) AS total_records_exported_to_sqlite;


---------------------------------------
-- 10. CLEANUP
---------------------------------------
DROP VIEW IF EXISTS constant_batch_ids;
DROP VIEW IF EXISTS combined_meal_fitness_metadata; 
DROP VIEW IF EXISTS participant_data_grouping;
DROP VIEW IF EXISTS json_insert_fragments;
DROP VIEW IF EXISTS final_insert_query_generator;