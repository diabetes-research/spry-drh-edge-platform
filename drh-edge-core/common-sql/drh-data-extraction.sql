CREATE VIEW IF NOT EXISTS drh_schema_logs AS
WITH Guardrail AS (
    SELECT COUNT(*) as total FROM uniform_resource LIMIT 1
),
SchemaData AS (
    SELECT 
        json_extract(content, '$.stream') AS schema_name,
        json_extract(content, '$.schema.properties') AS properties_json,
        json_extract(content, '$.emitted_at') AS detected_at
    FROM uniform_resource, Guardrail
    WHERE Guardrail.total > 1 
      AND json_valid(content)
      AND json_extract(content, '$.type') = 'SCHEMA'
)
SELECT 
    schema_name,
    COUNT(p.key) AS column_count,
    GROUP_CONCAT(p.key, ', ') AS column_names,
    MAX(detected_at) AS last_updated
FROM SchemaData, json_each(properties_json) AS p
GROUP BY schema_name;

-- =====================================================================
-- SQLITE GENERATOR: STANDARD DRH VIEWS
-- =====================================================================

-- Update uniform_resource to anonymize emails for authors and investigators
UPDATE uniform_resource
SET content = json_set(
    content, 
    '$.record.email', 
    surveilr_anonymize_email(json_extract(content, '$.record.email'))
)
WHERE json_extract(content, '$.type') = 'RECORD'
  AND json_extract(content, '$.stream') IN ('author', 'investigator')
  AND json_extract(content, '$.record.email') IS NOT NULL;

-- 1. View for author
CREATE VIEW IF NOT EXISTS drh_author AS
SELECT     
    json_extract(content, '$.record.author_id') AS author_id,
    json_extract(content, '$.record.first_name') AS first_name,
    json_extract(content, '$.record.last_name') AS last_name,
    json_extract(content, '$.record.email') AS email
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'author'
  AND json_extract(content, '$.type') = 'RECORD';

-- 2. View for lab
CREATE VIEW IF NOT EXISTS drh_lab AS
SELECT 
    json_extract(content, '$.record.lab_id') AS lab_id,
    json_extract(content, '$.record.lab_name') AS lab_name,
    json_extract(content, '$.record.site_id') AS site_id
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'lab'
  AND json_extract(content, '$.type') = 'RECORD';


-- 3. View for institution
CREATE VIEW IF NOT EXISTS drh_institution AS
SELECT     
    json_extract(content, '$.record.institution_id') AS institution_id,
    json_extract(content, '$.record.institution_name') AS institution_name,
    json_extract(content, '$.record.city') AS city,
    json_extract(content, '$.record.state') AS state,
    json_extract(content, '$.record.country') AS country,
    json_extract(content, '$.record.tenant_id') AS tenant_id,
    json_extract(content, '$.record.tenant_name') AS tenant_name
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'institution'
  AND json_extract(content, '$.type') = 'RECORD';

-- 4. View for investigator
CREATE VIEW IF NOT EXISTS drh_investigator AS
SELECT     
    json_extract(content, '$.record.investigator_id') AS investigator_id,
    json_extract(content, '$.record.investigator_name') AS investigator_name,
    json_extract(content, '$.record.email') AS email,
    json_extract(content, '$.record.institution_id') AS institution_id,
    json_extract(content, '$.record.study_id') AS study_id,
    json_extract(content, '$.record.tenant_id') AS tenant_id,
    json_extract(content, '$.record.tenant_name') AS tenant_name
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'investigator'
  AND json_extract(content, '$.type') = 'RECORD';


-- 5. View for participant
CREATE VIEW IF NOT EXISTS drh_participant AS
SELECT     
    json_extract(content, '$.record.participant_id') AS participant_id,
    json_extract(content, '$.record.study_id') AS study_id,
    json_extract(content, '$.record.site_id') AS site_id,
    json_extract(content, '$.record.diagnosis_icd') AS diagnosis_icd,
    json_extract(content, '$.record.med_rxnorm') AS med_rxnorm,
    json_extract(content, '$.record.treatment_modality') AS treatment_modality,
    json_extract(content, '$.record.gender') AS gender,
    json_extract(content, '$.record.race_ethnicity') AS race_ethnicity,
    json_extract(content, '$.record.age') AS age,
    json_extract(content, '$.record.bmi') AS bmi,
    json_extract(content, '$.record.baseline_hba1c') AS baseline_hba1c,
    json_extract(content, '$.record.diabetes_type') AS diabetes_type,
    json_extract(content, '$.record.study_arm') AS study_arm,
    json_extract(content, '$.record.tenant_id') AS tenant_id,
    json_extract(content, '$.record.tenant_name') AS tenant_name
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'participant'
  AND json_extract(content, '$.type') = 'RECORD';

-- 6. View for publication
CREATE VIEW IF NOT EXISTS drh_publication AS
SELECT     
    json_extract(content, '$.record.publication_id') AS publication_id,
    json_extract(content, '$.record.publication_title') AS publication_title,
    json_extract(content, '$.record.digital_object_identifier') AS digital_object_identifier,
    json_extract(content, '$.record.publication_site') AS publication_site,
    json_extract(content, '$.record.study_id') AS study_id,
    json_extract(content, '$.record.tenant_id') AS tenant_id,
    json_extract(content, '$.record.tenant_name') AS tenant_name
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'publication'
  AND json_extract(content, '$.type') = 'RECORD';

-- 7. View for site
CREATE VIEW IF NOT EXISTS drh_site AS
SELECT     
    json_extract(content, '$.record.study_id') AS study_id,
    json_extract(content, '$.record.site_id') AS site_id,
    json_extract(content, '$.record.site_name') AS site_name,
    json_extract(content, '$.record.site_type') AS site_type,
    json_extract(content, '$.record.tenant_id') AS tenant_id,
    json_extract(content, '$.record.tenant_name') AS tenant_name
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'site'
  AND json_extract(content, '$.type') = 'RECORD';

-- 8. View for study
CREATE VIEW IF NOT EXISTS drh_study AS
SELECT     
    json_extract(content, '$.record.study_id') AS study_id,
    json_extract(content, '$.record.study_name') AS study_name,
    json_extract(content, '$.record.start_date') AS start_date,
    json_extract(content, '$.record.end_date') AS end_date,
    json_extract(content, '$.record.treatment_modalities') AS treatment_modalities,
    json_extract(content, '$.record.funding_source') AS funding_source,
    json_extract(content, '$.record.nct_number') AS nct_number,
    json_extract(content, '$.record.study_description') AS study_description,
    json_extract(content, '$.record.tenant_id') AS tenant_id,
    json_extract(content, '$.record.tenant_name') AS tenant_name
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'study'
  AND json_extract(content, '$.type') = 'RECORD';

-- =====================================================================
-- METADATA VIEWS
-- =====================================================================
  -- 1. View for cgm_file_metadata
CREATE VIEW IF NOT EXISTS drh_cgm_file_metadata AS
SELECT 
    json_extract(content, '$.record.metadata_id') AS metadata_id,
    json_extract(content, '$.record.devicename') AS devicename,
    json_extract(content, '$.record.device_id') AS device_id,
    json_extract(content, '$.record.source_platform') AS source_platform,
    json_extract(content, '$.record.patient_id') AS patient_id,
    json_extract(content, '$.record.file_name') AS file_name,
    json_extract(content, '$.record.file_format') AS file_format,
    json_extract(content, '$.record.file_upload_date') AS file_upload_date,
    json_extract(content, '$.record.data_start_date') AS data_start_date,
    json_extract(content, '$.record.data_end_date') AS data_end_date,
    json_extract(content, '$.record.map_field_of_cgm_date') AS map_field_of_cgm_date,
    json_extract(content, '$.record.map_field_of_cgm_value') AS map_field_of_cgm_value,
    json_extract(content, '$.record.study_id') AS study_id,
    json_extract(content, '$.record.map_field_of_patient_id') AS map_field_of_patient_id,
    json_extract(content, '$.record.tenant_id') AS tenant_id,
    json_extract(content, '$.record.tenant_name') AS tenant_name
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'cgm_file_metadata'
  AND json_extract(content, '$.type') = 'RECORD';


-- 2. View for meal_file_metadata
CREATE VIEW IF NOT EXISTS drh_meal_file_metadata AS
SELECT     
    json_extract(content, '$.record.meal_meta_id') AS meal_meta_id,
    json_extract(content, '$.record.participant_id') AS participant_id,
    json_extract(content, '$.record.file_name') AS file_name,
    json_extract(content, '$.record.source') AS source,
    json_extract(content, '$.record.file_format') AS file_format
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'meal_file_metadata'
  AND json_extract(content, '$.type') = 'RECORD';


-- =====================================================================
-- RAW VIEWS FOR CGM, FITNESS, MEAL
-- =====================================================================

-- 1. Create the View for raw_cgm_tracing
CREATE VIEW IF NOT EXISTS drh_raw_cgm_tracing AS
SELECT 
    json_extract(content, '$.record.raw_id') AS raw_id,
    json_extract(content, '$.record.raw_file_name') AS raw_file_name,
    json_extract(content, '$.record.raw_data_payload') AS raw_data_payload
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'raw_cgm_tracing'
  AND json_extract(content, '$.type') = 'RECORD';

-- 2. Create the View for raw_fitness_data
CREATE VIEW IF NOT EXISTS drh_raw_fitness_data AS
SELECT     
    json_extract(content, '$.record.raw_id') AS raw_id,
    json_extract(content, '$.record.raw_file_name') AS raw_file_name,
    json_extract(content, '$.record.raw_data_payload') AS raw_data_payload
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'raw_fitness_data'
  AND json_extract(content, '$.type') = 'RECORD';

-- 3. Create the View for raw_meal_data
CREATE VIEW IF NOT EXISTS drh_raw_meal_data AS
SELECT     
    json_extract(content, '$.record.raw_id') AS raw_id,
    json_extract(content, '$.record.raw_file_name') AS raw_file_name,
    json_extract(content, '$.record.raw_data_payload') AS raw_data_payload
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'raw_meal_data'
  AND json_extract(content, '$.type') = 'RECORD';

--  View for fitness_file_metadata
CREATE VIEW IF NOT EXISTS drh_fitness_file_metadata AS
SELECT     
    json_extract(content, '$.record.fitness_meta_id') AS fitness_meta_id,
    json_extract(content, '$.record.participant_id') AS participant_id,
    json_extract(content, '$.record.file_name') AS file_name,
    json_extract(content, '$.record.source') AS source,
    json_extract(content, '$.record.file_format') AS file_format
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'fitness_file_metadata'
  AND json_extract(content, '$.type') = 'RECORD';

-- =====================================================================
-- DRH DIAGONOSTIC VIEWS
-- =====================================================================

-- View for drh_diagnostics
CREATE VIEW IF NOT EXISTS drh_diagnostics AS
SELECT     
    json_extract(content, '$.record.check_id') AS check_id,
    json_extract(content, '$.record.check_name') AS check_name,
    json_extract(content, '$.record.status') AS status,
    json_extract(content, '$.record.details') AS details
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'drh_diagnostics'
  AND json_extract(content, '$.type') = 'RECORD';

-- View for drh_validation_reports
CREATE VIEW IF NOT EXISTS drh_validation_reports AS
SELECT    
    json_extract(content, '$.record.timestamp') AS report_timestamp,
    json_extract(content, '$.record.folder_name') AS folder_name,
    json_extract(content, '$.record.tenant_id') AS tenant_id,
    json_extract(content, '$.record.tenant_name') AS tenant_name,
    json_extract(content, '$.record.overall_status') AS overall_status,
    json_extract(content, '$.record.report_json') AS report_json
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'drh_validation_reports'
  AND json_extract(content, '$.type') = 'RECORD';


-- =====================================================================
-- OPENTELEMETRY (OTEL) VIEWS
-- =====================================================================

-- 1. View for otel_logs
DROP VIEW IF EXISTS drh_otel_logs;
CREATE VIEW IF NOT EXISTS drh_otel_logs AS
SELECT 
    json_extract(content, '$.record.time_unix_nano') AS time_unix_nano,
    json_extract(content, '$.record.trace_id') AS trace_id,
    json_extract(content, '$.record.span_id') AS span_id,
    json_extract(content, '$.record.severity_number') AS severity_number,
    json_extract(content, '$.record.severity_text') AS severity_text,
    json_extract(content, '$.record.body') AS body,
    json_extract(content, '$.record.attributes') AS attributes,
    json_extract(content, '$.record.resource_id') AS resource_id
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'otel_logs'
  AND json_extract(content, '$.type') = 'RECORD';

-- 2. View for otel_metrics
DROP VIEW IF EXISTS drh_otel_metrics;
CREATE VIEW IF NOT EXISTS drh_otel_metrics AS
SELECT 
    json_extract(content, '$.record.name') AS metric_name,
    json_extract(content, '$.record.description') AS description,
    json_extract(content, '$.record.unit') AS unit,
    json_extract(content, '$.record.time_unix_nano') AS time_unix_nano,
    json_extract(content, '$.record.value') AS metric_value,
    json_extract(content, '$.record.attributes') AS attributes,
    json_extract(content, '$.record.resource_id') AS resource_id
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'otel_metrics'
  AND json_extract(content, '$.type') = 'RECORD';

-- 3. View for otel_resource
DROP VIEW IF EXISTS drh_otel_resource;
CREATE VIEW IF NOT EXISTS drh_otel_resource AS
SELECT 
    json_extract(content, '$.record.resource_id') AS resource_id,
    json_extract(content, '$.record."service.name"') AS service_name,
    json_extract(content, '$.record."service.version"') AS service_version,
    json_extract(content, '$.record."service.instance.id"') AS service_instance_id,
    json_extract(content, '$.record."deployment.environment"') AS deployment_environment,
    json_extract(content, '$.record."singer.role"') AS singer_role,
    json_extract(content, '$.record."singer.stream"') AS singer_stream
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'otel_resource'
  AND json_extract(content, '$.type') = 'RECORD';

-- 4. View for otel_spans
DROP VIEW IF EXISTS drh_otel_spans;
CREATE VIEW IF NOT EXISTS drh_otel_spans AS
SELECT 
    json_extract(content, '$.record.trace_id') AS trace_id,
    json_extract(content, '$.record.span_id') AS span_id,
    json_extract(content, '$.record.parent_span_id') AS parent_span_id,
    json_extract(content, '$.record.name') AS span_name,
    json_extract(content, '$.record.kind') AS span_kind,
    json_extract(content, '$.record.start_time_unix_nano') AS start_time_unix_nano,
    json_extract(content, '$.record.end_time_unix_nano') AS end_time_unix_nano,
    json_extract(content, '$.record.status_code') AS status_code,
    json_extract(content, '$.record.status_message') AS status_message,
    json_extract(content, '$.record.attributes') AS attributes,
    json_extract(content, '$.record.resource_id') AS resource_id
FROM uniform_resource
WHERE json_extract(content, '$.stream') = 'otel_spans'
  AND json_extract(content, '$.type') = 'RECORD';


-- ***************************************************************
-- DE-IDENTIFICATION PROCESS
-- This section performs email anonymization and logs the process.
-- ***************************************************************

-- Drops and recreates the view for device information.
DROP VIEW IF EXISTS drh_device;
CREATE VIEW IF NOT EXISTS drh_device AS
SELECT
    device_id,
    name,
    created_at
FROM
    device d;


-- Insert into orchestration_nature only if it doesn't exist
INSERT
OR IGNORE INTO orchestration_nature (
    orchestration_nature_id,
    nature,
    elaboration,
    created_at,
    created_by,
    updated_at,
    updated_by,
    deleted_at,
    deleted_by,
    activity_log
)
SELECT
    'deidentification', -- Unique ID for the orchestration nature
    'De-identification', -- Human-readable name for the orchestration nature
    NULL, -- No elaboration provided at insert time
    CURRENT_TIMESTAMP, -- Timestamp of creation
    d.device_id, -- Creator's name
    NULL, -- No updated timestamp yet
    NULL, -- No updater yet
    NULL, -- Not deleted
    NULL, -- No deleter yet
    NULL -- No activity log yet
FROM
    drh_device d
LIMIT
    1;

-- Limiting to 1 device
-- Insert into orchestration_session only if it doesn't exist
INSERT
OR IGNORE INTO orchestration_session (
    orchestration_session_id,
    device_id,
    orchestration_nature_id,
    version,
    orch_started_at,
    orch_finished_at,
    elaboration,
    args_json,
    diagnostics_json,
    diagnostics_md
)
SELECT
    'ORCHSESSID-' || hex (randomblob (16)), -- Generate a random hex blob for orchestration_session_id
    d.device_id, -- Pull device_id from the drh_device view
    'deidentification', -- Reference to the orchestration_nature_id we just inserted
    '', -- Version (placeholder)
    CURRENT_TIMESTAMP, -- Start time
    NULL, -- Finished time (to be updated later)
    NULL, -- Elaboration (if any)
    NULL, -- Args JSON (if any)
    NULL, -- Diagnostics JSON (if any)
    NULL -- Diagnostics MD (if any)
FROM
    drh_device d
LIMIT
    1;

-- Limiting to 1 device
-- Create a temporary view to retrieve orchestration session information
CREATE TEMP VIEW IF NOT EXISTS session_info AS
SELECT
    orchestration_session_id
FROM
    orchestration_session
WHERE
    orchestration_nature_id = 'deidentification'
LIMIT
    1;

-- Insert into orchestration_session_entry only if it doesn't exist
INSERT
OR IGNORE INTO orchestration_session_entry (
    orchestration_session_entry_id,
    session_id,
    ingest_src,
    ingest_table_name,
    elaboration
)
VALUES
    (
        'ORCHSESSENID-' || hex (randomblob (16)), -- Generate a random hex blob for orchestration_session_entry_id
        (
            SELECT
                orchestration_session_id
            FROM
                session_info
            limit
                1
        ), -- Session ID from previous insert
        'drh-singer-streams-extraction.sql', -- Replace with actual ingest source
        '', -- Placeholder for actual table name
        NULL -- Elaboration (if any)
    );

-- Create or replace a temporary view for session execution tracking
DROP VIEW IF EXISTS temp_session_info;
-- Remove any existing view
CREATE TEMP VIEW temp_session_info AS
SELECT
    orchestration_session_id,
    (
        SELECT
            orchestration_session_entry_id
        FROM
            orchestration_session_entry
        WHERE
            session_id = orchestration_session_id
        LIMIT
            1
    ) AS orchestration_session_entry_id
FROM
    orchestration_session
WHERE
    orchestration_nature_id = 'deidentification'
LIMIT
    1;

-- Insert into orchestration_session_exec for drh_investigator
INSERT
OR IGNORE INTO orchestration_session_exec (
    orchestration_session_exec_id,
    exec_nature,
    session_id,
    session_entry_id,
    exec_code,
    exec_status,
    input_text,
    output_text,
    exec_error_text,
    narrative_md
)
SELECT
    'ORCHSESSEXID-' || (
        (
            SELECT
                COUNT(*)
            FROM
                orchestration_session_exec
        ) + 1
    ), -- Unique ID based on count
    'De-identification', -- Nature of execution
    s.orchestration_session_id, -- Session ID from the temp view
    s.orchestration_session_entry_id, -- Session Entry ID from the temp view
    'UPDATE drh_investigator SET email = surveilr_anonymize_email(email) executed', -- Description of the executed code
    'SUCCESS', -- Execution status
    'email column in drh_investigator', -- Input text reference
    'De-identification completed', -- Output text summary
    CASE
        WHEN (
            SELECT
                changes () = 0
        ) THEN 'No rows updated' -- Capture update status
        ELSE NULL
    END,
    'username in email is masked' -- Narrative for clarification
FROM
    temp_session_info s;

-- From the temporary session info view
-- Insert into orchestration_session_exec for uniform_resource_author
INSERT
OR IGNORE INTO orchestration_session_exec (
    orchestration_session_exec_id,
    exec_nature,
    session_id,
    session_entry_id,
    exec_code,
    exec_status,
    input_text,
    output_text,
    exec_error_text,
    narrative_md
)
SELECT
    'ORCHSESSEXID-' || (
        (
            SELECT
                COUNT(*)
            FROM
                orchestration_session_exec
        ) + 1
    ), -- Unique ID based on count
    'De-identification', -- Nature of execution
    s.orchestration_session_id, -- Session ID from the temp view
    s.orchestration_session_entry_id, -- Session Entry ID from the temp view
    'UPDATE uniform_resource_author SET email = surveilr_anonymize_email(email) executed', -- Description of the executed code
    'SUCCESS', -- Execution status
    'email column in uniform_resource_author', -- Input text reference
    'De-identification completed', -- Output text summary
    CASE
        WHEN (
            SELECT
                changes () = 0
        ) THEN 'No rows updated' -- Capture update status
        ELSE NULL
    END,
    'username in email is masked' -- Narrative for clarification
FROM
    temp_session_info s;

-- From the temporary session info view
-- Update orchestration_session to set finished timestamp and diagnostics
UPDATE orchestration_session
SET
    orch_finished_at = CURRENT_TIMESTAMP, -- Set the finish time
    diagnostics_json = '{"status": "completed"}', -- Diagnostics status in JSON format
    diagnostics_md = 'De-identification process completed' -- Markdown summary
WHERE
    orchestration_session_id = (
        SELECT
            orchestration_session_id
        FROM
            temp_session_info
        LIMIT
            1
    );



-- Drop and recreate the vw_orchestration_deidentify view
-- Creates a consolidated view of de-identification execution sessions, joining
-- execution details with overall session information.
DROP VIEW IF EXISTS drh_vw_orchestration_deidentify;
CREATE VIEW
    drh_vw_orchestration_deidentify AS
SELECT
    osex.orchestration_session_exec_id,
    osex.exec_nature,
    osex.session_id,
    osex.session_entry_id,
    osex.parent_exec_id,
    osex.namespace,
    osex.exec_identity,
    osex.exec_code,
    osex.exec_status,
    osex.input_text,
    osex.exec_error_text,
    osex.output_text,
    osex.output_nature,
    osex.narrative_md,
    os.device_id,
    os.orchestration_nature_id,
    os.version,
    os.orch_started_at,
    os.orch_finished_at,
    os.args_json,
    os.diagnostics_json,
    os.diagnostics_md
FROM
    orchestration_session_exec osex
    JOIN orchestration_session os ON osex.session_id = os.orchestration_session_id
WHERE
    os.orchestration_nature_id = 'deidentification';



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


