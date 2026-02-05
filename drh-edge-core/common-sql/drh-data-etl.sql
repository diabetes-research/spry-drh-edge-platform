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



INSERT OR IGNORE INTO sqlpage_files (path, contents)
SELECT    
    'drh/cgm-data/raw-cgm/' || 
    LOWER(TRIM(
        CASE 
            WHEN instr(t.raw_file_name, '.') > 0 
            THEN substr(t.raw_file_name, 1, length(t.raw_file_name) - instr(printf('%s', rtrim(reverse(t.raw_file_name), replace(reverse(t.raw_file_name), '.', ''))), '.'))
            ELSE t.raw_file_name 
        END
    )) || '.sql' AS path, 
    '    
    SELECT ''shell'' AS component,
       ''Diabetes Research Hub Edge'' AS title,
       NULL AS icon,
       ''https://drh.diabetestechnology.org/_astro/favicon.CcrFY5y9.ico'' AS favicon,
       ''https://drh.diabetestechnology.org/images/diabetic-research-hub-logo.png'' AS image,
       ''fluid'' AS layout,
       true AS fixed_top_menu,
       ''/'' AS link,
       ''{"link":"/","title":"Home"}'' AS menu_item,
       ''https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/highlight.min.js'' AS javascript,
       ''https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/languages/sql.min.js'' AS javascript,
       ''https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/languages/handlebars.min.js'' AS javascript,
       ''https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/languages/json.min.js'' AS javascript,
       ''/static//d3-aide.js'' AS javascript,
       ''/js/chart-component.js'' AS javascript,  
       ''{"link":"https://drh.diabetestechnology.org/","title":"DRH Home","target": "__blank"}'' AS menu_item, 
       ''{"link":"https://www.diabetestechnology.org/index.shtml","title":"DTS Home","target": "__blank"}'' AS menu_item,         
       ''/static/stacked-bar-chart.js'' AS javascript_module,
       ''/static/gri-chart.js'' AS javascript_module,
       ''/static/dgp-chart.js'' AS javascript_module,
       ''/static/agp-chart.js'' AS javascript_module,
       ''/static/formula-component.js'' AS javascript_module;

    -- 1. Navigation
 
    SELECT ''breadcrumb'' AS component;
    SELECT ''Home'' AS title, ''/'' AS link;
    SELECT ''Raw CGM Data'' AS title, ''/drh/cgm-data.sql'' AS link;
    SELECT ''' || t.raw_file_name || ''' AS title;
    
    SELECT ''table'' AS component, TRUE AS sort, TRUE AS search;
    
    SELECT ' || 
    -- Map JSON keys to Column headers
    (SELECT GROUP_CONCAT('json_extract(p.value, ''$.' || key || ''') AS "' || key || '"', ', ')
     FROM json_each(json_extract(t.raw_data_payload, '$[0]'))) || 
    ' FROM drh_raw_cgm_tracing t, json_each(t.raw_data_payload) p
    WHERE t.raw_id = ''' || t.raw_id || ''';
    '
FROM
    drh_raw_cgm_tracing t;

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

-- =====================================================================
-- METRICS CALCULATION VIEWS AND TABLES
-- =====================================================================


DROP VIEW IF EXISTS participant_cgm_date_range_view;
CREATE VIEW
    participant_cgm_date_range_view AS
SELECT
    (
        select
            tenant_id
        from
            drh_study
        limit
            1
    ) as tenant_id,
    (
        select
            study_id
        from
            drh_study
        limit
            1
    ) as study_id,
    participant_id,
    CAST(strftime ('%Y-%m-%d', MIN(Date_Time)) AS TEXT) AS participant_cgm_start_date,
    CAST(strftime ('%Y-%m-%d', MAX(Date_Time)) AS TEXT) AS participant_cgm_end_date,
    CAST(
        strftime ('%Y-%m-%d', DATE (MAX(Date_Time), '-1 day')) AS TEXT
    ) AS end_date_minus_1_day,
    CAST(
        strftime ('%Y-%m-%d', DATE (MAX(Date_Time), '-7 day')) AS TEXT
    ) AS end_date_minus_7_days,
    CAST(
        strftime ('%Y-%m-%d', DATE (MAX(Date_Time), '-14 day')) AS TEXT
    ) AS end_date_minus_14_days,
    CAST(
        strftime ('%Y-%m-%d', DATE (MAX(Date_Time), '-30 day')) AS TEXT
    ) AS end_date_minus_30_days,
    CAST(
        strftime ('%Y-%m-%d', DATE (MAX(Date_Time), '-90 day')) AS TEXT
    ) AS end_date_minus_90_days
FROM
    combined_cgm_tracing_cached
GROUP BY
    participant_id;



-----Metric Specific Views----------------------------------------------------------        
DROP VIEW IF EXISTS drh_participant_cgm_dates;

CREATE VIEW drh_participant_cgm_dates As
SELECT 
    (
        select
            tenant_id
        from
            drh_study
        limit
            1
    ) as tenant_id,
    (
        select
            study_id
        from
            drh_study
        limit
            1
    ) as study_id,
    participant_id,
    MIN(Date_Time) AS cgm_start_date,
    MAX(Date_Time) AS cgm_end_date
FROM 
    combined_cgm_tracing_cached
GROUP BY 
    participant_id;
   


DROP VIEW IF EXISTS drh_participant_metrics;
-- Create the 
CREATE VIEW drh_participant_metrics AS
SELECT 
    (
        select
            tenant_id
        from
            drh_study
        limit
            1
    ) as tenant_id,
    (
        select
            study_id
        from
            drh_study
        limit
            1
    ) as study_id,
    participant_id,
    MIN(Date_Time) AS cgm_start_date,
    MAX(Date_Time) AS cgm_end_date,
    ROUND(AVG(CGM_Value), 2) AS mean_glucose,
    COUNT(DISTINCT DATE(Date_Time)) AS number_of_days_cgm_worn,
    ROUND(
        (COUNT(DISTINCT DATE(Date_Time)) / 
        ROUND((julianday(MAX(Date_Time)) - julianday(MIN(Date_Time)) + 1))
        ) * 100, 2) AS percentage_active,
    ROUND(AVG(CGM_Value) * 0.155 + 95, 2) AS gmi,
    ROUND((SQRT(AVG(CGM_Value * CGM_Value) - AVG(CGM_Value) * AVG(CGM_Value)) / AVG(CGM_Value)) * 100, 2) AS coefficient_of_variation
FROM 
    combined_cgm_tracing_cached
GROUP BY 
    participant_id;



DROP VIEW IF EXISTS drh_time_range_stacked_metrics;   
CREATE VIEW drh_time_range_stacked_metrics AS
   WITH GlucoseMetrics AS (
    SELECT 
        participant_id, 
        COUNT(*) AS total_readings, 
        SUM(CASE WHEN CGM_Value BETWEEN 54 AND 69 THEN 1 ELSE 0 END) AS time_below_range_low, 
        SUM(CASE WHEN CGM_Value < 54 THEN 1 ELSE 0 END) AS time_below_range_very_low, 
        SUM(CASE WHEN CGM_Value BETWEEN 70 AND 180 THEN 1 ELSE 0 END) AS time_in_range, 
        SUM(CASE WHEN CGM_Value > 250 THEN 1 ELSE 0 END) AS time_above_vh, 
        SUM(CASE WHEN CGM_Value BETWEEN 181 AND 250 THEN 1 ELSE 0 END) AS time_above_range_high 
    FROM 
        combined_cgm_tracing_cached
    GROUP BY 
        participant_id 
), Defaults AS (
    SELECT 
        0 AS total_readings, 
        0 AS time_below_range_low, 
        0 AS time_below_range_very_low, 
        0 AS time_in_range, 
        0 AS time_above_vh, 
        0 AS time_above_range_high 
)

SELECT 
    gm.participant_id,
    COALESCE(CASE WHEN gm.total_readings = 0 THEN 0 ELSE (gm.time_below_range_low * 100.0 / gm.total_readings) END, 0) AS time_below_range_low_percentage, 
    COALESCE(gm.time_below_range_low, 0) AS time_below_range_low, 
    COALESCE(CASE WHEN gm.total_readings = 0 THEN '00 hours, 00 minutes' ELSE printf('%02d hours, %02d minutes', (gm.time_below_range_low * 5) / 60, (gm.time_below_range_low * 5) % 60) END, '00 hours, 00 minutes') AS time_below_range_low_string, 
    COALESCE(CASE WHEN gm.total_readings = 0 THEN 0 ELSE (gm.time_below_range_very_low * 100.0 / gm.total_readings) END, 0) AS time_below_range_very_low_percentage, 
    COALESCE(gm.time_below_range_very_low, 0) AS time_below_range_very_low, 
    COALESCE(CASE WHEN gm.total_readings = 0 THEN '00 hours, 00 minutes' ELSE printf('%02d hours, %02d minutes', (gm.time_below_range_very_low * 5) / 60, (gm.time_below_range_very_low * 5) % 60) END, '00 hours, 00 minutes') AS time_below_range_very_low_string, 
    COALESCE(CASE WHEN gm.total_readings = 0 THEN 0 ELSE (gm.time_in_range * 100.0 / gm.total_readings) END, 0) AS time_in_range_percentage, 
    COALESCE(gm.time_in_range, 0) AS time_in_range, 
    COALESCE(CASE WHEN gm.total_readings = 0 THEN '00 hours, 00 minutes' ELSE printf('%02d hours, %02d minutes', (gm.time_in_range * 5) / 60, (gm.time_in_range * 5) % 60) END, '00 hours, 00 minutes') AS time_in_range_string, 
    COALESCE(CASE WHEN gm.total_readings = 0 THEN 0 ELSE (gm.time_above_vh * 100.0 / gm.total_readings) END, 0) AS time_above_vh_percentage, 
    COALESCE(gm.time_above_vh, 0) AS time_above_vh, 
    COALESCE(CASE WHEN gm.total_readings = 0 THEN '00 hours, 00 minutes' ELSE printf('%02d hours, %02d minutes', (gm.time_above_vh * 5) / 60, (gm.time_above_vh * 5) % 60) END, '00 hours, 00 minutes') AS time_above_vh_string, 
    COALESCE(CASE WHEN gm.total_readings = 0 THEN 0 ELSE (gm.time_above_range_high * 100.0 / gm.total_readings) END, 0) AS time_above_range_high_percentage, 
    COALESCE(gm.time_above_range_high, 0) AS time_above_range_high, 
    COALESCE(CASE WHEN gm.total_readings = 0 THEN '00 hours, 00 minutes' ELSE printf('%02d hours, %02d minutes', (gm.time_above_range_high * 5) / 60, (gm.time_above_range_high * 5) % 60) END, '00 hours, 00 minutes') AS time_above_range_high_string 
FROM 
    Defaults d 
    LEFT JOIN GlucoseMetrics gm ON 1=1;


DROP VIEW IF EXISTS drh_agp_metrics;
   
CREATE VIEW drh_agp_metrics AS
WITH glucose_data AS (
    SELECT
        gr.participant_id,
        gr.Date_Time AS timestamp,
        strftime('%Y-%m-%d %H', gr.Date_Time) AS hourValue,
        gr.CGM_Value AS glucose_level
    FROM
        combined_cgm_tracing_cached gr
),
ranked_data AS (
    SELECT
        participant_id,
        hourValue,
        glucose_level,
        ROW_NUMBER() OVER (PARTITION BY participant_id, hourValue ORDER BY glucose_level) AS row_num,
        COUNT(*) OVER (PARTITION BY participant_id, hourValue) AS total_count
    FROM
        glucose_data
),
percentiles AS (
    SELECT
        participant_id,
        hourValue AS hour,
        MAX(CASE WHEN row_num = CAST(0.05 * total_count AS INT) THEN glucose_level END) AS p5,
        MAX(CASE WHEN row_num = CAST(0.25 * total_count AS INT) THEN glucose_level END) AS p25,
        MAX(CASE WHEN row_num = CAST(0.50 * total_count AS INT) THEN glucose_level END) AS p50,
        MAX(CASE WHEN row_num = CAST(0.75 * total_count AS INT) THEN glucose_level END) AS p75,
        MAX(CASE WHEN row_num = CAST(0.95 * total_count AS INT) THEN glucose_level END) AS p95
    FROM
        ranked_data
    GROUP BY
        participant_id, hour
),
hourly_averages AS (
    SELECT
        participant_id,
        SUBSTR(hour, 1, 10) AS date,
        SUBSTR(hour, 12) AS hour,
        COALESCE(AVG(p5), 0) AS p5,
        COALESCE(AVG(p25), 0) AS p25,
        COALESCE(AVG(p50), 0) AS p50,
        COALESCE(AVG(p75), 0) AS p75,
        COALESCE(AVG(p95), 0) AS p95
    FROM
        percentiles
    GROUP BY
        participant_id, hour
)
SELECT
    participant_id,
    hour,
    COALESCE(AVG(p5), 0) AS p5,
    COALESCE(AVG(p25), 0) AS p25,
    COALESCE(AVG(p50), 0) AS p50,
    COALESCE(AVG(p75), 0) AS p75,
    COALESCE(AVG(p95), 0) AS p95
FROM
    hourly_averages
GROUP BY
    participant_id, hour
ORDER BY
    participant_id, hour;



DROP VIEW IF EXISTS drh_glycemic_risk_indicator;
CREATE VIEW drh_glycemic_risk_indicator AS 
  SELECT 
    participant_id, 
    ROUND(COALESCE((SUM(CASE WHEN cgm_value > 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)), 0), 2) AS time_above_VH_percentage,
    ROUND(COALESCE((SUM(CASE WHEN cgm_value BETWEEN 181 AND 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)), 0), 2) AS time_above_H_percentage,
    ROUND(COALESCE((SUM(CASE WHEN cgm_value BETWEEN 70 AND 180 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)), 0), 2) AS time_in_range_percentage,
    ROUND(COALESCE((SUM(CASE WHEN cgm_value BETWEEN 54 AND 69 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)), 0), 2) AS time_below_low_percentage,
    ROUND(COALESCE((SUM(CASE WHEN cgm_value < 54 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)), 0), 2) AS time_below_VL_percentage,
    ROUND(COALESCE((SUM(CASE WHEN cgm_value < 54 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)) + 
                   (0.8 * (SUM(CASE WHEN cgm_value BETWEEN 54 AND 69 THEN 1 ELSE 0 END) * 100.0 / COUNT(*))), 0), 2) AS Hypoglycemia_Component,
    ROUND(COALESCE((SUM(CASE WHEN cgm_value > 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)) + 
                   (0.5 * (SUM(CASE WHEN cgm_value BETWEEN 181 AND 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*))), 0), 2) AS Hyperglycemia_Component,
    ROUND(COALESCE((3.0 * ((SUM(CASE WHEN cgm_value < 54 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)) + 
                            (0.8 * (SUM(CASE WHEN cgm_value BETWEEN 54 AND 69 THEN 1 ELSE 0 END) * 100.0 / COUNT(*))))) + 
                   (1.6 * ((SUM(CASE WHEN cgm_value > 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)) + 
                            (0.5 * (SUM(CASE WHEN cgm_value BETWEEN 181 AND 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*))))), 0), 2) AS GRI
FROM combined_cgm_tracing_cached
GROUP BY participant_id;


DROP VIEW IF EXISTS drh_advanced_metrics;
CREATE  VIEW drh_advanced_metrics AS
WITH risk_scores AS (
    SELECT 
        participant_id,
        CGM_Value,
        CASE
            WHEN CGM_Value < 90 THEN 10 * (5 - (CGM_Value / 18.0)) * (5 - (CGM_Value / 18.0))
            WHEN CGM_Value > 180 THEN 10 * ((CGM_Value / 18.0) - 10) * ((CGM_Value / 18.0) - 10)
            ELSE 0
        END AS risk_score
    FROM combined_cgm_tracing_cached
),
average_risk AS (
    SELECT 
        participant_id,
        AVG(risk_score) AS avg_risk_score
    FROM risk_scores
    GROUP BY participant_id
),
amplitude_data AS (
    SELECT 
        participant_id,
        ABS(MAX(CGM_Value) - MIN(CGM_Value)) AS amplitude
    FROM combined_cgm_tracing_cached
    GROUP BY participant_id, DATE(Date_Time)
),
mean_amplitude AS (
    SELECT 
        participant_id,
        AVG(amplitude) AS mean_amplitude
    FROM amplitude_data
    GROUP BY participant_id
),
participant_min_max AS (
    SELECT 
        participant_id,
        MIN(CGM_Value) AS min_glucose,
        MAX(CGM_Value) AS max_glucose,
        MIN(DATETIME(Date_Time)) AS start_time,
        MAX(DATETIME(Date_Time)) AS end_time
    FROM combined_cgm_tracing_cached
    GROUP BY participant_id
),
m_value AS (
    SELECT 
        participant_id,
        (max_glucose - min_glucose) / ((strftime('%s', end_time) - strftime('%s', start_time)) / 60.0) AS m_value
    FROM participant_min_max
),
daily_risk AS (
    SELECT 
        participant_id,
        DATE(Date_Time) AS day,
        MAX(CGM_Value) - MIN(CGM_Value) AS daily_range
    FROM combined_cgm_tracing_cached
    GROUP BY participant_id, DATE(Date_Time)
),
average_daily_risk AS (
    SELECT 
        participant_id,
        AVG(daily_range) AS average_daily_risk
    FROM daily_risk
    GROUP BY participant_id
),
glucose_stats AS (
    SELECT
        participant_id,
        AVG(CGM_Value) AS mean_glucose,
        (AVG(CGM_Value * CGM_Value) - AVG(CGM_Value) * AVG(CGM_Value)) AS variance_glucose
    FROM combined_cgm_tracing_cached
    GROUP BY participant_id
),
lbgi_hbgi AS (
    SELECT 
        participant_id,
        ROUND(SUM(CASE WHEN (CGM_Value - 2.5) / 2.5 > 0 THEN ((CGM_Value - 2.5) / 2.5) * ((CGM_Value - 2.5) / 2.5) ELSE 0 END) * 5, 2) AS lbgi, 
        ROUND(SUM(CASE WHEN (CGM_Value - 9.5) / 9.5 > 0 THEN ((CGM_Value - 9.5) / 9.5) * ((CGM_Value - 9.5) / 9.5) ELSE 0 END) * 5, 2) AS hbgi
    FROM combined_cgm_tracing_cached
    GROUP BY participant_id
),
daily_diffs AS (
    SELECT
        participant_id,
        DATE(Date_Time) AS date,
        CGM_Value,
        CGM_Value - LAG(CGM_Value) OVER (PARTITION BY participant_id ORDER BY DATE(Date_Time)) AS daily_diff
    FROM combined_cgm_tracing_cached
),
mean_daily_diff AS (
    SELECT
        participant_id,
        AVG(daily_diff) AS mean_daily_diff
    FROM daily_diffs
    WHERE daily_diff IS NOT NULL
    GROUP BY participant_id
),
lag_values AS (
    SELECT 
        participant_id,
        Date_Time,
        CGM_Value,
        LAG(CGM_Value) OVER (PARTITION BY participant_id ORDER BY Date_Time) AS lag_CGM_Value
    FROM combined_cgm_tracing_cached
),
conga_hourly AS (
    SELECT 
        participant_id,
        SQRT(
            AVG(
                (CGM_Value - lag_CGM_Value) * (CGM_Value - lag_CGM_Value)
            ) OVER (PARTITION BY participant_id ORDER BY Date_Time)
        ) AS conga_hourly
    FROM lag_values
    WHERE lag_CGM_Value IS NOT NULL
    GROUP BY participant_id
),
liability_index AS (
    SELECT
        participant_id,
        SUM(CASE WHEN CGM_Value < 70 THEN 1 ELSE 0 END) AS hypoglycemic_episodes, 
        SUM(CASE WHEN CGM_Value BETWEEN 70 AND 180 THEN 1 ELSE 0 END) AS euglycemic_episodes, 
        SUM(CASE WHEN CGM_Value > 180 THEN 1 ELSE 0 END) AS hyperglycemic_episodes, 
        ROUND(CAST(
            (SUM(CASE WHEN CGM_Value < 70 THEN 1 ELSE 0 END) + SUM(CASE WHEN CGM_Value > 180 THEN 1 ELSE 0 END))
            AS REAL
        ) / COUNT(*), 2) AS liability_index
    FROM combined_cgm_tracing_cached
    GROUP BY participant_id
),
j_index AS (
    SELECT
        participant_id,
        ROUND(0.001 * (mean_glucose + sqrt(variance_glucose)) * (mean_glucose + sqrt(variance_glucose)), 2) AS j_index
    FROM glucose_stats
),
time_in_tight_range AS ( 
    SELECT        
        participant_id,
        (SUM(CASE WHEN CGM_Value BETWEEN 70 AND 140 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)) AS time_in_tight_range_percentage,
        SUM(CASE WHEN CGM_Value BETWEEN 70 AND 140 THEN 1 ELSE 0 END) AS time_in_tight_range        
    FROM combined_cgm_tracing_cached
    GROUP BY participant_id
)
SELECT
    participant_id,
    COALESCE((SELECT time_in_tight_range_percentage FROM time_in_tight_range WHERE participant_id = p.participant_id), 0) AS time_in_tight_range_percentage,
    COALESCE((SELECT avg_risk_score FROM average_risk WHERE participant_id = p.participant_id), 0) AS grade,
    COALESCE((SELECT mean_amplitude FROM mean_amplitude WHERE participant_id = p.participant_id), 0) AS mean_amplitude,
    COALESCE((SELECT m_value FROM m_value WHERE participant_id = p.participant_id), 0) AS m_value,
    COALESCE((SELECT average_daily_risk FROM average_daily_risk WHERE participant_id = p.participant_id), 0) AS average_daily_risk,
    COALESCE((SELECT mean_glucose FROM glucose_stats WHERE participant_id = p.participant_id), 0) AS mean_glucose,
    COALESCE((SELECT lbgi FROM lbgi_hbgi WHERE participant_id = p.participant_id), 0) AS lbgi,
    COALESCE((SELECT hbgi FROM lbgi_hbgi WHERE participant_id = p.participant_id), 0) AS hbgi,
    COALESCE((SELECT mean_daily_diff FROM mean_daily_diff WHERE participant_id = p.participant_id), 0) AS mean_daily_diff,
    COALESCE((SELECT conga_hourly FROM conga_hourly WHERE participant_id = p.participant_id), 0) AS conga_hourly,
    COALESCE((SELECT hypoglycemic_episodes FROM liability_index WHERE participant_id = p.participant_id), 0) AS hypoglycemic_episodes,
    COALESCE((SELECT euglycemic_episodes FROM liability_index WHERE participant_id = p.participant_id), 0) AS euglycemic_episodes,
    COALESCE((SELECT hyperglycemic_episodes FROM liability_index WHERE participant_id = p.participant_id), 0) AS hyperglycemic_episodes,
    COALESCE((SELECT liability_index FROM liability_index WHERE participant_id = p.participant_id), 0) AS liability_index,
    COALESCE((SELECT j_index FROM j_index WHERE participant_id = p.participant_id), 0) AS j_index
FROM (
    SELECT DISTINCT participant_id 
    FROM combined_cgm_tracing_cached
) AS p;


-- Optimized View: CGM Dashboard Metrics
DROP VIEW IF EXISTS study_combined_dashboard_participant_metrics_view;
CREATE VIEW study_combined_dashboard_participant_metrics_view AS
WITH cgm_stats AS (
    -- Pre-calculate all CGM metrics once per participant
    SELECT 
        participant_id,
        COUNT(CGM_Value) as total_count,
        SUM(CASE WHEN CGM_Value BETWEEN 70 AND 180 THEN 1 ELSE 0 END) as count_tir,
        SUM(CASE WHEN CGM_Value > 250 THEN 1 ELSE 0 END) as count_tar_vh,
        SUM(CASE WHEN CGM_Value BETWEEN 181 AND 250 THEN 1 ELSE 0 END) as count_tar_h,
        SUM(CASE WHEN CGM_Value BETWEEN 54 AND 69 THEN 1 ELSE 0 END) as count_tbr_l,
        SUM(CASE WHEN CGM_Value < 54 THEN 1 ELSE 0 END) as count_tbr_vl,
        -- Added for TAR/TBR totals
        SUM(CASE WHEN CGM_Value > 180 THEN 1 ELSE 0 END) as count_tar,
        SUM(CASE WHEN CGM_Value < 70 THEN 1 ELSE 0 END) as count_tbr,
        AVG(CGM_Value) as avg_glucose,
        AVG(CGM_Value * CGM_Value) as avg_sq_glucose,
        COUNT(DISTINCT DATE(Date_Time)) AS days_of_wear,
        MIN(DATE(Date_Time)) AS d_start,
        MAX(DATE(Date_Time)) AS d_end
    FROM combined_cgm_tracing_cached
    GROUP BY participant_id
),
meta_stats AS (
    -- Aggregate file info separately to avoid multiplying CGM rows
    SELECT 
        patient_id,
        GROUP_CONCAT(DISTINCT devicename) AS cgm_devices,
        GROUP_CONCAT(DISTINCT file_name || '.' || file_format) AS cgm_files
    FROM drh_cgm_file_metadata
    GROUP BY patient_id
)
SELECT 
    dg.tenant_id,
    dg.study_id,             
    dg.participant_id,
    dg.gender,
    dg.age,
    dg.study_arm,
    dg.baseline_hba1c,
    ms.cgm_devices,
    ms.cgm_files,
    -- Core Metrics
    ROUND(cs.count_tir * 100.0 / cs.total_count, 2) AS tir,
    ROUND(cs.count_tar_vh * 100.0 / cs.total_count, 2) AS tar_vh,
    ROUND(cs.count_tar_h * 100.0 / cs.total_count, 2) AS tar_h,
    ROUND(cs.count_tbr_l * 100.0 / cs.total_count, 2) AS tbr_l,
    ROUND(cs.count_tbr_vl * 100.0 / cs.total_count, 2) AS tbr_vl,
    -- Missing TAR/TBR added
    ROUND(cs.count_tar * 100.0 / cs.total_count, 2) AS tar,
    ROUND(cs.count_tbr * 100.0 / cs.total_count, 2) AS tbr,
    -- Clinical Indicators
    CEIL((cs.avg_glucose * 0.155) + 95) AS gmi,
    ROUND((SQRT(cs.avg_sq_glucose - (cs.avg_glucose * cs.avg_glucose)) / cs.avg_glucose) * 100, 2) AS percent_gv,
    -- Added GRI (Glycemia Risk Index) calculation
    ROUND((3.0 * ((cs.count_tbr_vl * 100.0 / cs.total_count) + 
                  (0.8 * (cs.count_tbr_l * 100.0 / cs.total_count)))) + 
          (1.6 * ((cs.count_tar_vh * 100.0 / cs.total_count) + 
                  (0.5 * (cs.count_tar_h * 100.0 / cs.total_count)))), 2) AS gri,
    -- Metadata
    cs.days_of_wear,
    cs.d_start AS data_start_date,
    cs.d_end AS data_end_date,
    ROUND(COALESCE((cs.days_of_wear * 1.0 / (JULIANDAY(cs.d_end) - JULIANDAY(cs.d_start) + 1)) * 100, 0), 2) AS wear_time_percentage
FROM drh_participant dg
JOIN cgm_stats cs ON dg.participant_id = cs.participant_id
LEFT JOIN meta_stats ms ON dg.participant_id = ms.patient_id
ORDER BY      
    CASE 
        WHEN LENGTH(dg.participant_id) - LENGTH(REPLACE(dg.participant_id, '-', '')) = 1 THEN 
            CAST(SUBSTR(dg.participant_id, INSTR(dg.participant_id, '-') + 1) AS INTEGER) 
        ELSE dg.participant_id 
    END ASC;


------cached tables-------------------------



-- Drop the cached table if it already exists
DROP TABLE IF EXISTS participant_dashboard_cached;
-- Create and populate the table with data from the view
CREATE TABLE participant_dashboard_cached AS
SELECT * FROM study_combined_dashboard_participant_metrics_view;



-- DROP TABLE IF EXISTS cgm_table_name_cached;

-- CREATE TABLE cgm_table_name_cached AS 
-- SELECT DISTINCT 
--     pdc.tenant_id,
--     pdc.study_id, 
--     sm.tbl_name AS table_name, 
--     REPLACE(sm.tbl_name, 'drh_', '') || '.' || ur.nature AS file_name
-- FROM 
--     participant_dashboard_cached pdc
-- JOIN 
--     sqlite_master sm
--     ON sm.type = 'table'
--     AND sm.name LIKE 'uniform_resource%'
--     AND sm.name != 'drh_transform'
--     AND sm.name != 'uniform_resource'
-- JOIN 
--     uniform_resource ur 
--     ON ur.uri LIKE '%' || REPLACE(sm.tbl_name, 'drh_', '') || '%';



DROP TABLE IF EXISTS participant_cgm_date_range_cached;

CREATE TABLE
    participant_cgm_date_range_cached AS
SELECT
    *
FROM
    participant_cgm_date_range_view;



-------------------study-meta-data---------------------

CREATE TABLE study_meta_data AS
SELECT
    CAST((SELECT db_file_id FROM file_meta_ingest_data LIMIT 1) AS TEXT) AS db_file_id,  
    CAST(lower(hex(randomblob(16))) AS TEXT) AS study_meta_id,
    CAST((SELECT party_id FROM party LIMIT 1) AS TEXT) AS tenant_id, 
    CAST(s.study_id AS TEXT) AS study_display_id,
    CAST(s.study_name AS TEXT) AS study_name,
    CAST(s.start_date AS TEXT) AS start_date,
    CAST(s.end_date AS TEXT) AS end_date,
    CAST(s.treatment_modalities AS TEXT) AS treatment_modalities,
    CAST(s.funding_source AS TEXT) AS funding_source,
    CAST(s.nct_number AS TEXT) AS nct_number,
    CAST(s.study_description AS TEXT) AS study_description,  
    -- Investigators as JSON Array (Text)
    CAST((SELECT JSON_GROUP_ARRAY(
        JSON_OBJECT(
            'investigator_name', i.investigator_name,
            'email', i.email,
            'institution_id', i.institution_id
        )
     ) FROM drh_investigator i) AS TEXT) AS investigators,

    -- Publications as JSON Array (Text)
    CAST((SELECT JSON_GROUP_ARRAY(
        JSON_OBJECT(
            'title', p.publication_title,
            'doi', p.digital_object_identifier,
            'publication_site', p.publication_site
        )
     ) FROM drh_publication p) AS TEXT) AS publications,

    -- Authors as JSON Array (Text)
    CAST((SELECT JSON_GROUP_ARRAY(
        JSON_OBJECT(
            'name', a.name,
            'email', a.email,
            'investigator_id', a.investigator_id
        )
     ) FROM drh_author a) AS TEXT) AS authors,

    -- Institutions as JSON Array (Text)
    CAST((SELECT JSON_GROUP_ARRAY(
        JSON_OBJECT(
            'name', iv.institution_name,
            'city', iv.city,
            'state', iv.state,
            'country', iv.country
        )
     ) FROM drh_institution iv) AS TEXT) AS institutions,

    -- Labs as JSON Array (Text)
    CAST((SELECT JSON_GROUP_ARRAY(
        JSON_OBJECT(
            'lab_name', l.lab_name,
            'lab_pi', l.lab_pi,
            'institution_id', l.institution_id
        )
     ) FROM drh_lab l) AS TEXT) AS labs,

    -- Sites as JSON Array (Text)
    CAST((SELECT JSON_GROUP_ARRAY(
        JSON_OBJECT(
            'site_name', si.site_name,
            'site_type', si.site_type
        )
     ) FROM drh_site si) AS TEXT) AS sites,
     
    -- Mark studies as synthetic or real in JSON format
    CAST(JSON_OBJECT('type', 'synthetic' ) AS TEXT) AS elaboration

FROM drh_study s;

------------------------Metric definitions------------------------

DROP TABLE IF EXISTS metric_definitions;
CREATE TABLE IF NOT EXISTS metric_definitions (
    metric_id TEXT PRIMARY KEY,
    metric_name TEXT NOT NULL UNIQUE,
    metric_info TEXT NOT NULL -- Stores JSON with "description" and "formula" details
);

-- Metric: Time CGM Active
INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info)
VALUES (
    'time_cgm_active', 
    'Time CGM Active', 
    '{"description": "This metric calculates the percentage of time during a specific period (e.g., a day, week, or month) that the CGM device is actively collecting data. It takes into account the total duration of the monitoring period and compares it to the duration during which the device was operational and recording glucose readings.", 
      "formula": "Percentage of time CGM is active = (Duration CGM is active / Total duration of monitoring period) × 100"}'
);

-- Metric: Number of Days CGM Worn
INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info)
VALUES (
    'number_of_days_cgm_worn', 
    'Number of Days CGM Worn', 
    '{"description": "This metric represents the total number of days the CGM device was worn by the user over a monitoring period. It helps in assessing the adherence to wearing the device as prescribed.", 
      "formula": "Number of days CGM worn = Count of days with CGM data recorded in the monitoring period"}'
);

-- Metric: Mean Glucose
INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info)
VALUES (
    'mean_glucose', 
    'Mean Glucose', 
    '{"description": "Mean glucose reflects the average glucose level over the monitoring period, serving as an indicator of overall glucose control. It is a simple yet powerful measure in glucose management.", 
      "formula": "Mean glucose = Sum of all glucose readings / Number of readings"}'
);

-- Metric: Glucose Management Indicator (GMI)
INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info)
VALUES (
    'gmi', 
    'Glucose Management Indicator (GMI)', 
    '{"description": "GMI provides an estimated A1C level based on mean glucose, which can be used as an indicator of long-term glucose control. GMI helps in setting and assessing long-term glucose goals.", 
      "formula": "GMI = (3.31 + 0.02392 × Mean glucose) × 100"}'
);

-- Metric: Glucose Variability
INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info)
VALUES (
    'glucose_variability', 
    'Glucose Variability', 
    '{"description": "Glucose variability measures fluctuations in glucose levels over time, calculated as the coefficient of variation (%CV). A lower %CV indicates more stable glucose control.", 
      "formula": "Glucose variability = (Standard deviation of glucose / Mean glucose) × 100"}'
);

-- Insert a single record for AGP metrics and axes
INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info)
VALUES (
    'AGP_metrics',
    'Ambulatory Glucose Profile (AGP)',
    '{"description": "The Ambulatory Glucose Profile (AGP) summarizes glucose monitoring data over a specified period, typically 14 to 90 days. It provides a visual representation of glucose levels, helping to identify patterns and variability in glucose management.",
        "metrics": {
            "time_in_target_range": {
                "description": "This metric indicates the percentage of time glucose levels are within the target range (typically 70-180 mg/dL). It is essential for evaluating the effectiveness of diabetes management.",
                "formula": "Percentage in Target Range = (Time in Target Range / Total Time) × 100"
            },
            "below_70": {
                "description": "Tracks the percentage of time glucose levels are below 70 mg/dL, indicating hypoglycemic episodes. Understanding these periods helps prevent severe lows.",
                "formula": "Percentage below 70 mg/dL = (Time below 70 mg/dL / Total Time) × 100"
            },
            "above_180": {
                "description": "Indicates the percentage of time glucose levels exceed 180 mg/dL, highlighting periods of hyperglycemia. Managing these episodes is critical for overall health.",
                "formula": "Percentage above 180 mg/dL = (Time above 180 mg/dL / Total Time) × 100"
            },
            "quartiles": {
                "description": "Quartiles divide glucose readings into four equal parts, helping to understand glucose level distribution. Q1 is the 25th percentile, Q2 is the median, and Q3 is the 75th percentile.",
                "formula": "Quartiles are calculated from sorted glucose readings: Q1 = 25th percentile, Q2 = 50th percentile (median), Q3 = 75th percentile."
            }
        },
        "axes": {
            "x_axis": {
                "description": "Time of Day - The X-axis represents the time of day, segmented into hourly intervals. It typically includes the following time points: 12 AM, 3 AM, 6 AM, 9 AM, 12 PM, 3 PM, 6 PM, 9 PM, and 11 PM."
            },
            "y_axis": {
                "description": "Glucose Levels -The Y-axis represents glucose levels measured in milligrams per deciliter (mg/dL). It typically displays a range from 0 mg/dL to 350 mg/dL, indicating when glucose levels are within, below, or above the target range."
            }
        }
    }'
);

-- Seed SQL for metrics definitions with JSON formatted metric_info

INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
('liability_index', 'Liability Index', '{"description": "The Liability Index quantifies the risk associated with glucose variability, measured in mg/dL.", "formula": "Liability Index = (Total Duration of monitoring period) * (Average of CGM_i)"}');

INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
('hypoglycemic_episodes', 'Hypoglycemic Episodes', '{"description": "This metric counts the number of occurrences when glucose levels drop below a specified hypoglycemic threshold, indicating potentially dangerous low blood sugar events.", "formula": "Hypoglycemic Episodes = COUNT(CASE WHEN CGM_i < Threshold THEN 1 END)"}');

INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
('euglycemic_episodes', 'Euglycemic Episodes', '{"description": "This metric counts the number of instances where glucose levels remain within the target range, indicating stable and healthy glucose control.", "formula": "Euglycemic Episodes = COUNT(CASE WHEN CGM_i BETWEEN LowThreshold AND HighThreshold THEN 1 END)"}');

INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
('hyperglycemic_episodes', 'Hyperglycemic Episodes', '{"description": "This metric counts the number of instances where glucose levels exceed a certain hyperglycemic threshold, indicating potentially harmful high blood sugar events.", "formula": "Hyperglycemic Episodes = COUNT(CASE WHEN CGM_i > Threshold THEN 1 END)"}');

INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
('m_value', 'M Value', '{"description": "The M Value provides a measure of glucose variability, calculated from the mean of the absolute differences between consecutive CGM values over a specified period.", "formula": "M Value = Mean(ABS(CGM_i - CGM_(i-1)))"}');

INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
('mean_amplitude', 'Mean Amplitude', '{"description": "Mean Amplitude quantifies the average degree of fluctuation in glucose levels over a given time frame, giving insight into glucose stability.", "formula": "Mean Amplitude = Mean(ABS(CGM_i - Mean(CGM)))"}');

INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
('average_daily_risk_range', 'Average Daily Risk Range', '{"description": "This metric assesses the average risk associated with daily glucose variations, expressed in mg/dL.", "formula": "Average Daily Risk Range = (Max(CGM) - Min(CGM)) / Number of Days"}');

INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
('j_index', 'J Index', '{"description": "The J Index calculates glycemic variability using both high and low glucose readings, offering a comprehensive view of glucose fluctuations.", "formula": "J Index = (3.0 * Hypoglycemia Component) + (1.6 * Hyperglycemia Component)"}');

INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
('low_blood_glucose_index', 'Low Blood Glucose Index', '{"description": "This metric quantifies the risk associated with low blood glucose levels over a specified period, measured in mg/dL.", "formula": "Low Blood Glucose Index = SUM(CASE WHEN CGM_i < LowThreshold THEN 1 ELSE 0 END)"}');

INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
('high_blood_glucose_index', 'High Blood Glucose Index', '{"description": "This metric quantifies the risk associated with high blood glucose levels over a specified period, measured in mg/dL.", "formula": "High Blood Glucose Index = SUM(CASE WHEN CGM_i > HighThreshold THEN 1 ELSE 0 END)"}');

INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
('glycemic_risk_assessment', 'Glycemic Risk Assessment Diabetes Equation (GRADE)', '{"description": "GRADE is a metric that combines various glucose metrics to assess overall glycemic risk in individuals with diabetes, calculated using multiple input parameters.", "formula": "GRADE = (Weights based on Low, Normal, High CGM values)"}');

INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
('continuous_overall_net_glycemic_action', 'Continuous Overall Net Glycemic Action (CONGA)', '{"description": "CONGA quantifies the net glycemic effect over time by evaluating the differences between CGM values at specified intervals.", "formula": "CONGA = Mean(ABS(CGM_i - CGM_(i-k))) for k=1 to n"}');

INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
('mean_of_daily_differences', 'Mean of Daily Differences', '{"description": "This metric calculates the average of the absolute differences between daily CGM readings, giving insight into daily glucose variability.", "formula": "Mean of Daily Differences = Mean(ABS(CGM_i - CGM_(i-1)))"}');


INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
(
    'daily_glucose_profile', 
    'Daily Glucose Profile', 
    '{
        "description": "The Daily Glucose Profile Chart visualizes a participant''s glucose levels over a specified timeframe, typically the last 14 days. Each point on the graph represents a glucose reading taken at a specific hour, indicating the participant''s response to food intake, exercise, medication, and other lifestyle factors. Monitoring these thresholds helps in identifying periods of risk: hypoglycemia, for glucose levels below 70 mg/dL, and hyperglycemia, for levels above 180 mg/dL. This analysis can guide interventions and adjustments in treatment. A consistently high or low profile may lead to further investigation and modifications in treatment plans.",
        "axes": {
            "y_axis": "The y-axis represents glucose levels in mg/dL, with a lower threshold of 70 mg/dL indicating hypoglycemia risk and an upper threshold of 180 mg/dL indicating hyperglycemia risk.",
            "x_axis": "The x-axis spans a week from Friday to Thursday, displaying data between 12 PM and 10 PM each day, focusing on peak active hours for glucose level variations."
        }
    }'
);


INSERT OR IGNORE INTO metric_definitions (metric_id, metric_name, metric_info) VALUES
(
    'goals_for_type_1_and_type_2_diabetes_chart_metrics', 
    'Goals for Type 1 and Type 2 Diabetes chart Metrics', 
    '{
        "description": "Goals for Type 1 and Type 2 Diabetes Chart provides a comprehensive view of a participant''s glucose readings categorized into different ranges over a specified period.",
        "metrics": {
            "very_low": {
                "description": "Represents the count and percentage of readings below 54 mg/dL, which may indicate critical hypoglycemia."
            },
            "low": {
                "description": "Represents the count and percentage of readings between 54 mg/dL and 69 mg/dL, indicating a potential risk of hypoglycemia."
            },
            "in_range": {
                "description": "The percentage and count of readings between 70 mg/dL and 180 mg/dL, considered the target glucose range for optimal health.",
                "target": "over 70%"
            },
            "high": {
                "description": "Includes readings between 181 mg/dL and 250 mg/dL, indicating borderline hyperglycemia."
            },
            "very_high": {
                "description": "Represents readings above 250 mg/dL, indicating potentially dangerous hyperglycemia."
            }
        },
        "formula": "The calculation for each category is performed by counting the total readings in each defined glucose range. The chart shows both the total time spent in each range and the percentage of total readings over a defined monitoring period. Example: If a participant has 100 readings and 10 are below 54 mg/dL, the percentage is calculated as (10 / 100) * 100, resulting in 10%. Usage: The chart aids healthcare providers and participants in understanding glucose variability and making informed decisions.",
        "axes": "x-axis: Time intervals and y-axis: Percentages of time in each range"
    }'
);


DROP VIEW IF EXISTS metric_info_view;
CREATE VIEW metric_info_view AS
SELECT 
    metric_id,
    metric_name,
    json_extract(metric_info, '$.description') AS "Metrics Description",
    json_extract(metric_info, '$.formula') AS formula,    
    json_extract(metric_info, '$.metrics') AS "Metrics Details",    
    json_extract(metric_info, '$.axes') AS "Axes Details"    
FROM 
    metric_definitions;



DROP TABLE IF EXISTS participant; 
CREATE TABLE participant AS
SELECT
    CAST((SELECT db_file_id FROM file_meta_ingest_data LIMIT 1) AS TEXT) AS db_file_id, 
    p.participant_id as participant_display_id,
    p.study_id as study_display_id,
    p.tenant_id,
    p.site_id,
    p.diagnosis_icd,
    p.med_rxnorm,
    p.treatment_modality,
    p.gender,
    p.race_ethnicity,
    p.age,
    p.bmi,
    p.baseline_hba1c,
    p.diabetes_type,
    p.study_arm 
FROM drh_participant p;