DROP VIEW IF EXISTS combined_cgm_tracing;
CREATE VIEW IF NOT EXISTS combined_cgm_tracing AS
WITH joined_data AS (
    SELECT 
        m.tenant_id, m.study_id, m.patient_id, 
        m.map_field_of_cgm_date, m.map_field_of_cgm_value,
        r.raw_data_payload
    FROM drh_cgm_file_metadata m
    JOIN drh_raw_cgm_tracing r ON (
        -- Insert the "Any Format" Join Logic here
        LOWER(TRIM(CASE WHEN INSTR(r.raw_file_name, '.') > 0 THEN SUBSTR(r.raw_file_name, 1, INSTR(r.raw_file_name, '.') - 1) ELSE r.raw_file_name END)) 
        = 
        LOWER(TRIM(CASE WHEN INSTR(m.file_name, '.') > 0 THEN SUBSTR(m.file_name, 1, INSTR(m.file_name, '.') - 1) ELSE m.file_name END))
    )
)
SELECT 
    tenant_id, study_id, patient_id AS participant_id,
    json_extract(p.value, '$."' || map_field_of_cgm_date || '"') AS Date_Time,
    CAST(json_extract(p.value, '$."' || map_field_of_cgm_value || '"') AS REAL) AS CGM_Value
FROM joined_data, json_each(raw_data_payload) AS p;