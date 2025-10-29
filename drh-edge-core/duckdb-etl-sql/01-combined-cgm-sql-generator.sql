-- ==============================================================================
-- DUCKDB ETL SCRIPT: DYNAMICALLY INGEST CGM DATA FROM SQLITE
--
-- This script relies entirely on external shell substitution for dynamic values.
-- It eliminates the need for internal SET commands and dynamic SQL generation
-- (which caused previous Catalog Errors).
--
-- PLACEHOLDERS (Must be replaced by the external runner):
-- 1. __SQLITE_DB_PATH__: Path to the resource-surveillance.sqlite.db file.
-- 2. __DB_FILE_ID__: Global unique ID for this ingestion batch (UUID string).
-- 3. __TENANT_ID__: Tenant/Client ID string.
-- 4. __TENANT_NAME__: Tenant/Client Name string.
-- 5. __UNION_ALL_QUERY__: The full dynamically generated UNION ALL SQL string.
-- ==============================================================================

-- 0. Extension and Configuration Setup
--------------------------------------
-- Explicitly install and load required extensions for JSON manipulation and SQLite access.
INSTALL json;
LOAD json;
INSTALL sqlite;
LOAD sqlite;


-- 1. Attach the SQLite database
----------------------------------
ATTACH '__SQLITE_DB_PATH__' AS sqlite_db_alias;


-- 2. Ingestion Core Logic - Setup Temporary View (Resolves Catalog Error)
-----------------------------------

-----------------------------------
-- A. Create a Temporary View of the metadata.
CREATE OR REPLACE TEMPORARY VIEW metadata_local AS
    SELECT
        -- Use the provided global ID and standard text concatenation for file_meta_id
        '__DB_FILE_ID__' AS db_file_id,
        '__DB_FILE_ID__' || '-' || CAST(row_number() OVER (ORDER BY file_name) AS TEXT) AS file_meta_id,
        '__TENANT_ID__' AS tenant_id,
        '__TENANT_NAME__' AS tenant_name,
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


-- B. Generate the UNION ALL Query String (Standardized Schema Generation)
CREATE OR REPLACE TEMPORARY VIEW union_query_generator AS
    SELECT
        -- ✅ CORRECTION: Removed the opening parenthesis '(' after AS 
        'CREATE OR REPLACE VIEW combined_cgm_tracing AS ' || 
        STRING_AGG(
            -- We explicitly select and alias the required mapped fields to guarantee a consistent schema.
            'SELECT '
            -- 1. CGM Date (Standardized as Date_Time) - Incorporates conditional splitting logic
            || CASE
                -- Replicate TS/JS logic: if (mapFieldOfCGMDate.includes("/"))
                WHEN T1.map_field_of_cgm_date LIKE '%/%' THEN 
                    'TRY_CAST(STRFTIME(''%Y-%m-%d %H:%M:%S'', datetime('
                    || SPLIT_PART(T1.map_field_of_cgm_date, '/', 1) || ' || ''-'' || printf(''%02d'', ' || SPLIT_PART(T1.map_field_of_cgm_date, '/', 2) || ') || ''-'' || printf(''%02d'', ' || SPLIT_PART(T1.map_field_of_cgm_date, '/', 3) || ')'
                    || ')) AS TIMESTAMP) AS Date_Time'
                -- Replicate TS/JS logic: else { strftime('%Y-%m-%d %H:%M:%S', ... ) }
                ELSE 
                    -- Standard conversion to canonical TIMESTAMP format
                    -- FIX: Add double quotes around the column name (T1.map_field_of_cgm_date)
                    'TRY_CAST(STRFTIME(''%Y-%m-%d %H:%M:%S'', TRY_CAST("' || T1.map_field_of_cgm_date || '" AS TIMESTAMP)) AS TIMESTAMP) AS Date_Time'
            END
            || ', '
            -- 2. CGM Value (Standardized as CGM_Value)
            -- FIX: Add double quotes around the column name (T1.map_field_of_cgm_value)
            -- NOTE: If map_field_of_cgm_value itself contains spaces (e.g., 'Sensor Glucose (mg/dL)'), 
            -- it MUST be enclosed in double quotes for DuckDB. I'll add them here for safety.
            || 'TRY_CAST("' || T1.map_field_of_cgm_value || '" AS REAL) AS CGM_Value, '
            
            -- 3. Tenant ID (Static)
            || '''' || '__TENANT_ID__' || '''' || ' AS tenant_id, '
            
            -- 4. Participant ID (Directly from metadata T1.patient_id)
            || '''' || T1.patient_id || '''' || ' AS participant_id '

            
            -- 5. From the source table (Table name sanitization logic)
            || 'FROM sqlite_db_alias.uniform_resource_' || REPLACE(REGEXP_REPLACE(TRIM(lower(T1.file_name)), '\.[^\.]+$', '', 'g'), '-', '_'),
            ' UNION ALL '
        )
        -- ✅ CORRECTION: Removed the closing parenthesis ')'
        AS final_union_query 
    FROM metadata_local AS T1;

-- C. Final Output: Select the generated SQL string
COPY (
    SELECT final_union_query FROM union_query_generator
) TO '__TEMP_VIEW_SQL_PATH__' (HEADER FALSE, DELIMITER '' , QUOTE '');