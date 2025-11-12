-- ***************************************************************
-- SECTION 1: DE-IDENTIFICATION PROCESS
-- This section performs email anonymization and logs the process.
-- ***************************************************************

-- Anonymize email addresses in the uniform_resource_investigator table
UPDATE uniform_resource_investigator
SET
    email = surveilr_anonymize_email (email)
WHERE
    email IS NOT NULL;

-- Anonymize email addresses in the uniform_resource_author table
UPDATE uniform_resource_author
SET
    email = surveilr_anonymize_email (email)
WHERE
    email IS NOT NULL;

CREATE TEMP VIEW IF NOT EXISTS device_info AS
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
    device_info d
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
    d.device_id, -- Pull device_id from the device_info view
    'deidentification', -- Reference to the orchestration_nature_id we just inserted
    '', -- Version (placeholder)
    CURRENT_TIMESTAMP, -- Start time
    NULL, -- Finished time (to be updated later)
    NULL, -- Elaboration (if any)
    NULL, -- Args JSON (if any)
    NULL, -- Diagnostics JSON (if any)
    NULL -- Diagnostics MD (if any)
FROM
    device_info d
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
        'drh-data-quality-prepare.sql', -- Replace with actual ingest source
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

-- Insert into orchestration_session_exec for uniform_resource_investigator
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
    'UPDATE uniform_resource_investigator SET email = surveilr_anonymize_email(email) executed', -- Description of the executed code
    'SUCCESS', -- Execution status
    'email column in uniform_resource_investigator', -- Input text reference
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




-- ***************************************************************
-- SECTION 1: CREATING RELATIONAL VIEWS (T)
-- ***************************************************************

-- VIEW 1: drh_participant
-- Drops and recreates the view for participant information, adding a 'tenant_id'
-- (taken from the 'party' table) for multi-tenancy support.
DROP VIEW IF EXISTS drh_participant;
CREATE VIEW drh_participant AS
SELECT
    p.participant_id,
    p.study_id,
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
    p.study_arm,
    party.party_id AS tenant_id
FROM uniform_resource_participant p
CROSS JOIN (SELECT party_id FROM party LIMIT 1) party;

-- Create participant table if not exists (This syntax is SQLite compatible)
-- Creates a persistent 'participant' table by materializing the data from drh_participant view.
-- This might be used for downstream processing or performance.
CREATE TABLE IF NOT EXISTS participant AS
SELECT * FROM drh_participant;

-- VIEW 2: drh_study
-- Drops and recreates the view for study-related metadata, adding a 'tenant_id'.
DROP VIEW IF EXISTS drh_study;
CREATE VIEW drh_study AS
SELECT 
    s.study_id,
    s.study_name,
    s.start_date,
    s.end_date,
    s.treatment_modalities,
    s.funding_source,
    s.nct_number,
    s.study_description,
    party.party_id AS tenant_id
FROM uniform_resource_study s
CROSS JOIN (SELECT party_id FROM party LIMIT 1) party;

-- VIEW 3: drh_cgmfilemetadata_view
-- Drops and recreates the view for Continuous Glucose Monitor (CGM) file metadata,
-- linking it to a study ID (from the first study found) and adding 'tenant_id'.
DROP VIEW IF EXISTS drh_cgmfilemetadata_view;
CREATE VIEW drh_cgmfilemetadata_view AS
SELECT 
    m.metadata_id,
    m.devicename,
    m.device_id,
    m.source_platform,
    m.patient_id,
    m.file_name,
    m.file_format,
    m.file_upload_date,
    m.data_start_date,
    m.data_end_date,
    s.study_id,
    party.party_id AS tenant_id
FROM uniform_resource_cgm_file_metadata m
CROSS JOIN (SELECT study_id FROM uniform_resource_study LIMIT 1) s
CROSS JOIN (SELECT party_id FROM party LIMIT 1) party;

-- VIEW 4: drh_author
-- Drops and recreates the view for publication author information, linking it
-- to a study ID and adding 'tenant_id'.
DROP VIEW IF EXISTS drh_author;
CREATE VIEW drh_author AS
SELECT 
    a.author_id,
    a.name,
    a.email,
    a.investigator_id,
    s.study_id,
    party.party_id AS tenant_id
FROM uniform_resource_author a
CROSS JOIN (SELECT study_id FROM uniform_resource_study LIMIT 1) s
CROSS JOIN (SELECT party_id FROM party LIMIT 1) party;

-- VIEW 5: drh_institution
-- Drops and recreates the view for institution information, adding 'tenant_id'.
DROP VIEW IF EXISTS drh_institution;
CREATE VIEW drh_institution AS
SELECT 
    i.institution_id,
    i.institution_name,
    i.city,
    i.state,
    i.country,
    party.party_id AS tenant_id
FROM uniform_resource_institution i
CROSS JOIN (SELECT party_id FROM party LIMIT 1) party;

-- VIEW 6: drh_investigator
-- Drops and recreates the view for investigator information, linking it
-- to a study ID and adding 'tenant_id'.
DROP VIEW IF EXISTS drh_investigator;
CREATE VIEW drh_investigator AS
SELECT 
    inv.investigator_id,
    inv.investigator_name,
    inv.email,
    inv.institution_id,
    s.study_id,
    party.party_id AS tenant_id
FROM uniform_resource_investigator inv
CROSS JOIN (SELECT study_id FROM uniform_resource_study LIMIT 1) s
CROSS JOIN (SELECT party_id FROM party LIMIT 1) party;

-- VIEW 7: drh_lab
-- Drops and recreates the view for lab information, linking it to a study ID
-- and adding 'tenant_id'.
DROP VIEW IF EXISTS drh_lab;
CREATE VIEW drh_lab AS
SELECT 
    l.lab_id,
    l.lab_name,
    l.lab_pi,
    l.institution_id,
    s.study_id,
    party.party_id AS tenant_id
FROM uniform_resource_lab l
CROSS JOIN (SELECT study_id FROM uniform_resource_study LIMIT 1) s
CROSS JOIN (SELECT party_id FROM party LIMIT 1) party;

-- VIEW 8: drh_publication
-- Drops and recreates the view for publication information, linking it to a study ID
-- and adding 'tenant_id'.
DROP VIEW IF EXISTS drh_publication;
CREATE VIEW drh_publication AS
SELECT 
    p.publication_id,
    p.publication_title,
    p.digital_object_identifier,
    p.publication_site,
    s.study_id,
    party.party_id AS tenant_id
FROM uniform_resource_publication p
CROSS JOIN (SELECT study_id FROM uniform_resource_study LIMIT 1) s
CROSS JOIN (SELECT party_id FROM party LIMIT 1) party;

-- VIEW 9: drh_site
-- Drops and recreates the view for study site information, linking it to a study ID
-- and adding 'tenant_id'.
DROP VIEW IF EXISTS drh_site;
CREATE VIEW drh_site AS
SELECT 
    s.study_id,
    site.site_id,
    site.site_name,
    site.site_type,
    party.party_id AS tenant_id
FROM uniform_resource_site site
CROSS JOIN (SELECT study_id FROM uniform_resource_study LIMIT 1) s
CROSS JOIN (SELECT party_id FROM party LIMIT 1) party;

-- VIEW 10: drh_participant_file_names
-- Drops and recreates the view to aggregate all file names associated with each patient_id
-- using SQLite's GROUP_CONCAT function.
DROP VIEW IF EXISTS drh_participant_file_names;
CREATE VIEW drh_participant_file_names AS
SELECT
    patient_id,
    -- Converted STRING_AGG to GROUP_CONCAT
    GROUP_CONCAT(file_name, ', ') AS file_names
FROM uniform_resource_cgm_file_metadata
GROUP BY patient_id;

-- Drops and recreates the view for device information.
DROP VIEW IF EXISTS drh_device;
CREATE VIEW drh_device AS
SELECT
    device_id,
    name,
    created_at
FROM
    device d;

-- Drop and recreate the number_of_files_converted view
-- Calculates the total count of converted files (those with a non-placeholder content_digest).
DROP VIEW IF EXISTS drh_number_of_files_converted;
CREATE VIEW drh_number_of_files_converted AS
SELECT
    COUNT(*) AS file_count
FROM
    uniform_resource
WHERE
    content_digest != '-';

-- Drop and recreate the converted_files_list view
-- Lists the base names of files that were ingested and converted (based on file extensions).
DROP VIEW IF EXISTS drh_converted_files_list;
CREATE VIEW drh_converted_files_list AS
SELECT
    file_basename
FROM
    ur_ingest_session_fs_path_entry
WHERE
    file_extn IN ('csv', 'xls', 'xlsx', 'json', 'html');

-- Drop and recreate the converted_table_list view
-- Lists all tables in the database that are part of the 'uniform_resource' schema,
-- excluding temporary/utility tables. Uses SQLite's sqlite_master table.
DROP VIEW IF EXISTS drh_converted_table_list;
CREATE VIEW drh_converted_table_list AS
SELECT
    tbl_name AS table_name
FROM
    sqlite_master
WHERE
    type = 'table'
    AND name LIKE 'uniform_resource%'
    AND name != 'uniform_resource_transform'
    AND name != 'uniform_resource';

-- VIEW 11: drh_study_vanity_metrics_details
-- Drops and recreates the view to calculate key high-level (vanity) metrics per study,
-- such as participant count, average age, female percentage, and a list of investigators.

DROP VIEW IF EXISTS drh_study_vanity_metrics_details;

CREATE VIEW
    drh_study_vanity_metrics_details AS
SELECT
    (
        select
            party_id
        from
            party
        limit
            1
    ) as tenant_id,
    s.study_id,
    s.study_name,
    s.study_description,
    s.start_date,
    s.end_date,
    s.nct_number,
    COUNT(DISTINCT p.participant_id) AS total_number_of_participants,
    ROUND(AVG(p.age), 2) AS average_age,
    (
        CAST(
            SUM(
                CASE
                    WHEN p.gender = 'F' THEN 1
                    ELSE 0
                END
            ) AS FLOAT
        ) / COUNT(*)
    ) * 100 AS percentage_of_females,
    GROUP_CONCAT (DISTINCT i.investigator_name) AS investigators
FROM
    uniform_resource_study s
    LEFT JOIN drh_participant p ON s.study_id = p.study_id
    LEFT JOIN uniform_resource_investigator i ON s.study_id = i.study_id
GROUP BY
    s.study_id,
    s.study_name,
    s.study_description,
    s.start_date,
    s.end_date,
    s.nct_number;

-- VIEW 12: drh_device_file_count_view
-- Drops and recreates the view to count the number of distinct files per device name
-- used for CGM data, ordered descending by file count.
DROP VIEW IF EXISTS drh_device_file_count_view;
CREATE VIEW drh_device_file_count_view AS
SELECT 
    devicename, 
    COUNT(DISTINCT file_name) AS number_of_files
FROM uniform_resource_cgm_file_metadata
GROUP BY 
    devicename
ORDER BY 
    number_of_files DESC;



-- Drops and recreates the view to list all raw CGM data tables.
-- It queries sqlite_master for tables matching the 'uniform_resource_cgm_tracing%' pattern.
DROP VIEW IF EXISTS drh_raw_cgm_table_lst;

CREATE VIEW
    drh_raw_cgm_table_lst AS
SELECT
    name,
    tbl_name as table_name
FROM
    sqlite_master
WHERE
    type = 'table'
    AND name LIKE 'uniform_resource_cgm_tracing%';

-- Drops and recreates the view to count the total number of raw CGM data tables.
DROP VIEW IF EXISTS drh_number_cgm_count;

CREATE VIEW
    drh_number_cgm_count AS
SELECT
    count(*) as number_of_cgm_raw_files
FROM
    sqlite_master
WHERE
    type = 'table'
    AND name LIKE 'uniform_resource_cgm_tracing%';

-- Drops and recreates the view to list all non-transformed 'uniform_resource' tables.
-- This is used to identify tables derived from ingested files.
DROP VIEW IF EXISTS study_wise_csv_file_names;

CREATE VIEW
    study_wise_csv_file_names AS
SELECT
    name
FROM
    sqlite_master
WHERE
    type = 'table'
    AND name LIKE 'uniform_resource_%'
    AND name != 'uniform_resource_transform';

-- Drops and recreates the view to count the total number of raw CGM data tables (duplicate of drh_number_cgm_count).
DROP VIEW IF EXISTS study_wise_number_cgm_raw_files_count;

CREATE VIEW
    study_wise_number_cgm_raw_files_count AS
SELECT
    count(*) as number_of_cgm_raw_files
FROM
    sqlite_master
WHERE
    type = 'table'
    AND name LIKE 'uniform_resource_cgm_tracing%';


-- Drops and creates a permanent table to cache the list of raw CGM tables.
-- Materializes the data from drh_raw_cgm_table_lst view.
DROP TABLE IF EXISTS raw_cgm_lst_cached;

CREATE TABLE
    raw_cgm_lst_cached AS
SELECT
    *
FROM
    drh_raw_cgm_table_lst;

-- Drops and creates a view to join uniform resource metadata with ingestion path entry details
-- to derive the file format and corresponding table name. Uses string manipulation functions (SUBSTR, INSTR).
DROP VIEW IF EXISTS drh_study_files_table_info;

CREATE VIEW
    IF NOT EXISTS drh_study_files_table_info AS
SELECT
    ur.uniform_resource_id,
    ur.nature AS file_format,
    SUBSTR (
        pe.file_path_rel,
        INSTR (pe.file_path_rel, '/') + 1,
        INSTR (pe.file_path_rel, '.') - INSTR (pe.file_path_rel, '/') - 1
    ) as file_name,
    'uniform_resource_' || SUBSTR (
        pe.file_path_rel,
        INSTR (pe.file_path_rel, '/') + 1,
        INSTR (pe.file_path_rel, '.') - INSTR (pe.file_path_rel, '/') - 1
    ) AS table_name
FROM
    uniform_resource ur
    LEFT JOIN uniform_resource_edge ure ON ur.uniform_resource_id = ure.uniform_resource_id
    AND ure.nature = 'ingest_fs_path'
    LEFT JOIN ur_ingest_session_fs_path p ON ure.node_id = p.ur_ingest_session_fs_path_id
    LEFT JOIN ur_ingest_session_fs_path_entry pe ON ur.uniform_resource_id = pe.uniform_resource_id;



-- Drops and recreates the view to count the number of distinct files per device name (duplicate of VIEW 12).
DROP VIEW IF EXISTS drh_device_file_count_view;

CREATE VIEW
    drh_device_file_count_view AS
SELECT
    devicename,
    COUNT(DISTINCT file_name) AS number_of_files
FROM
    uniform_resource_cgm_file_metadata
GROUP BY
    devicename
ORDER BY
    number_of_files DESC;



-------------Dynamically insert the sqlpages for CGM raw tables--------------------------
-- Inserts a dynamic SQLPage file entry for each raw CGM table listed in drh_raw_cgm_table_lst.
-- This generates a self-contained SQL file for display/pagination of each raw table in a web interface.
WITH
    raw_cgm_table_name AS (
        -- Select all table names to iterate over
        SELECT
            table_name
        FROM
            drh_raw_cgm_table_lst
    )
-- INSERT OR IGNORE the dynamically generated file content into sqlpage_files
INSERT OR IGNORE INTO sqlpage_files (path, contents)
SELECT    
    'drh/cgm-data/raw-cgm/' || table_name || '.sql' AS path,    
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
       ''/static/formula-component.js'' AS javascript_module
       ;
   
    SELECT ''title'' AS component, 
       REPLACE(REPLACE(''' ||table_name ||''', ''uniform_resource_'', ''''), ''.sql'', '''') 
        AS contents;
    
    
    SET total_rows = (SELECT COUNT(*) FROM ''' || table_name || ''');
    SET limit = COALESCE($limit, 50);
    SET offset = COALESCE($offset, 0);
    SET total_pages = ($total_rows + $limit - 1) / $limit;
    SET current_page = ($offset / $limit) + 1;

    
    SELECT ''table'' AS component,
        TRUE AS sort,
        TRUE AS search;
    SELECT * FROM ''' || table_name || '''
    LIMIT $limit
    OFFSET $offset; 

    -- 4. Generate Pagination Links
    SELECT ''text'' AS component,
        (SELECT CASE WHEN $current_page > 1 THEN ''[Previous](?limit='' || $limit || ''&offset='' || ($offset - $limit) || '')'' ELSE '''' END) || '' '' ||
        ''(__Page '' || $current_page || '' of '' || $total_pages || ''__)'' || '' '' ||
        (SELECT CASE WHEN $current_page < $total_pages THEN ''[Next](?limit='' || $limit || ''&offset='' || ($offset + $limit) || '')'' ELSE '''' END)
        AS contents_md;
    '
FROM
    raw_cgm_table_name;