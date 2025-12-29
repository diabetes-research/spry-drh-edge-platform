-- =====================================================================
-- PURE DUCKDB SQL ETL: AUTOMATED PRE-VALIDATION
-- =====================================================================

---------------------------------------
-- 0. SETUP & PERSISTENCE
---------------------------------------
INSTALL json;
LOAD json;
INSTALL sqlite;
load sqlite;

-- 0. Ensure the SQLite DB is attached (if not already done in your session)
ATTACH 'resource-surveillance.sqlite.db' AS base (TYPE SQLITE);

CREATE TABLE IF NOT EXISTS base.validation_reports (
    id INTEGER PRIMARY KEY , 
    timestamp TEXT DEFAULT CURRENT_TIMESTAMP,
    folder_name TEXT,
    tenant_id TEXT,
    tenant_name TEXT,
    overall_status TEXT NOT NULL,
    report_json TEXT 
);

-- 1. Drop existing staging table in the persistent SQLite store
DROP TABLE IF EXISTS base.stage_files;

-- 2. Recreate using DuckDB optimized string logic
CREATE TABLE base.stage_files AS
SELECT 
    entry.file_basename,
    res.size_bytes,
    entry.file_extn,
    entry.file_path_rel,
    entry.file_path_rel_parent,
    CAST(res.content AS TEXT) AS full_content,
    -- DuckDB logic: Split by newline and take the first element [1]
    LOWER(TRIM(
        STR_SPLIT(CAST(res.content AS TEXT), E'\n')[1]
    )) AS actual_header_row
FROM base.ur_ingest_session_fs_path_entry entry
JOIN base.uniform_resource res ON entry.uniform_resource_id = res.uniform_resource_id;



-- 1. DIAGNOSTICS TABLE
DROP TABLE IF EXISTS base.diagnostics;
CREATE TABLE base.diagnostics (check_id INTEGER, check_name TEXT, status TEXT, details TEXT);


DROP TABLE IF EXISTS base.schema_dna;
CREATE TABLE base.schema_dna AS
SELECT 
    REPLACE(tbl, 'uniform_resource_', '') || '.csv' AS file_basename,
    column_name,
    is_mandatory
FROM (
    VALUES    
    ('uniform_resource_institution' , 'institution_id', 1 ),
    ('uniform_resource_institution', 'institution_name', 1 ),
    ('uniform_resource_institution', 'city', 1 ),
    ('uniform_resource_institution', 'state', 1 ),
    ('uniform_resource_institution', 'country', 1 ),
    -- lab
    ('uniform_resource_lab', 'lab_id', 1 ),
    ('uniform_resource_lab', 'lab_name', 1 ),
    ('uniform_resource_lab', 'lab_pi', 1 ),
    ('uniform_resource_lab', 'institution_id', 1 ),
    ('uniform_resource_lab', 'study_id', 1 ),
    -- study
    ('uniform_resource_study', 'study_id', 1 ),
    ('uniform_resource_study', 'study_name', 1 ),
    ('uniform_resource_study', 'start_date', 1 ),
    ('uniform_resource_study', 'end_date', 1 ),
    ('uniform_resource_study', 'treatment_modalities', 1 ),
    ('uniform_resource_study', 'funding_source', 1 ),
    ('uniform_resource_study', 'nct_number', 1 ),
    ('uniform_resource_study', 'study_description', 1 ),
    -- participant
    ('uniform_resource_participant', 'participant_id', 1 ),
    ('uniform_resource_participant', 'study_id', 1 ),
    ('uniform_resource_participant', 'site_id', 1 ),
    ('uniform_resource_participant', 'diagnosis_icd', 1 ),
    ('uniform_resource_participant', 'med_rxnorm', 1 ),
    ('uniform_resource_participant', 'treatment_modality', 0 ),
    ('uniform_resource_participant', 'gender', 1 ),
    ('uniform_resource_participant', 'race_ethnicity', 0 ),
    ('uniform_resource_participant', 'age', 1 ),
    ('uniform_resource_participant', 'bmi', 1 ),
    ('uniform_resource_participant', 'baseline_hba1c',1 ),
    ('uniform_resource_participant', 'diabetes_type', 1 ),
    ('uniform_resource_participant', 'study_arm', 1 ),
    --site
    ('uniform_resource_site', 'site_id', 1 ),
    ('uniform_resource_site', 'study_id', 1 ),
    ('uniform_resource_site', 'site_name', 1 ),
    ('uniform_resource_site', 'site_type', 1 ),    
    -- investigator table
    ('uniform_resource_investigator', 'investigator_id',  1 ),
    ('uniform_resource_investigator', 'investigator_name',  1 ),
    ('uniform_resource_investigator', 'email',  1 ),
    ('uniform_resource_investigator', 'institution_id',  1 ),
    ('uniform_resource_investigator', 'study_id',  1 ),
    -- publication table
    ('uniform_resource_publication', 'publication_id', 1 ),
    ('uniform_resource_publication', 'publication_title', 1 ),
    ('uniform_resource_publication', 'digital_object_identifier', 0 ),
    ('uniform_resource_publication', 'publication_site',  0 ),
    ('uniform_resource_publication', 'study_id',  1 ),
    -- author table
    ('uniform_resource_author', 'author_id',  1  ),
    ('uniform_resource_author', 'name',  1 ),
    ('uniform_resource_author', 'email',  1 ),
    ('uniform_resource_author', 'investigator_id',  1 ),
    ('uniform_resource_author', 'study_id',  1 ),
    -- cgm file metadata
    ('uniform_resource_cgm_file_metadata', 'metadata_id', 1 ),
    ('uniform_resource_cgm_file_metadata', 'devicename', 1 ),
    ('uniform_resource_cgm_file_metadata', 'device_id', 1 ),
    ('uniform_resource_cgm_file_metadata', 'source_platform', 1 ),
    ('uniform_resource_cgm_file_metadata', 'patient_id', 1 ),
    ('uniform_resource_cgm_file_metadata', 'file_name', 1 ),
    ('uniform_resource_cgm_file_metadata', 'file_format', 1 ),
    ('uniform_resource_cgm_file_metadata', 'file_upload_date',  1 ),
    ('uniform_resource_cgm_file_metadata', 'data_start_date',  1 ),
    ('uniform_resource_cgm_file_metadata', 'data_end_date',  1 ),    
    ('uniform_resource_cgm_file_metadata', 'map_field_of_cgm_date', 1 ),
    ('uniform_resource_cgm_file_metadata', 'map_field_of_cgm_value', 1 ),
    ('uniform_resource_cgm_file_metadata', 'study_id', 1 ),
    -- (Add other tables like meal_file_metadata as needed)
-- Optional: Meal (Your Schema)
    ('uniform_resource_meal_file_metadata', 'meal_meta_id', 1 ),
    ('uniform_resource_meal_file_metadata', 'participant_id', 1 ),
    ('uniform_resource_meal_file_metadata', 'file_name', 1 ),
    -- Optional: Fitness (Your Schema)
    ('uniform_resource_fitness_file_metadata', 'fitness_meta_id', 1 ),
    ('uniform_resource_fitness_file_metadata', 'participant_id', 1 ),
    ('uniform_resource_fitness_file_metadata', 'file_name', 1)
) AS t(tbl, column_name, is_mandatory);


---------------------------------------------------------------------
-- 2a. DEFINE MANDATORY FILES
---------------------------------------------------------------------
DROP TABLE IF EXISTS base.mandatory_files;
CREATE TABLE base.mandatory_files AS 
SELECT * FROM (
    VALUES 
        ('participant.csv'),
        ('institution.csv'),
        ('lab.csv'),
        ('study.csv'),
        ('site.csv'),
        ('investigator.csv'),
        ('publication.csv'),
        ('author.csv'),
        ('meal_file_metadata.csv'),
        ('fitness_file_metadata.csv'),
        ('cgm_file_metadata.csv')
) AS t(file_basename);


---------------------------------------
-- GLOBAL VARIABLE: Capture Parent Folder
---------------------------------------
DROP TABLE IF EXISTS base.temp_session_vars;
CREATE TABLE base.temp_session_vars AS
WITH path_parsing AS (
    SELECT 
        file_path_rel_parent,
        string_split(REPLACE(file_path_rel_parent, '\', '/'), '/') AS parts
    FROM base.ur_ingest_session_fs_path_entry
    WHERE file_path_rel_parent IS NOT NULL
    LIMIT 1
)
SELECT 
    CASE 
        WHEN len(parts) > 0 THEN parts[-1] 
        ELSE 'Unknown' 
    END AS global_folder_name
FROM path_parsing;


---------------------------------------------------------------------
-- STEP 1: PARENT FOLDER DYNAMIC DEPTH
---------------------------------------------------------------------
INSERT INTO base.diagnostics (check_id, check_name, status, details)
WITH path_parsing AS (
    -- Use the specific parent path column
    -- and handle both / and \ just in case
    SELECT 
        file_path_rel_parent,
        string_split(REPLACE(file_path_rel_parent, '\', '/'), '/') AS parts
    FROM base.ur_ingest_session_fs_path_entry
    LIMIT 1
),
folder_extraction AS (
    SELECT 
        -- parts[-1] gets the very last segment of the path
        CASE 
            WHEN len(parts) > 0 THEN parts[-1] 
            ELSE 'Unknown' 
        END AS last_folder
    FROM path_parsing
)
SELECT
    1,
    'Folder & Resource Check',
    CASE
        WHEN (SELECT COUNT(*) FROM base.stage_files) > 0 THEN 'PASS'
        ELSE 'FAIL'
    END,
    CASE
        WHEN (SELECT COUNT(*) FROM base.stage_files) = 0
            THEN 'Error: No files detected during ingestion. This may occur if the source folder name contains spaces or unsupported characters.'
        ELSE
            'File ingestion successful. Detected ' || (SELECT COUNT(*) FROM base.stage_files) || ' files from folder: ' ||
            (SELECT last_folder FROM folder_extraction)
    END;


---------------------------------------------------------------------
-- STEP 2: CSV FORMAT & MANDATORY FILE EXISTENCE
---------------------------------------------------------------------
INSERT INTO base.diagnostics (check_id, check_name, status, details)
WITH format_check AS (
    SELECT 
        (SELECT COUNT(*) FROM base.stage_files WHERE LOWER(file_extn) != 'csv') as non_csv_count,
        (SELECT COUNT(*) FROM base.mandatory_files m 
         LEFT JOIN base.stage_files s ON s.file_basename = m.file_basename
         WHERE s.file_basename IS NULL) as missing_mandatory_count
)
SELECT 2, 'File Format & Mandatory  Files Existence',
    CASE 
        WHEN (SELECT status FROM base.diagnostics WHERE check_id = 1) = 'FAIL' THEN 'FAIL'
        WHEN non_csv_count > 0 OR missing_mandatory_count > 0 THEN 'FAIL'
        ELSE 'PASS'
    END,
    CASE 
        WHEN non_csv_count > 0 THEN 'Error: ' || non_csv_count || ' Non-CSV files detected.'
        WHEN missing_mandatory_count > 0 THEN 'Error: Missing mandatory files.'
        ELSE 'All mandatory files present and in CSV format.'
    END
FROM format_check;

---------------------------------------------------------------------
-- STEP 3: HEADER VALIDATION (With Halt Logic)
---------------------------------------------------------------------

INSERT INTO base.diagnostics (check_id, check_name, status, details)
WITH header_eval AS (
    SELECT 
        dna.file_basename,
        dna.column_name,
        CASE 
            WHEN s.actual_header_row IS NULL THEN 'MISSING_FILE'
            WHEN contains(s.actual_header_row, dna.column_name) THEN 'OK'
            ELSE 'MISSING_COL'
        END AS col_status
    FROM base.schema_dna dna
    LEFT JOIN base.stage_files s ON s.file_basename LIKE dna.file_basename || '%'
    WHERE dna.is_mandatory = 1
)
SELECT 
    3, 
    'File Schema Check: ' || file_basename,
    CASE WHEN contains(string_agg(col_status, ','), 'MISSING') THEN 'FAIL' ELSE 'PASS' END,
    string_agg(column_name || ': ' || col_status, ' | ')
FROM header_eval
WHERE NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id IN (1,2) AND status = 'FAIL')
GROUP BY file_basename;

---------------------------------------------------------------------
-- STEP 4: CGM FILE EXISTENCE (Cross-reference Metadata with Resources)
---------------------------------------------------------------------
INSERT INTO base.diagnostics (check_id, check_name, status, details)
WITH raw_meta AS (
    SELECT CAST(full_content AS TEXT) as csv_text
    FROM base.stage_files 
    WHERE file_basename LIKE 'cgm_file_metadata%'
    LIMIT 1
),
expected_files AS (
    -- Fixed: Use a CROSS JOIN to pass the string into read_csv_auto
    SELECT DISTINCT TRIM(f.file_name) as target_file
    FROM raw_meta rm, 
         read_csv_auto(rm.csv_text) f
    WHERE rm.csv_text IS NOT NULL
)
SELECT 
    4,
    'CGM Metadata File Existence Check: ' || e.target_file,
    CASE 
        WHEN EXISTS (SELECT 1 FROM base.stage_files s WHERE s.file_basename = e.target_file) THEN 'PASS'
        ELSE 'FAIL'
    END,
    CASE 
        WHEN EXISTS (SELECT 1 FROM base.stage_files s WHERE s.file_basename = e.target_file)
        THEN 'File ' || e.target_file || ' found in uniform_resource.'
        ELSE 'File ' || e.target_file || ' is MISSING based on cgm_file_metadata.'
    END
FROM expected_files e
WHERE NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id IN (1,2) AND status = 'FAIL');

---------------------------------------------------------------------
-- STEP 5: CGM COLUMN & DATA VALIDATION (Deep Content Check)
---------------------------------------------------------------------
INSERT INTO base.diagnostics (check_id, check_name, status, details)
WITH raw_meta AS (
    SELECT CAST(full_content AS TEXT) as csv_text
    FROM base.stage_files 
    WHERE file_basename LIKE 'cgm_file_metadata%'
    LIMIT 1
),
child_files AS (
    -- Fixed: Use CROSS JOIN to avoid Binder Error subquery
    SELECT DISTINCT TRIM(f.file_name) as target_file
    FROM raw_meta rm, 
         read_csv_auto(rm.csv_text) f
    WHERE target_file IN (SELECT file_basename FROM base.stage_files)
),
content_eval AS (
    SELECT 
        c.target_file,
        s.full_content,
        s.actual_header_row,
        -- Check if file is more than just a header
        (contains(s.full_content, E'\n') AND length(TRIM(s.full_content)) > length(TRIM(s.actual_header_row))) as has_data
    FROM child_files c
    JOIN base.stage_files s ON s.file_basename = c.target_file
)
SELECT 
    5,
    'CGM Tracing Data Integrity Check: ' || target_file,
    CASE WHEN has_data THEN 'PASS' ELSE 'FAIL' END,
    CASE 
        WHEN has_data THEN 'Data rows detected beyond header for ' || target_file
        ELSE 'File ' || target_file || ' contains ONLY a header or is empty.'
    END
FROM content_eval
-- WATERFALL GATE: Only run if Step 4 succeeded for ALL files
WHERE NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id = 4 AND status = 'FAIL')
  AND NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id IN (1,2) AND status = 'FAIL');

-- ---------------------------------------------------------------------
-- -- STEP 5: MEAL DATA TRAVERSAL (Check Tracing BLOBs)
-- ---------------------------------------------------------------------
-- INSERT INTO base.diagnostics (check_id, check_name, status, details)
-- WITH raw_meal_meta AS (
--     -- Get the Meal Metadata BLOB from stage_files
--     SELECT CAST(full_content AS TEXT) as csv_text
--     FROM base.stage_files 
--     WHERE file_basename LIKE 'meal_file_metadata%'
--     LIMIT 1
-- ),
-- expected_meal_files AS (
--     -- Parse the CSV text to find every file_name mentioned
--     SELECT DISTINCT TRIM(file_name) as target_file
--     FROM read_csv_auto((SELECT csv_text FROM raw_meal_meta))
-- )
-- SELECT 
--     5,
--     'Meal Data Existence: ' || e.target_file,
--     CASE 
--         WHEN EXISTS (
--             SELECT 1 FROM base.stage_files s 
--             WHERE s.file_basename = e.target_file 
--             AND s.size_bytes > 0
--         ) THEN 'PASS'
--         ELSE 'FAIL'
--     END,
--     CASE 
--         WHEN EXISTS (SELECT 1 FROM base.stage_files s WHERE s.file_basename = e.target_file)
--         THEN 'Meal Resource ' || e.target_file || ' verified in uniform_resource.'
--         ELSE 'Meal Resource ' || e.target_file || ' is MISSING from the ingestion.'
--     END
-- FROM expected_meal_files e
-- WHERE NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id IN (1,2) AND status = 'FAIL');

---------------------------------------------------------------------
-- STEP 7: FINAL BUNDLE (JSON)
---------------------------------------------------------------------
INSERT INTO base.validation_reports (folder_name, tenant_id, tenant_name, overall_status, report_json)
SELECT 
    (SELECT global_folder_name from base.temp_session_vars limit 1),
    p.party_id, p.party_name,
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM base.diagnostics WHERE status = 'FAIL') THEN 'FAIL' ELSE 'PASS' END),
    json_object(
        'timestamp', CURRENT_TIMESTAMP,
        'folderName', (SELECT global_folder_name from base.temp_session_vars limit 1),
        'tenantId', p.party_id,
        'tenantName', p.party_name,
        'overallStatus', (SELECT CASE WHEN EXISTS (SELECT 1 FROM base.diagnostics WHERE status = 'FAIL') THEN 'FAIL' ELSE 'PASS' END),
        'results', (SELECT json_group_array(json_object('check', check_name, 'status', status, 'details', details)) FROM (SELECT * FROM base.diagnostics ORDER BY check_id))
    )
FROM base.party p LIMIT 1;