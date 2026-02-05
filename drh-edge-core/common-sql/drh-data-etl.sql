-- =====================================================================
-- EDGE FUNCTIONAL VIEWS
-- =====================================================================

DROP VIEW IF EXISTS drh_participant_file_names;
CREATE VIEW drh_participant_file_names AS
SELECT
    patient_id,
    -- Converted STRING_AGG to GROUP_CONCAT
    GROUP_CONCAT(file_name, ', ') AS file_names
FROM drh_cgm_file_metadata
GROUP BY patient_id;


DROP VIEW IF EXISTS drh_study_vanity_metrics_details;
CREATE VIEW
    drh_study_vanity_metrics_details AS
SELECT
    s.tenant_id,
    s.study_id,
    s.study_name,
    s.study_description,
    s.start_date,
    s.end_date,
    s.nct_number,
    COUNT(DISTINCT p.participant_id) AS total_number_of_participants,
    ROUND(AVG(p.age), 2) AS average_age,
    ROUND(
        (CAST(SUM(CASE WHEN p.gender = 'F' THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*)) * 100, 
        1
    ) AS percentage_of_females,    
    
    ROUND(
        (CAST(SUM(CASE WHEN p.gender = 'M' THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*)) * 100, 
        1
    ) AS percentage_of_males,
    GROUP_CONCAT (DISTINCT i.investigator_name) AS investigators
FROM
    drh_study s
    LEFT JOIN drh_participant p ON s.study_id = p.study_id
    LEFT JOIN drh_investigator i ON s.study_id = i.study_id
GROUP BY
    s.study_id,
    s.study_name,
    s.study_description,
    s.start_date,
    s.end_date,
    s.nct_number;


DROP VIEW IF EXISTS drh_raw_cgm_table_lst;
CREATE VIEW
    drh_raw_cgm_table_lst AS
SELECT
    raw_file_name as file_name    
FROM
    drh_raw_cgm_tracing;


DROP VIEW IF EXISTS study_wise_number_cgm_raw_files_count;
CREATE VIEW
    drh_number_cgm_count AS
SELECT
    count(*) as number_of_cgm_raw_files
FROM
    drh_raw_cgm_tracing;


-- Drops and recreates the view to count the number of distinct files per device name (duplicate of VIEW 12).
DROP VIEW IF EXISTS drh_device_file_count_view;

CREATE VIEW
    drh_device_file_count_view AS
SELECT
    devicename,
    COUNT(DISTINCT file_name) AS number_of_files
FROM
    drh_cgm_file_metadata
GROUP BY
    devicename
ORDER BY
    number_of_files DESC;

--drh_study_files_table_info

-- =====================================================================
-- ETL VIEWS
-- =====================================================================


DROP VIEW IF EXISTS combined_cgm_tracing;
CREATE VIEW IF NOT EXISTS combined_cgm_tracing AS
WITH joined_data AS (
    SELECT 
        m.tenant_id, m.study_id, m.patient_id, 
        m.map_field_of_cgm_date, m.map_field_of_cgm_value,
        r.raw_data_payload
    FROM drh_cgm_file_metadata m
    JOIN drh_raw_cgm_tracing r ON (
        LOWER(TRIM(CASE WHEN INSTR(r.raw_file_name, '.') > 0 THEN SUBSTR(r.raw_file_name, 1, INSTR(r.raw_file_name, '.') - 1) ELSE r.raw_file_name END)) 
        = 
        LOWER(TRIM(CASE WHEN INSTR(m.file_name, '.') > 0 THEN SUBSTR(m.file_name, 1, INSTR(m.file_name, '.') - 1) ELSE m.file_name END))
    )
)
SELECT 
    tenant_id, 
    study_id, 
    patient_id AS participant_id,    
    strftime('%Y-%m-%d %H:%M:%S', json_extract(p.value, '$."' || map_field_of_cgm_date || '"')) AS Date_Time,
    CAST(json_extract(p.value, '$."' || map_field_of_cgm_value || '"') AS REAL) AS CGM_Value
FROM joined_data, json_each(raw_data_payload) AS p;


DROP TABLE IF EXISTS combined_cgm_tracing_cached;
CREATE TABLE combined_cgm_tracing_cached AS
SELECT *
FROM combined_cgm_tracing;

DROP VIEW IF EXISTS combined_meal_data;
CREATE VIEW combined_meal_data AS
WITH joined_data AS (
    SELECT        
        (SELECT tenant_id FROM drh_study LIMIT 1) AS tenant_id,
        (SELECT study_id FROM drh_study LIMIT 1) AS study_id,
        m.participant_id, 
        r.raw_data_payload
    FROM drh_meal_file_metadata m
    JOIN drh_raw_meal_data r ON (        
        LOWER(TRIM(CASE 
            WHEN INSTR(r.raw_file_name, '.') > 0 
            THEN SUBSTR(r.raw_file_name, 1, INSTR(r.raw_file_name, '.') - 1) 
            ELSE r.raw_file_name 
        END)) 
        = 
        LOWER(TRIM(CASE 
            WHEN INSTR(m.file_name, '.') > 0 
            THEN SUBSTR(m.file_name, 1, INSTR(m.file_name, '.') - 1) 
            ELSE m.file_name 
        END))
        OR         
        LOWER(TRIM(r.raw_file_name)) LIKE '%' || LOWER(TRIM(m.file_name))
    )
)
SELECT 
    j.tenant_id, 
    j.study_id, 
    j.participant_id,        
    strftime('%Y-%m-%d %H:%M:%S', json_extract(p.value, '$.meal_time')) AS Meal_Time,
    CAST(json_extract(p.value, '$.calories') AS REAL) AS Calories,
    json_extract(p.value, '$.meal_type') AS Meal_Type
FROM joined_data j
CROSS JOIN json_each(j.raw_data_payload) AS p;


DROP TABLE IF EXISTS combined_meal_data_cached;
CREATE TABLE combined_meal_data_cached AS
SELECT *
FROM combined_meal_data;


DROP VIEW IF EXISTS combined_fitness_data;
CREATE VIEW combined_fitness_data AS
WITH joined_data AS (
    SELECT 
        (SELECT tenant_id FROM drh_study LIMIT 1) AS tenant_id,
        (SELECT study_id FROM drh_study LIMIT 1) AS study_id,
        m.participant_id, 
        r.raw_data_payload
    FROM drh_fitness_file_metadata m
    JOIN drh_raw_fitness_data r ON (                
        LOWER(TRIM(CASE 
            WHEN INSTR(r.raw_file_name, '.') > 0 
            THEN SUBSTR(r.raw_file_name, 1, INSTR(r.raw_file_name, '.') - 1) 
            ELSE r.raw_file_name 
        END)) 
        = 
        LOWER(TRIM(CASE 
            WHEN INSTR(m.file_name, '.') > 0 
            THEN SUBSTR(m.file_name, 1, INSTR(m.file_name, '.') - 1) 
            ELSE m.file_name 
        END))
        OR         
        LOWER(TRIM(r.raw_file_name)) LIKE '%' || LOWER(TRIM(m.file_name))
    )
)
SELECT 
    j.tenant_id, 
    j.study_id, 
    j.participant_id,        
    strftime('%Y-%m-%d %H:%M:%S', json_extract(p.value, '$.date')) AS Date_Time,    
    CAST(json_extract(p.value, '$.steps') AS INTEGER) AS Steps,
    CAST(json_extract(p.value, '$.exercise_minutes') AS REAL) AS Exercise_Minutes,
    CAST(json_extract(p.value, '$.calories_burned') AS REAL) AS Calories_Burned,
    CAST(json_extract(p.value, '$.distance') AS REAL) AS Distance,
    CAST(json_extract(p.value, '$.heart_rate') AS REAL) AS Heart_Rate
FROM joined_data j
CROSS JOIN json_each(j.raw_data_payload) AS p;


DROP TABLE IF EXISTS combined_fitness_data_cached;
CREATE TABLE combined_fitness_data_cached AS
SELECT *
FROM combined_fitness_data;


---------------------------------------
-- file_meta_ingest_data
---------------------------------------
DROP TABLE IF EXISTS constant_batch_ids;
CREATE TEMP TABLE constant_batch_ids AS
SELECT 
    printf('%012x', (strftime('%s', 'now') * 1000)) || lower(hex(randomblob(8))) AS db_file_id,
    (SELECT tenant_id FROM drh_study LIMIT 1) AS tenant_id,
    (SELECT study_id FROM drh_study LIMIT 1) AS study_display_id;


DROP TABLE IF EXISTS file_meta_ingest_data;
CREATE TABLE IF NOT EXISTS file_meta_ingest_data (
  file_meta_id TEXT PRIMARY KEY,
  db_file_id TEXT NOT NULL,
  participant_display_id TEXT NOT NULL,
  file_meta_data TEXT NULL,
  cgm_data TEXT -- Stores the raw CGM rows as a JSON array
);


INSERT INTO file_meta_ingest_data (
    file_meta_id, 
    db_file_id, 
    participant_display_id, 
    file_meta_data, 
    cgm_data
)
WITH raw_combined AS (
    SELECT 
        m.patient_id,
        m.device_id,
        m.file_name,
        m.devicename,
        m.file_format,
        m.source_platform,
        m.file_upload_date,
        m.map_field_of_cgm_date,
        m.map_field_of_cgm_value,
        m.map_field_of_patient_id,
        r.raw_data_payload
    FROM drh_cgm_file_metadata m
    JOIN drh_raw_cgm_tracing r ON (
        -- Standardize filenames (remove path/extension)
        LOWER(TRIM(CASE WHEN INSTR(r.raw_file_name, '.') > 0 THEN SUBSTR(r.raw_file_name, 1, INSTR(r.raw_file_name, '.') - 1) ELSE r.raw_file_name END)) 
        = 
        LOWER(TRIM(CASE WHEN INSTR(m.file_name, '.') > 0 THEN SUBSTR(m.file_name, 1, INSTR(m.file_name, '.') - 1) ELSE m.file_name END))
    )
)
SELECT 
    printf('%012x', (strftime('%s', 'now') * 1000) + (strftime('%f', 'now') % 1 * 1000)) 
    || lower(hex(randomblob(8))) AS file_meta_id,
    (SELECT db_file_id FROM constant_batch_ids) AS db_file_id, -- Single ID for this batch
    patient_id AS participant_display_id,
    json_object(
        'device_id', device_id,
        'file_name', file_name,
        'devicename', devicename,
        'file_format', file_format,
        'source_platform', source_platform,
        'file_upload_date', file_upload_date,
        'map_field_of_cgm_date', map_field_of_cgm_date,
        'map_field_of_cgm_value', map_field_of_cgm_value,
        'map_field_of_patient_id', map_field_of_patient_id
    ) AS file_meta_data,
    -- raw_data_payload is already a JSON array string in your raw view
    raw_data_payload AS cgm_data
FROM raw_combined;


---------------------------------------
-- participant_meal_fitness_data
---------------------------------------
CREATE TABLE IF NOT EXISTS participant_meal_fitness_data (
    db_file_id TEXT,
    tenant_id TEXT,
    study_display_id TEXT,
    fitness_meal_id TEXT PRIMARY KEY,
    participant_display_id TEXT,
    meal_data TEXT,             -- JSON Array of all meal records
    fitness_data TEXT,          -- JSON Array of all fitness records
    meal_file_metadata TEXT,    -- JSON Array of file info
    fitness_file_metadata TEXT  -- JSON Array of file info
);


INSERT INTO participant_meal_fitness_data
WITH 
-- 1. Unroll and Filter Meal Records
meal_filtered AS (
    SELECT 
        m.participant_id,
        m.meal_meta_id,
        m.file_name,
        m.source,
        p.value AS record_item
    FROM drh_meal_file_metadata m
    JOIN drh_raw_meal_data r ON (
        LOWER(TRIM(CASE WHEN INSTR(r.raw_file_name, '.') > 0 THEN SUBSTR(r.raw_file_name, 1, INSTR(r.raw_file_name, '.') - 1) ELSE r.raw_file_name END)) 
        = 
        LOWER(TRIM(CASE WHEN INSTR(m.file_name, '.') > 0 THEN SUBSTR(m.file_name, 1, INSTR(m.file_name, '.') - 1) ELSE m.file_name END))
    )
    CROSS JOIN json_each(r.raw_data_payload) AS p
    -- CRITICAL STEP: Ensure the record inside the JSON belongs to this participant
    WHERE json_extract(p.value, '$.participant_id') = m.participant_id
),
-- 2. Aggregate Filtered Meal Data
meal_agg AS (
    SELECT 
        participant_id,
        json_group_array(DISTINCT json_object(
            'meal_meta_id', meal_meta_id,
            'file_name', file_name,
            'source', source
        )) AS meal_meta,
        json_group_array(json(record_item)) AS meal_payloads
    FROM meal_filtered
    GROUP BY participant_id
),
-- 3. Unroll and Filter Fitness Records
fitness_filtered AS (
    SELECT 
        m.participant_id,
        m.fitness_meta_id,
        m.file_name,
        m.source,
        p.value AS record_item
    FROM drh_fitness_file_metadata m
    JOIN drh_raw_fitness_data r ON (
        LOWER(TRIM(CASE WHEN INSTR(r.raw_file_name, '.') > 0 THEN SUBSTR(r.raw_file_name, 1, INSTR(r.raw_file_name, '.') - 1) ELSE r.raw_file_name END)) 
        = 
        LOWER(TRIM(CASE WHEN INSTR(m.file_name, '.') > 0 THEN SUBSTR(m.file_name, 1, INSTR(m.file_name, '.') - 1) ELSE m.file_name END))
    )
    CROSS JOIN json_each(r.raw_data_payload) AS p
    -- CRITICAL STEP: Filter for participant match
    WHERE json_extract(p.value, '$.participant_id') = m.participant_id
),
-- 4. Aggregate Filtered Fitness Data
fitness_agg AS (
    SELECT 
        participant_id,
        json_group_array(DISTINCT json_object(
            'fitness_meta_id', fitness_meta_id,
            'file_name', file_name,
            'source', source
        )) AS fitness_meta,
        json_group_array(json(record_item)) AS fitness_payloads
    FROM fitness_filtered
    GROUP BY participant_id
),
all_participants AS (
    SELECT participant_id FROM meal_agg
    UNION
    SELECT participant_id FROM fitness_agg
)
SELECT 
    c.db_file_id,
    c.tenant_id,
    c.study_display_id,
    printf('%012x', (strftime('%s', 'now') * 1000)) || lower(hex(randomblob(8))) AS fitness_meal_id,
    p.participant_id,
    COALESCE(ma.meal_payloads, '[]') AS meal_data,
    COALESCE(fa.fitness_payloads, '[]') AS fitness_data,
    COALESCE(ma.meal_meta, '[]') AS meal_file_metadata,
    COALESCE(fa.fitness_meta, '[]') AS fitness_file_metadata
FROM all_participants p
CROSS JOIN constant_batch_ids c
LEFT JOIN meal_agg ma ON p.participant_id = ma.participant_id
LEFT JOIN fitness_agg fa ON p.participant_id = fa.participant_id;