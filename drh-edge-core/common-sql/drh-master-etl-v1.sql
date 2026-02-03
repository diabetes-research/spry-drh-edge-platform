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
    strftime('%Y-%m-%d %H:%M:%S', json_extract(p.value, '$.Date')) AS Date_Time,    
    CAST(json_extract(p.value, '$.Steps') AS INTEGER) AS Steps,
    CAST(json_extract(p.value, '$.Exercise_Minutes') AS REAL) AS Exercise_Minutes,
    CAST(json_extract(p.value, '$.Calories_Burned') AS REAL) AS Calories_Burned,
    CAST(json_extract(p.value, '$.Distance') AS REAL) AS Distance,
    CAST(json_extract(p.value, '$.Heart_Rate') AS REAL) AS Heart_Rate
FROM joined_data j
CROSS JOIN json_each(j.raw_data_payload) AS p;