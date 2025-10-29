-- ==============================================================================
-- JSON INSERT QUERY EMITTER (CGM Metadata JSON and CGM data JSON)
-- Generates the dynamic INSERT INTO SQL string and outputs it to a file.
-- ==============================================================================

-- Load the necessary extensions FIRST
-- INSTALL json;
-- LOAD json;
INSTALL sqlite;
LOAD sqlite;
SET autoload_known_extensions=1;

ATTACH '__SQLITE_DB_PATH__' AS sqlite_db_alias;

-- DDL for the target table (run first when this script is executed)
CREATE TABLE IF NOT EXISTS file_meta_ingest_data (
    file_meta_id TEXT NOT NULL,
    db_file_id TEXT NOT NULL,
    tenant_id TEXT NOT NULL,
    tenant_name TEXT NOT NULL,
    participant_display_id TEXT NOT NULL,
    file_meta_data JSON NULL,
    cgm_data JSON
);

-- 2. Define a view containing the metadata and necessary IDs
CREATE OR REPLACE TEMPORARY VIEW cgm_metadata_local AS
SELECT    
    '__DB_FILE_ID__' AS db_file_id,
    '__TENANT_ID__' AS tenant_id,
    '__TENANT_NAME__' AS tenant_name,
    -- FIX: Use GEN_RANDOM_UUID() to create a unique ID for each row, 
    -- as file_meta_id must be unique across the metadata rows.
    GEN_RANDOM_UUID() AS file_meta_id_gen ,
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
FROM sqlite_db_alias.uniform_resource_cgm_file_metadata AS T1;


-- 3. Generate the FINAL INSERT INTO file_meta_ingest_data Query String
CREATE OR REPLACE TEMPORARY VIEW json_insert_generator AS
SELECT
    -- Start the final INSERT statement
    'INSERT INTO file_meta_ingest_data (file_meta_id, db_file_id, tenant_id, tenant_name, participant_display_id, file_meta_data, cgm_data) '
    || IFNULL(
        STRING_AGG(
            '  SELECT '
            || '''' || T1.file_meta_id_gen || '''' || ' AS file_meta_id, ' 
            || '''' || T1.db_file_id || '''' || ' AS db_file_id, ' 
            || '''' || T1.tenant_id || '''' || ', ' || '''' || T1.tenant_name || '''' || ', ' || '''' || T1.patient_id || '''' || ', '
            
            -- 6. file_meta_data (Outer JSON Object)
            || 'TO_JSON_STRING('
                || 'JSON_OBJECT('
                    || '''device_id'', ' || '''' || T1.device_id || '''' || ', '
                    || '''file_name'', ' || '''' || T1.file_name || '''' || ', '
                    || '''devicename'', ' || '''' || T1.devicename || '''' || ', '
                    || '''file_format'', ' || '''' || T1.file_format || '''' || ', '
                    || '''source_platform'', ' || '''' || T1.source_platform || '''' || ', '
                    || '''file_upload_date'', ' || '''' || T1.file_upload_date || '''' || ', '
                    || '''map_field_of_cgm_date'', ' || '''' || T1.map_field_of_cgm_date || '''' || ', '
                    || '''map_field_of_cgm_value'', ' || '''' || T1.map_field_of_cgm_value || '''' || ', '
                    || '''map_field_of_patient_id'', ' || '''' || T1.map_field_of_patient_id || ''''
                || '))' || ' AS file_meta_data, '
                
            -- 7. cgm_data (Inner JSON Array - Correctly wrapped for raw data)
            || '(SELECT TO_JSON_STRING(JSON_ARRAY_AGG(ROW(*))) FROM sqlite_db_alias."uniform_resource_'
            || REPLACE(REGEXP_REPLACE(TRIM(LOWER(T1.file_name)), '\.[^\.]+$', '', 'g'), '-', '_')
            || '"'   -- <<Close the dynamic table name string (e.g., "..._00001")
            
            -- WHERE clause is intentionally omitted to return all raw rows as requested.

            || ')'   -- << Close the entire subquery (SELECT TO_JSON_STRING(...))
            || ' AS cgm_data' -- <<Correctly apply the column alias for the subquery result

            , ' UNION ALL ' -- < This ensures each metadata record generates a separate record via UNION ALL
        ),
        '' -- Empty string if no rows were aggregated
    ) AS final_json_insert_query
FROM cgm_metadata_local AS T1;


-- 4. Final Output: SELECT the generated JSON INSERT query string to the console
-- SELECT final_json_insert_query FROM json_insert_generator;

-- 4.1. Final Output: Write the generated JSON INSERT query string to the specified path
COPY (
    SELECT final_json_insert_query FROM json_insert_generator
) TO '__TEMP_GENERATED_INSERT_SQL_PATH__' (HEADER FALSE, DELIMITER '' , QUOTE '');