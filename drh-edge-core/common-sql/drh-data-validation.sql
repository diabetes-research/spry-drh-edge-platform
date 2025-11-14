
-- drh-data-validation.sql
-- 1. DROP the temporary view if it exists (must be a standalone DDL command).
DROP VIEW IF EXISTS temp_ValidationErrors;

-- 2. CREATE the temporary view, consuming the CTEs directly. This ensures correct SQLite parsing.
CREATE TEMP VIEW temp_ValidationErrors AS
WITH MetadataCounts AS (    
    SELECT
        (SELECT COUNT(*) FROM uniform_resource_cgm_file_metadata) AS cgm_meta_count,
        (SELECT COUNT(*) FROM uniform_resource_fitness_file_metadata) AS fitness_meta_count,
        (SELECT COUNT(*) FROM uniform_resource_meal_file_metadata) AS meal_meta_count
),
FileMetadata AS (
    -- Combine and normalize metadata from all resources
    -- This CTE is used for the critical Data Table Existence check (Section 1).
    -- The table name construction now uses advanced REGEXP_REPLACE to ensure a clean name
    -- (lowercase, no extension, no hyphens).
    SELECT 
        patient_id, 
        file_name, 
        'cgm' AS resource_type, 
        'uniform_resource_cgm_' || REPLACE(REGEXP_REPLACE(TRIM(LOWER(file_name)), '\.[^\.]+$', ''), '-', '_') AS expected_table_name 
    FROM 
        uniform_resource_cgm_file_metadata
    
    UNION ALL
    
    -- Fitness metadata is included here, but errors are only logged if the table had records.
    SELECT 
        participant_id as patient_id, 
        file_name, 
        'fitness' AS resource_type, 
        'uniform_resource_fitness_' || REPLACE(REGEXP_REPLACE(TRIM(LOWER(file_name)), '\.[^\.]+$', ''), '-', '_') AS expected_table_name 
    FROM 
        uniform_resource_fitness_file_metadata
    
    UNION ALL
    
    -- Meal metadata is included here, but errors are only logged if the table had records.
    SELECT 
        participant_id as patient_id,
        file_name, 
        'meal' AS resource_type, 
        'uniform_resource_meal_' || REPLACE(REGEXP_REPLACE(TRIM(LOWER(file_name)), '\.[^\.]+$', ''), '-', '_') AS expected_table_name 
    FROM 
        uniform_resource_meal_file_metadata
),

ValidationErrors AS (

    -- =========================================================================
    -- 1. CRITICAL: DATA TABLE EXISTENCE CHECK (PRE-VALIDATION)
    -- Fails if a metadata record exists, but the corresponding data table is missing.
    -- This runs for ALL resources for which metadata was found.
    -- =========================================================================
    SELECT
        'CRITICAL' AS severity,
        t.resource_type || '_DATA_TABLE_MISSING' AS error_type,
        t.file_name AS table_name,
        'Metadata exists for file: ' || t.file_name || ', but the corresponding data table ' || t.expected_table_name || ' is missing in the database.' AS error_detail,
        t.patient_id,
        t.file_name
    FROM
        FileMetadata t
    LEFT JOIN
        sqlite_master sm ON sm.type = 'table' AND sm.name = t.expected_table_name
    WHERE
        sm.name IS NULL

    UNION ALL

    -- =========================================================================
    -- 2. MANDATORY: CGM METADATA FIELD COMPLETENESS CHECK (UNCONDITIONAL)
    -- Fails if any required column is NULL or empty/whitespace in uniform_resource_cgm_file_metadata.
    -- =========================================================================
    SELECT
        'CRITICAL' AS severity,
        'CGM_META_FIELD_MISSING' AS error_type,
        'uniform_resource_cgm_file_metadata' AS table_name,
        'A mandatory column (patient_id, mapping fields, file_name, file_format, or map_field_of_cgm_value) is null or empty in row ' || ROW_NUMBER() OVER (ORDER BY file_name) AS error_detail,
        t.patient_id,
        t.file_name
    FROM
        uniform_resource_cgm_file_metadata t
    WHERE
        t.patient_id IS NULL OR TRIM(t.patient_id) = '' OR
        t.map_field_of_cgm_date IS NULL OR TRIM(t.map_field_of_cgm_date) = '' OR
        t.file_name IS NULL OR TRIM(t.file_name) = '' OR
        t.file_format IS NULL OR TRIM(t.file_format) = '' OR
        t.map_field_of_cgm_value IS NULL OR TRIM(t.map_field_of_cgm_value) = ''
    UNION ALL

    -- =========================================================================
    -- 3. CONDITIONAL: FITNESS METADATA FIELD COMPLETENESS
    -- ONLY runs if uniform_resource_fitness_file_metadata has records (i.e., Fitness is present).
    -- =========================================================================
    SELECT
        'CRITICAL' AS severity,
        'FITNESS_META_FIELD_MISSING' AS error_type,
        'uniform_resource_fitness_file_metadata' AS table_name,
        'A mandatory column (participant_id, file_name, file_format, or source) is null or empty in row ' || ROW_NUMBER() OVER (ORDER BY file_name) AS error_detail,
        t.participant_id as patient_id,
        t.file_name
    FROM
        uniform_resource_fitness_file_metadata t, MetadataCounts mc
    WHERE
        mc.fitness_meta_count > 0 AND ( -- Condition to skip if metadata is empty
            t.participant_id IS NULL OR TRIM(t.participant_id) = '' OR
            t.file_name IS NULL OR TRIM(t.file_name) = '' OR
            t.file_format IS NULL OR TRIM(t.file_format) = '' OR
            t.source IS NULL OR TRIM(t.source) = ''
        )

    UNION ALL

    -- =========================================================================
    -- 4. CONDITIONAL: MEAL METADATA FIELD COMPLETENESS
    -- ONLY runs if uniform_resource_meal_file_metadata has records (i.e., Meal is present).
    -- =========================================================================
    SELECT
        'CRITICAL' AS severity,
        'MEAL_META_FIELD_MISSING' AS error_type,
        'uniform_resource_meal_file_metadata' AS table_name,
        'A mandatory column (participant_id, file_name, file_format, or source) is null or empty in row ' || ROW_NUMBER() OVER (ORDER BY file_name) AS error_detail,
        t.participant_id as patient_id,
        t.file_name
    FROM
        uniform_resource_meal_file_metadata t, MetadataCounts mc
    WHERE
        mc.meal_meta_count > 0 AND ( -- Condition to skip if metadata is empty
            t.participant_id IS NULL OR TRIM(t.participant_id) = '' OR
            t.file_name IS NULL OR TRIM(t.file_name) = '' OR
            t.file_format IS NULL OR TRIM(t.file_format) = '' OR
            t.source IS NULL OR TRIM(t.source) = ''
        )   
  
)
SELECT
    severity,
    error_type,
    table_name,
    error_detail,
    patient_id,
    file_name
FROM
    ValidationErrors;

-- ***************************************************************
-- SECTION 3: PERSISTENT ERROR LOGGING
-- Inserts the detected errors from the temp view into the persistent
-- orchestration_session_issue table for audit and reporting.
-- ***************************************************************
-- Temporary view to retrieve device information for logging.
CREATE TEMP VIEW IF NOT EXISTS device_info AS
SELECT
    device_id,
    name,
    created_at
FROM
    device d;

-- Insert the 'Verification and Validation' nature into the orchestration_nature table if it doesn't exist.
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
    'V&V', -- orchestration_nature_id (unique identifier for V&V process)
    'Verification and Validation', -- nature description
    NULL, -- elaboration
    CURRENT_TIMESTAMP, -- Timestamp of creation
    d.device_id, -- created_by (using the current device ID)
    NULL, -- updated_at
    NULL, -- updated_by
    NULL, -- deleted_at
    NULL, -- deleted_by
    NULL -- activity_log
FROM
    device_info d
LIMIT
    1;

-- Insert a new orchestration session for the V&V process.
-- This records the start time of the data quality run.
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
    'ORCHSESSID-' || hex (randomblob (16)), -- Generate a unique session ID
    d.device_id, -- Device ID running the session
    'V&V', -- Reference to the V&V nature
    '', -- Version (placeholder)
    CURRENT_TIMESTAMP, -- Start time of the orchestration
    NULL, -- Finished time (to be updated later)
    NULL, -- Elaboration (if any)
    NULL, -- Args JSON (if any)
    NULL, -- Diagnostics JSON (if any)
    NULL -- Diagnostics MD (if any)
FROM
    device_info d
LIMIT
    1;

-- Temporary view to retrieve the newly created orchestration session ID.
CREATE TEMP VIEW IF NOT EXISTS session_info AS
SELECT
    orchestration_session_id
FROM
    orchestration_session
WHERE
    orchestration_nature_id = 'V&V'
LIMIT
    1;

-- Insert an entry for the data quality script within the session.
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
        'ORCHSESSENID-' || hex (randomblob (16)), -- Generate a unique session entry ID
        (
            SELECT
                orchestration_session_id
            FROM
                session_info
            limit
                1
        ), -- Reference the current session ID
        'drh-data-quality-prepare.sql', -- Source script name
        '', -- Placeholder for actual table name
        NULL -- Elaboration (if any)
    );

-- Create or Replace Temp Session Info View (Re-creation for consistent reference)
DROP VIEW IF EXISTS temp_session_info;
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
    orchestration_nature_id = 'V&V'
LIMIT
    1;

INSERT OR IGNORE INTO orchestration_session_issue (
    orchestration_session_issue_id, -- Mapped from user schema
    session_id,
    session_entry_id,
    issue_type,
    issue_message,
    issue_row,
    issue_column,
    invalid_value,
    remediation,
    elaboration
)
SELECT
    NULL AS orchestration_session_issue_id, -- Assuming auto-generated primary key
    (SELECT orchestration_session_id FROM temp_session_info LIMIT 1) AS session_id,
    NULL AS session_entry_id,
    error_type AS issue_type,
    -- Concatenating table_name and severity into issue_message to retain diagnostic context
    '[' || severity || '] Table: ' || table_name || ' - ' || error_detail AS issue_message,
    NULL AS issue_row,
    NULL AS issue_column,
    NULL AS invalid_value,
    -- Simple remediation guide based on error type
    CASE
        WHEN error_type LIKE '%META_FIELD_MISSING%' THEN 'Check the corresponding metadata table and fill in the missing mandatory fields.'
        WHEN error_type LIKE '%DATA_TABLE_MISSING%' THEN 'Ensure the data file specified in the metadata is loaded and the corresponding data table exists.'
        WHEN error_type LIKE '%DATA_CONTENT_EMPTY%' THEN 'Check that the data files were correctly parsed and inserted into the unified data table.'
        ELSE 'Review the data quality issue and consult documentation for remediation.'
    END AS remediation,
    NULL AS elaboration
FROM
    temp_ValidationErrors;


-----------------------------------------------------------------------------
-- ***************************************************************
-- SECTION : EXPECTED SCHEMA DEFINITION
-- This view defines the required schema for data tables, including primary keys (PK), 
-- NOT NULL constraints, data types, and Foreign Key (FK) relationships.
-- This is used to check for missing columns and incorrect types in Section 2.
-- ***************************************************************

CREATE VIEW IF NOT EXISTS expected_schema_view AS
-- 'references_table' and 'references_column' define Foreign Key relationships.
-- 'column_type' is set to DATE or REAL where appropriate for integrity checks.
-- institution table
SELECT 'uniform_resource_institution' AS table_name, 'institution_id' AS column_name, 'TEXT' AS column_type, 1 AS is_primary_key, 1 AS not_null, NULL AS references_table, NULL AS references_column
UNION ALL
SELECT 'uniform_resource_institution', 'institution_name', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_institution', 'city', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_institution', 'state', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_institution', 'country', 'TEXT', 0, 1, NULL, NULL
UNION ALL
-- lab table
SELECT 'uniform_resource_lab', 'lab_id', 'TEXT', 1, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_lab', 'lab_name', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_lab', 'lab_pi', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_lab', 'institution_id', 'TEXT', 0, 1, 'uniform_resource_institution', 'institution_id'
UNION ALL
SELECT 'uniform_resource_lab', 'study_id', 'TEXT', 0, 1, 'uniform_resource_study', 'study_id'
UNION ALL
-- study table
SELECT 'uniform_resource_study', 'study_id', 'TEXT', 1, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_study', 'study_name', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_study', 'start_date', 'DATE', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_study', 'end_date', 'DATE', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_study', 'treatment_modalities', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_study', 'funding_source', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_study', 'nct_number', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_study', 'study_description', 'TEXT', 0, 1, NULL, NULL
UNION ALL
-- participant table
SELECT 'uniform_resource_participant', 'participant_id', 'TEXT', 1, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_participant', 'study_id', 'TEXT', 0, 1, 'uniform_resource_study', 'study_id'
UNION ALL
SELECT 'uniform_resource_participant', 'site_id', 'TEXT', 0, 1, 'uniform_resource_site', 'site_id'
UNION ALL
SELECT 'uniform_resource_participant', 'diagnosis_icd', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_participant', 'med_rxnorm', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_participant', 'treatment_modality', 'TEXT', 0, 0, NULL, NULL
UNION ALL
SELECT 'uniform_resource_participant', 'gender', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_participant', 'race_ethnicity', 'TEXT', 0, 0, NULL, NULL
UNION ALL
SELECT 'uniform_resource_participant', 'age', 'REAL', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_participant', 'bmi', 'REAL', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_participant', 'baseline_hba1c', 'REAL', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_participant', 'diabetes_type', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_participant', 'study_arm', 'TEXT', 0, 1, NULL, NULL
UNION ALL
-- site table
SELECT 'uniform_resource_site', 'site_id', 'TEXT', 1, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_site', 'study_id', 'TEXT', 0, 1, 'uniform_resource_study', 'study_id'
UNION ALL
SELECT 'uniform_resource_site', 'site_name', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_site', 'site_type', 'TEXT', 0, 1, NULL, NULL
UNION ALL
-- investigator table
SELECT 'uniform_resource_investigator', 'investigator_id', 'TEXT', 1, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_investigator', 'investigator_name', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_investigator', 'email', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_investigator', 'institution_id', 'TEXT', 0, 1, 'uniform_resource_institution', 'institution_id'
UNION ALL
SELECT 'uniform_resource_investigator', 'study_id', 'TEXT', 0, 1, 'uniform_resource_study', 'study_id'
UNION ALL
-- publication table
SELECT 'uniform_resource_publication', 'publication_id', 'TEXT', 1, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_publication', 'publication_title', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_publication', 'digital_object_identifier', 'TEXT', 0, 0, NULL, NULL
UNION ALL
SELECT 'uniform_resource_publication', 'publication_site', 'TEXT', 0, 0, NULL, NULL
UNION ALL
SELECT 'uniform_resource_publication', 'study_id', 'TEXT', 0, 1, 'uniform_resource_study', 'study_id'
UNION ALL
-- author table
SELECT 'uniform_resource_author', 'author_id', 'TEXT', 1, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_author', 'name', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_author', 'email', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_author', 'investigator_id', 'TEXT', 0, 1, 'uniform_resource_investigator', 'investigator_id'
UNION ALL
SELECT 'uniform_resource_author', 'study_id', 'TEXT', 0, 1, 'uniform_resource_study', 'study_id'
UNION ALL
-- cgm_file_metadata table
SELECT 'uniform_resource_cgm_file_metadata', 'metadata_id', 'TEXT', 1, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_cgm_file_metadata', 'devicename', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_cgm_file_metadata', 'device_id', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_cgm_file_metadata', 'source_platform', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_cgm_file_metadata', 'patient_id', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_cgm_file_metadata', 'file_name', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_cgm_file_metadata', 'file_format', 'TEXT', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_cgm_file_metadata', 'file_upload_date', 'DATE', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_cgm_file_metadata', 'data_start_date', 'DATE', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_cgm_file_metadata', 'data_end_date', 'DATE', 0, 1, NULL, NULL
UNION ALL
SELECT 'uniform_resource_cgm_file_metadata', 'study_id', 'TEXT', 0, 1, 'uniform_resource_study', 'study_id';
-------------------------------------------------------------------------------
-- ***************************************************************
-- SECTION : ORCHESTRATION AND ISSUE LOGGING
-- This section handles recording the V&V process in orchestration tables
-- and logging non-halting (though still critical) data quality issues.
-- ***************************************************************



-- Create or Replace Temp Schema Validation Missing Columns View
-- Identifies columns present in the expected schema but missing from the actual database tables.
DROP VIEW IF EXISTS temp_SchemaValidationMissingColumns;
CREATE TEMP VIEW temp_SchemaValidationMissingColumns AS
SELECT
    'Schema Validation: Missing Columns' AS heading,
    e.table_name,
    e.column_name,
    e.column_type,
    e.is_primary_key,
    'Missing column: ' || e.column_name || ' in table ' || e.table_name AS status,
    'Include the ' || e.column_name || ' in table ' || e.table_name AS remediation
FROM
    expected_schema_view e
    LEFT JOIN (
        -- Select all existing table columns (excluding tracing and transform tables)
        SELECT
            m.name AS table_name,
            p.name AS column_name,
            p.type AS column_type,
            p.pk AS is_primary_key
        FROM
            sqlite_master m
            JOIN pragma_table_info (m.name) p
        WHERE
            m.type = 'table'
            AND m.name NOT LIKE 'uniform_resource_cgm_tracing%'
            AND m.name != 'uniform_resource_transform'
            AND m.name LIKE 'uniform_resource_%'
    ) a ON e.table_name = a.table_name
    AND e.column_name = a.column_name
WHERE
    a.column_name IS NULL; -- Filter for columns that are expected but not found

-- Log Missing Column errors into the orchestration_session_issue table.
INSERT
OR IGNORE INTO orchestration_session_issue (
    orchestration_session_issue_id,
    session_id,
    session_entry_id,
    issue_type,
    issue_message,
    issue_row,
    issue_column,
    invalid_value,
    remediation,
    elaboration
)
SELECT
    -- Generate a unique UUID for the issue ID
    lower(
        hex (randomblob (4)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (6))
    ) AS orchestration_session_issue_id,
    tsi.orchestration_session_id,
    tsi.orchestration_session_entry_id,
    svc.heading AS issue_type,
    svc.status AS issue_message,
    NULL AS issue_row,
    svc.column_name AS issue_column,
    NULL AS invalid_value,
    svc.remediation,
    NULL AS elaboration
FROM
    temp_SchemaValidationMissingColumns svc
    JOIN temp_session_info tsi ON 1 = 1;


-- Create or Replace Temp Data Integrity Invalid Dates View
-- Checks all date columns (start/end dates, upload dates) to ensure they follow the 'YYYY-MM-DD' format.
DROP VIEW IF EXISTS temp_DataIntegrityInvalidDates;
CREATE TEMP VIEW temp_DataIntegrityInvalidDates AS
SELECT
    'Data Integrity Checks: Invalid Dates' AS heading,
    table_name,
    column_name,
    value,
    'Dates must be in YYYY-MM-DD format: ' || value AS status,
    'The date value in column: ' || column_name || ' of table ' || table_name || ' does not follow the YYYY-MM-DD format. Please ensure the dates are in this format' AS remediation
FROM
    (
        -- Collect all date-containing columns across relevant tables
        SELECT 'uniform_resource_study' AS table_name, 'start_date' AS column_name, start_date AS value FROM uniform_resource_study WHERE start_date IS NOT NULL AND start_date != ''
        UNION ALL
        SELECT 'uniform_resource_study' AS table_name, 'end_date' AS column_name, end_date AS value FROM uniform_resource_study WHERE end_date IS NOT NULL AND end_date != ''
        UNION ALL
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'file_upload_date' AS column_name, file_upload_date AS value FROM uniform_resource_cgm_file_metadata WHERE file_upload_date IS NOT NULL AND file_upload_date != ''
        UNION ALL
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'data_start_date' AS column_name, data_start_date AS value FROM uniform_resource_cgm_file_metadata WHERE data_start_date IS NOT NULL AND data_start_date != ''
        UNION ALL
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'data_end_date' AS column_name, data_end_date AS value FROM uniform_resource_cgm_file_metadata WHERE data_end_date IS NOT NULL AND data_end_date != ''
    )
WHERE
    value NOT LIKE '____-__-__'; -- Simple regex check for YYYY-MM-DD format

-- Log Invalid Date errors into the orchestration_session_issue table.
INSERT
OR IGNORE INTO orchestration_session_issue (
    orchestration_session_issue_id,
    session_id,
    session_entry_id,
    issue_type,
    issue_message,
    issue_row,
    issue_column,
    invalid_value,
    remediation,
    elaboration
)
SELECT
    -- Generate a unique UUID for the issue ID
    lower(
        hex (randomblob (4)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (6))
    ) AS orchestration_session_issue_id,
    tsi.orchestration_session_id,
    tsi.orchestration_session_entry_id,
    diid.heading AS issue_type,
    diid.status AS issue_message,
    NULL AS issue_row,
    diid.column_name AS issue_column,
    diid.value AS invalid_value,
    diid.remediation,
    NULL AS elaboration
FROM
    temp_DataIntegrityInvalidDates diid
    JOIN temp_session_info tsi ON 1 = 1;

-- Create or Replace Temp Data Integrity Empty Cells View
-- Checks all mandatory (NOT NULL) columns defined in the expected schema for NULL or empty string values.
DROP VIEW IF EXISTS DataIntegrityEmptyCells;
CREATE TEMP VIEW DataIntegrityEmptyCells AS
SELECT
    'Data Integrity Checks: Empty Cells' AS heading,
    table_name,
    column_name,
    'The rows empty are:' || GROUP_CONCAT (rowid) AS issue_row, -- Grouping rowids where the value is missing
    'The following rows in column ' || column_name || ' of file ' || substr (table_name, 18) || ' are either NULL or empty.' AS status,
    'Please provide values for the ' || column_name || ' column in file ' || substr (table_name, 18) || '.The Rows are:' || GROUP_CONCAT (rowid) AS remediation
FROM
    (
        -- List of all mandatory columns to check for NULL/Empty values
        -- uniform_resource_study table
        SELECT 'uniform_resource_study' AS table_name, 'study_id' AS column_name, study_id AS value, rowid FROM uniform_resource_study WHERE study_id IS NULL OR study_id = ''
        UNION ALL
        SELECT 'uniform_resource_study' AS table_name, 'study_name' AS column_name, study_name AS value, rowid FROM uniform_resource_study WHERE study_name IS NULL OR study_name = ''
        UNION ALL
        SELECT 'uniform_resource_study' AS table_name, 'start_date' AS column_name, start_date AS value, rowid FROM uniform_resource_study WHERE start_date IS NULL OR start_date = ''
        UNION ALL
        SELECT 'uniform_resource_study' AS table_name, 'end_date' AS column_name, end_date AS value, rowid FROM uniform_resource_study WHERE end_date IS NULL OR end_date = ''
        UNION ALL
        SELECT 'uniform_resource_study' AS table_name, 'treatment_modalities' AS column_name, treatment_modalities AS value, rowid FROM uniform_resource_study WHERE treatment_modalities IS NULL OR treatment_modalities = ''
        UNION ALL
        SELECT 'uniform_resource_study' AS table_name, 'funding_source' AS column_name, funding_source AS value, rowid FROM uniform_resource_study WHERE funding_source IS NULL OR funding_source = ''
        UNION ALL
        SELECT 'uniform_resource_study' AS table_name, 'nct_number' AS column_name, nct_number AS value, rowid FROM uniform_resource_study WHERE nct_number IS NULL OR nct_number = ''
        UNION ALL
        SELECT 'uniform_resource_study' AS table_name, 'study_description' AS column_name, study_description AS value, rowid FROM uniform_resource_study WHERE study_description IS NULL OR study_description = ''
        UNION ALL
        --- uniform_resource_institution table
        SELECT 'uniform_resource_institution' AS table_name, 'institution_id' AS column_name, institution_id AS value, rowid FROM uniform_resource_institution WHERE institution_id IS NULL OR institution_id = ''
        UNION ALL
        SELECT 'uniform_resource_institution' AS table_name, 'institution_name' AS column_name, institution_name AS value, rowid FROM uniform_resource_institution WHERE institution_name IS NULL OR institution_name = ''
        UNION ALL
        SELECT 'uniform_resource_institution' AS table_name, 'city' AS column_name, city AS value, rowid FROM uniform_resource_institution WHERE city IS NULL OR city = ''
        UNION ALL
        SELECT 'uniform_resource_institution' AS table_name, 'state' AS column_name, state AS value, rowid FROM uniform_resource_institution WHERE state IS NULL OR state = ''
        UNION ALL
        SELECT 'uniform_resource_institution' AS table_name, 'country' AS column_name, country AS value, rowid FROM uniform_resource_institution WHERE country IS NULL OR country = ''
        UNION ALL
        -- uniform_resource_site table
        SELECT 'uniform_resource_site' AS table_name, 'site_id' AS column_name, site_id AS value, rowid FROM uniform_resource_site WHERE site_id IS NULL OR site_id = ''
        UNION ALL
        SELECT 'uniform_resource_site' AS table_name, 'study_id' AS column_name, study_id AS value, rowid FROM uniform_resource_site WHERE study_id IS NULL OR study_id = ''
        UNION ALL
        SELECT 'uniform_resource_site' AS table_name, 'site_name' AS column_name, site_name AS value, rowid FROM uniform_resource_site WHERE site_name IS NULL OR site_name = ''
        UNION ALL
        SELECT 'uniform_resource_site' AS table_name, 'site_type' AS column_name, site_type AS value, rowid FROM uniform_resource_site WHERE site_type IS NULL OR site_type = ''
        UNION ALL
        -- uniform_resource_lab table
        SELECT 'uniform_resource_lab' AS table_name, 'lab_id' AS column_name, lab_id AS value, rowid FROM uniform_resource_lab WHERE lab_id IS NULL OR lab_id = ''
        UNION ALL
        SELECT 'uniform_resource_lab' AS table_name, 'lab_name' AS column_name, lab_name AS value, rowid FROM uniform_resource_lab WHERE lab_name IS NULL OR lab_name = ''
        UNION ALL
        SELECT 'uniform_resource_lab' AS table_name, 'lab_pi' AS column_name, lab_pi AS value, rowid FROM uniform_resource_lab WHERE lab_pi IS NULL OR lab_pi = ''
        UNION ALL
        SELECT 'uniform_resource_lab' AS table_name, 'institution_id' AS column_name, institution_id AS value, rowid FROM uniform_resource_lab WHERE institution_id IS NULL OR institution_id = ''
        UNION ALL
        SELECT 'uniform_resource_lab' AS table_name, 'study_id' AS column_name, study_id AS value, rowid FROM uniform_resource_lab WHERE study_id IS NULL OR study_id = ''
        UNION ALL
        -- uniform_resource_investigator table
        SELECT 'uniform_resource_investigator' AS table_name, 'investigator_id' AS column_name, investigator_id AS value, rowid FROM uniform_resource_investigator WHERE investigator_id IS NULL OR investigator_id = ''
        UNION ALL
        SELECT 'uniform_resource_investigator' AS table_name, 'investigator_name' AS column_name, investigator_name AS value, rowid FROM uniform_resource_investigator WHERE investigator_name IS NULL OR investigator_name = ''
        UNION ALL
        SELECT 'uniform_resource_investigator' AS table_name, 'email' AS column_name, email AS value, rowid FROM uniform_resource_investigator WHERE email IS NULL OR email = ''
        UNION ALL
        SELECT 'uniform_resource_investigator' AS table_name, 'institution_id' AS column_name, institution_id AS value, rowid FROM uniform_resource_investigator WHERE institution_id IS NULL OR institution_id = ''
        UNION ALL
        SELECT 'uniform_resource_investigator' AS table_name, 'study_id' AS column_name, study_id AS value, rowid FROM uniform_resource_investigator WHERE study_id IS NULL OR study_id = ''
        UNION ALL
        -- uniform_resource_participant table
        SELECT 'uniform_resource_participant' AS table_name, 'participant_id' AS column_name, participant_id AS value, rowid FROM uniform_resource_participant WHERE participant_id IS NULL OR participant_id = ''
        UNION ALL
        SELECT 'uniform_resource_participant' AS table_name, 'study_id' AS column_name, study_id AS value, rowid FROM uniform_resource_participant WHERE study_id IS NULL OR study_id = ''
        UNION ALL
        SELECT 'uniform_resource_participant' AS table_name, 'site_id' AS column_name, site_id AS value, rowid FROM uniform_resource_participant WHERE site_id IS NULL OR site_id = ''
        UNION ALL
        SELECT 'uniform_resource_participant' AS table_name, 'diagnosis_icd' AS column_name, diagnosis_icd AS value, rowid FROM uniform_resource_participant WHERE diagnosis_icd IS NULL OR diagnosis_icd = ''
        UNION ALL
        SELECT 'uniform_resource_participant' AS table_name, 'med_rxnorm' AS column_name, med_rxnorm AS value, rowid FROM uniform_resource_participant WHERE med_rxnorm IS NULL OR med_rxnorm = ''
        UNION ALL
        -- Note: 'treatment_modality' and 'race_ethnicity' are not required (not_null=0) and are skipped here.
        SELECT 'uniform_resource_participant' AS table_name, 'gender' AS column_name, gender AS value, rowid FROM uniform_resource_participant WHERE gender IS NULL OR gender = ''
        UNION ALL
        SELECT 'uniform_resource_participant' AS table_name, 'age' AS column_name, age AS value, rowid FROM uniform_resource_participant WHERE age IS NULL OR age = ''
        UNION ALL
        SELECT 'uniform_resource_participant' AS table_name, 'bmi' AS column_name, bmi AS value, rowid FROM uniform_resource_participant WHERE bmi IS NULL OR bmi = ''
        UNION ALL
        SELECT 'uniform_resource_participant' AS table_name, 'baseline_hba1c' AS column_name, baseline_hba1c AS value, rowid FROM uniform_resource_participant WHERE baseline_hba1c IS NULL OR baseline_hba1c = ''
        UNION ALL
        SELECT 'uniform_resource_participant' AS table_name, 'diabetes_type' AS column_name, diabetes_type AS value, rowid FROM uniform_resource_participant WHERE diabetes_type IS NULL OR diabetes_type = ''
        UNION ALL
        SELECT 'uniform_resource_participant' AS table_name, 'study_arm' AS column_name, study_arm AS value, rowid FROM uniform_resource_participant WHERE study_arm IS NULL OR study_arm = ''
        UNION ALL
        -- uniform_resource_publication table
        SELECT 'uniform_resource_publication' AS table_name, 'publication_id' AS column_name, publication_id AS value, rowid FROM uniform_resource_publication WHERE publication_id IS NULL OR publication_id = ''
        UNION ALL
        SELECT 'uniform_resource_publication' AS table_name, 'publication_title' AS column_name, publication_title AS value, rowid FROM uniform_resource_publication WHERE publication_title IS NULL OR publication_title = ''
        -- Note: 'digital_object_identifier' and 'publication_site' are not required (not_null=0) and are skipped here.
        UNION ALL
        SELECT 'uniform_resource_publication' AS table_name, 'study_id' AS column_name, study_id AS value, rowid FROM uniform_resource_publication WHERE study_id IS NULL OR study_id = ''
        UNION ALL
        -- uniform_resource_author table
        SELECT 'uniform_resource_author' AS table_name, 'author_id' AS column_name, author_id AS value, rowid FROM uniform_resource_author WHERE author_id IS NULL OR author_id = ''
        UNION ALL
        SELECT 'uniform_resource_author' AS table_name, 'name' AS column_name, name AS value, rowid FROM uniform_resource_author WHERE name IS NULL OR name = ''
        UNION ALL
        SELECT 'uniform_resource_author' AS table_name, 'email' AS column_name, email AS value, rowid FROM uniform_resource_author WHERE email IS NULL OR email = ''
        UNION ALL
        SELECT 'uniform_resource_author' AS table_name, 'investigator_id' AS column_name, investigator_id AS value, rowid FROM uniform_resource_author WHERE investigator_id IS NULL OR investigator_id = ''
        UNION ALL
        SELECT 'uniform_resource_author' AS table_name, 'study_id' AS column_name, study_id AS value, rowid FROM uniform_resource_author WHERE study_id IS NULL OR study_id = ''
        UNION ALL
        -- uniform_resource_cgm_file_metadata table
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'metadata_id' AS column_name, metadata_id AS value, rowid FROM uniform_resource_cgm_file_metadata WHERE metadata_id IS NULL OR metadata_id = ''
        UNION ALL
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'devicename' AS column_name, devicename AS value, rowid FROM uniform_resource_cgm_file_metadata WHERE devicename IS NULL OR devicename = ''
        UNION ALL
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'device_id' AS column_name, device_id AS value, rowid FROM uniform_resource_cgm_file_metadata WHERE device_id IS NULL OR device_id = ''
        UNION ALL
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'source_platform' AS column_name, source_platform AS value, rowid FROM uniform_resource_cgm_file_metadata WHERE source_platform IS NULL OR source_platform = ''
        UNION ALL
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'patient_id' AS column_name, patient_id AS value, rowid FROM uniform_resource_cgm_file_metadata WHERE patient_id IS NULL OR patient_id = ''
        UNION ALL
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'file_name' AS column_name, file_name AS value, rowid FROM uniform_resource_cgm_file_metadata WHERE file_name IS NULL OR file_name = ''
        UNION ALL
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'file_format' AS column_name, file_format AS value, rowid FROM uniform_resource_cgm_file_metadata WHERE file_format IS NULL OR file_format = ''
        UNION ALL
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'file_upload_date' AS column_name, file_upload_date AS value, rowid FROM uniform_resource_cgm_file_metadata WHERE file_upload_date IS NULL OR file_upload_date = ''
        UNION ALL
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'data_start_date' AS column_name, data_start_date AS value, rowid FROM uniform_resource_cgm_file_metadata WHERE data_start_date IS NULL OR data_start_date = ''
        UNION ALL
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'data_end_date' AS column_name, data_end_date AS value, rowid FROM uniform_resource_cgm_file_metadata WHERE data_end_date IS NULL OR data_end_date = ''
        UNION ALL
        SELECT 'uniform_resource_cgm_file_metadata' AS table_name, 'study_id' AS column_name, study_id AS value, rowid FROM uniform_resource_cgm_file_metadata WHERE study_id IS NULL OR study_id = ''
    )
GROUP BY
    table_name,
    column_name;

-- Log Empty Cell errors into the orchestration_session_issue table.
INSERT
OR IGNORE INTO orchestration_session_issue (
    orchestration_session_issue_id,
    session_id,
    session_entry_id,
    issue_type,
    issue_message,
    issue_row,
    issue_column,
    invalid_value,
    remediation,
    elaboration
)
SELECT
    -- Generate a unique UUID for the issue ID
    lower(
        hex (randomblob (4)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (6))
    ) AS orchestration_session_issue_id,
    tsi.orchestration_session_id,
    tsi.orchestration_session_entry_id,
    dice.heading AS issue_type,
    dice.status AS issue_message,
    dice.issue_row,
    dice.column_name AS issue_column,
    NULL AS invalid_value,
    dice.remediation,
    NULL AS elaboration
FROM
    DataIntegrityEmptyCells dice
    JOIN temp_session_info tsi ON 1 = 1;


-- Log CRITICAL Validation Errors (V&V checks from the top CTE) into the orchestration_session_issue table.
INSERT
OR IGNORE INTO orchestration_session_issue (
    orchestration_session_issue_id,
    session_id,
    session_entry_id,
    issue_type,
    issue_message,
    issue_row,
    issue_column,
    invalid_value,
    remediation,
    elaboration
)
SELECT
    -- Generate a unique UUID for the issue ID
    lower(
        hex (randomblob (4)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (6))
    ) AS orchestration_session_issue_id,
    tsi.orchestration_session_id,
    tsi.orchestration_session_entry_id,
    tve.error_type AS issue_type, -- The specific critical error type (e.g., CGM_META_FIELD_MISSING)
    tve.error_detail AS issue_message, -- Detailed error message
    tve.patient_id AS issue_row, -- Using patient_id as a pseudo row identifier
    tve.table_name AS issue_column, -- Table where the error occurred
    tve.file_name AS invalid_value, -- File name associated with the error
    'Critical error: Data ingestion pipeline will halt. Please fix required metadata fields in the specified table/file.' AS remediation,
    'Severity: ' || tve.severity || ' for file: ' || tve.file_name
FROM
    temp_ValidationErrors tve
    JOIN temp_session_info tsi ON 1 = 1;


-- Create or Replace Temp Empty Tables View
-- Identifies tables that should contain data (based on the expected schema list) but are completely empty.
DROP VIEW IF EXISTS empty_tables;
CREATE TEMP VIEW empty_tables AS
SELECT
    'Data Integrity Checks: Empty Tables' AS heading,
    e.table_name,
    e.table_name AS issue_column,
    'The table ' || e.table_name || ' is empty' AS status,
    'Please provide data for the table ' || e.table_name AS remediation
FROM
    (
        -- Get a distinct list of all expected table names
        SELECT DISTINCT table_name
        FROM expected_schema_view
    ) e
    LEFT JOIN (
        -- Count rows in all existing uniform_resource tables
        SELECT
            m.name AS table_name,
            COUNT(p.name) AS column_count,
            (SELECT COUNT(rowid) FROM pragma_table_info(m.name)) AS row_count
        FROM
            sqlite_master m
            JOIN pragma_table_info (m.name) p
        WHERE
            m.type = 'table'
            AND m.name LIKE 'uniform_resource_%'
        GROUP BY
            m.name
    ) a ON e.table_name = a.table_name
WHERE
    a.row_count IS NULL OR a.row_count = 0; -- Filter for tables that are either non-existent or have 0 rows

-- Log Empty Table errors into the orchestration_session_issue table.
INSERT
OR IGNORE INTO orchestration_session_issue (
    orchestration_session_issue_id,
    session_id,
    session_entry_id,
    issue_type,
    issue_message,
    issue_row,
    issue_column,
    invalid_value,
    remediation,
    elaboration
)
SELECT
    -- Generate a unique UUID for the issue ID
    lower(
        hex (randomblob (4)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (2)) || '-' || hex (randomblob (6))
    ) AS orchestration_session_issue_id,
    tsi.orchestration_session_id,
    tsi.orchestration_session_entry_id,
    ed.heading AS issue_type,
    ed.status AS issue_message,
    NULL AS issue_row,
    NULL AS issue_column,
    NULL AS invalid_value,
    ed.remediation,
    NULL AS elaboration
FROM
    empty_tables ed
    JOIN temp_session_info tsi ON 1 = 1;

-- Update orchestration_session to set finished timestamp and diagnostics
-- This marks the V&V session as complete in the audit log.
UPDATE orchestration_session
SET
    orch_finished_at = CURRENT_TIMESTAMP, -- Set the finish time
    diagnostics_json = '{"status": "completed"}', -- Diagnostics status in JSON format
    diagnostics_md = 'Verification Validation process completed' -- Markdown summary
WHERE
    orchestration_session_id = (
        SELECT
            orchestration_session_id
        FROM
            temp_session_info
        LIMIT
            1
    );


-----------------------------------------------------------------------------
-- ***************************************************************
-- SECTION 4: REPORTING VIEWS
-- Views for querying and reporting the results of the processes.
-- ***************************************************************

-- Drops and creates a view to display a summary of issues logged during the 
-- Verification & Validation (V&V) orchestration process for easy user reporting.
DROP VIEW IF EXISTS drh_vandv_orch_issues;
CREATE VIEW
    drh_vandv_orch_issues AS
SELECT
    osi.issue_type as 'Issue Type',
    osi.issue_message as 'Issue Message',
    osi.issue_column as 'Issue column',
    osi.remediation,
    osi.issue_row as 'Issue Row',
    osi.invalid_value
FROM
    orchestration_session_issue osi
    JOIN orchestration_session os ON osi.session_id = os.orchestration_session_id
WHERE
    os.orchestration_nature_id = 'V&V';


-- ***************************************************************
-- SECTION 4: PIPELINE HALT CHECK
-- This MUST be the final select statement. It returns all critical
-- errors logged to the persistent table for the current session.
-- A non-empty result halts the pipeline.
-- ***************************************************************

-- SELECT 
--      * from drh_vandv_orch_issues;