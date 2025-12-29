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
DROP TABLE IF EXISTS base.session_vars;
CREATE TABLE base.session_vars AS
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
WHERE NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id IN (1,2,3) AND status = 'FAIL')
GROUP BY file_basename;

---------------------------------------------------------------------
-- STEP 4: CGM FILE EXISTENCE (Cross-referencing Metadata Content)
---------------------------------------------------------------------
INSERT INTO base.diagnostics (check_id, check_name, status, details)
WITH raw_data AS (
    -- Convert hex \x0A to standard newlines and clean Windows \r
    SELECT REPLACE(REPLACE(CAST(full_content AS TEXT), '\x0A', E'\n'), E'\r', '') as clean_txt
    FROM base.stage_files 
    WHERE file_basename LIKE 'cgm_file_metadata%'
    LIMIT 1
),
split_lines AS (
    SELECT unnest(str_split(clean_txt, E'\n')) as line FROM raw_data
),
header_discovery AS (
    SELECT list_indexof(list_transform(str_split(line, ','), x -> TRIM(x)), 'file_name') as fn_index
    FROM split_lines LIMIT 1
),
expected_files AS (
    SELECT DISTINCT 
        -- Extract name, remove quotes, append .csv if missing
        CASE 
            WHEN TRIM(REPLACE(str_split(line, ',')[fn_index], '"', '')) LIKE '%.csv' 
            THEN TRIM(REPLACE(str_split(line, ',')[fn_index], '"', ''))
            ELSE TRIM(REPLACE(str_split(line, ',')[fn_index], '"', '')) || '.csv'
        END as target_file
    FROM split_lines, header_discovery
    WHERE fn_index > 0 
      AND line NOT LIKE '%file_name%' 
      AND length(TRIM(line)) > 10
)
SELECT 
    4,
    'CGM Tracing Files Existence: ' || e.target_file,
    CASE 
        WHEN EXISTS (SELECT 1 FROM base.stage_files s WHERE s.file_basename = e.target_file) THEN 'PASS'
        ELSE 'FAIL'
    END,
    CASE 
        WHEN EXISTS (SELECT 1 FROM base.stage_files s WHERE s.file_basename = e.target_file)
        THEN 'File ' || e.target_file || ' verified in ' || (SELECT global_folder_name FROM base.session_vars)
        ELSE 'File ' || e.target_file || ' is missing from ' || (SELECT global_folder_name FROM base.session_vars) 
    END
FROM expected_files e
WHERE NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id IN (1,2,3) AND status = 'FAIL');

---------------------------------------------------------------------
-- STEP 5: CGM COLUMN & DATA VALIDATION (Robust Join Fix)
---------------------------------------------------------------------
INSERT INTO base.diagnostics (check_id, check_name, status, details)
WITH raw_data AS (
    SELECT REPLACE(REPLACE(CAST(full_content AS TEXT), '\x0A', E'\n'), E'\r', '') as clean_txt
    FROM base.stage_files WHERE file_basename LIKE 'cgm_file_metadata%' LIMIT 1
),
split_lines AS (
    SELECT unnest(str_split(clean_txt, E'\n')) as line FROM raw_data
),
header_discovery AS (
    SELECT list_indexof(list_transform(str_split(line, ','), x -> TRIM(LOWER(x))), 'file_name') as fn_index
    FROM split_lines LIMIT 1
),
child_files AS (
    SELECT DISTINCT 
        -- Extract, lowercase, and normalize hyphens to underscores for the search
        REPLACE(LOWER(TRIM(REPLACE(str_split(line, ',')[fn_index], '"', ''))), '-', '_') as search_key,
        -- Keep the original name just for the report label
        TRIM(REPLACE(str_split(line, ',')[fn_index], '"', '')) as original_name
    FROM split_lines, header_discovery
    WHERE fn_index > 0 AND line NOT LIKE '%file_name%' AND length(TRIM(line)) > 10
),
content_eval AS (
    SELECT 
        c.original_name,
        s.file_basename,
        -- Use a more resilient data check: check if a second line exists
        (len(str_split(REPLACE(CAST(s.full_content AS TEXT), '\x0A', E'\n'), E'\n')) > 1) as has_data
    FROM child_files c
    JOIN base.stage_files s ON (
        -- Match by lowercasing both and replacing hyphens on both sides
        REPLACE(REPLACE(LOWER(s.file_basename), '.csv', ''), '-', '_') = c.search_key
    )
)
SELECT 
    5,
    'CGM Data Integrity: ' || original_name,
    CASE WHEN has_data THEN 'PASS' ELSE 'FAIL' END,
    CASE 
        WHEN has_data THEN 'Data rows detected for ' || original_name
        ELSE 'File ' || original_name || ' (matched as ' || file_basename || ') is empty or missing rows.'
    END
FROM content_eval
WHERE NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id = 4 AND status = 'FAIL')
  AND NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id IN (1,2,3) AND status = 'FAIL');

---------------------------------------------------------------------
-- STEP 6: MEAL DATA VALIDATION (Existence
---------------------------------------------------------------------
INSERT INTO base.diagnostics (check_id, check_name, status, details)
WITH raw_data AS (
    -- Convert hex \x0A to standard newlines and clean Windows \r
    SELECT REPLACE(REPLACE(CAST(full_content AS TEXT), '\x0A', E'\n'), E'\r', '') as clean_txt
    FROM base.stage_files 
    WHERE file_basename LIKE 'meal_file_metadata%'
    LIMIT 1
),
split_lines AS (
    SELECT unnest(str_split(clean_txt, E'\n')) as line FROM raw_data
),
header_discovery AS (
    SELECT list_indexof(list_transform(str_split(line, ','), x -> TRIM(x)), 'file_name') as fn_index
    FROM split_lines LIMIT 1
),
expected_files AS (
    SELECT DISTINCT 
        -- Extract name, remove quotes, append .csv if missing
        CASE 
            WHEN TRIM(REPLACE(str_split(line, ',')[fn_index], '"', '')) LIKE '%.csv' 
            THEN TRIM(REPLACE(str_split(line, ',')[fn_index], '"', ''))
            ELSE TRIM(REPLACE(str_split(line, ',')[fn_index], '"', '')) || '.csv'
        END as target_file
    FROM split_lines, header_discovery
    WHERE fn_index > 0 
      AND line NOT LIKE '%file_name%' 
      AND length(TRIM(line)) > 10
)
SELECT 
    6,
    'Meal Data Files Existence: ' || e.target_file,
    CASE 
        WHEN EXISTS (SELECT 1 FROM base.stage_files s WHERE s.file_basename = e.target_file) THEN 'PASS'
        ELSE 'FAIL'
    END,
    CASE 
        WHEN EXISTS (SELECT 1 FROM base.stage_files s WHERE s.file_basename = e.target_file)
        THEN 'File ' || e.target_file || ' verified in ' || (SELECT global_folder_name FROM base.session_vars)
        ELSE 'File ' || e.target_file || ' is missing from ' || (SELECT global_folder_name FROM base.session_vars) 
    END
FROM expected_files e
WHERE NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id IN (1,2,3,4,5) AND status = 'FAIL');

---------------------------------------------------------------------
-- Meal file content valdiation 
---------------------------------------------------------------------
INSERT INTO base.diagnostics (check_id, check_name, status, details)
WITH raw_data AS (
    SELECT REPLACE(REPLACE(CAST(full_content AS TEXT), '\x0A', E'\n'), E'\r', '') as clean_txt
    FROM base.stage_files WHERE file_basename LIKE 'meal_file_metadata%' LIMIT 1
),
split_lines AS (
    SELECT unnest(str_split(clean_txt, E'\n')) as line FROM raw_data
),
header_discovery AS (
    SELECT list_indexof(list_transform(str_split(line, ','), x -> TRIM(LOWER(x))), 'file_name') as fn_index
    FROM split_lines LIMIT 1
),
child_files AS (
    SELECT DISTINCT 
        -- Extract, lowercase, and normalize hyphens to underscores for the search
        REPLACE(LOWER(TRIM(REPLACE(str_split(line, ',')[fn_index], '"', ''))), '-', '_') as search_key,
        -- Keep the original name just for the report label
        TRIM(REPLACE(str_split(line, ',')[fn_index], '"', '')) as original_name
    FROM split_lines, header_discovery
    WHERE fn_index > 0 AND line NOT LIKE '%file_name%' AND length(TRIM(line)) > 10
),
content_eval AS (
    SELECT 
        c.original_name,
        s.file_basename,
        -- Use a more resilient data check: check if a second line exists
        (len(str_split(REPLACE(CAST(s.full_content AS TEXT), '\x0A', E'\n'), E'\n')) > 1) as has_data
    FROM child_files c
    JOIN base.stage_files s ON (
        -- Match by lowercasing both and replacing hyphens on both sides
        REPLACE(REPLACE(LOWER(s.file_basename), '.csv', ''), '-', '_') = c.search_key
    )
)
SELECT 
    7,
    'Meal Data Integrity: ' || original_name,
    CASE WHEN has_data THEN 'PASS' ELSE 'FAIL' END,
    CASE 
        WHEN has_data THEN 'Data rows detected for ' || original_name
        ELSE 'File ' || original_name || ' (matched as ' || file_basename || ') is empty or missing rows.'
    END
FROM content_eval
WHERE NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id = 4 AND status = 'FAIL')
  AND NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id IN (1,2,3) AND status = 'FAIL');



---------------------------------------------------------------------
-- FITNESS DATA VALIDATION (Existence)
---------------------------------------------------------------------
INSERT INTO base.diagnostics (check_id, check_name, status, details)
WITH raw_data AS (
    -- Convert hex \x0A to standard newlines and clean Windows \r
    SELECT REPLACE(REPLACE(CAST(full_content AS TEXT), '\x0A', E'\n'), E'\r', '') as clean_txt
    FROM base.stage_files 
    WHERE file_basename LIKE 'fitness_file_metadata%'
    LIMIT 1
),
split_lines AS (
    SELECT unnest(str_split(clean_txt, E'\n')) as line FROM raw_data
),
header_discovery AS (
    SELECT list_indexof(list_transform(str_split(line, ','), x -> TRIM(x)), 'file_name') as fn_index
    FROM split_lines LIMIT 1
),
expected_files AS (
    SELECT DISTINCT 
        -- Extract name, remove quotes, append .csv if missing
        CASE 
            WHEN TRIM(REPLACE(str_split(line, ',')[fn_index], '"', '')) LIKE '%.csv' 
            THEN TRIM(REPLACE(str_split(line, ',')[fn_index], '"', ''))
            ELSE TRIM(REPLACE(str_split(line, ',')[fn_index], '"', '')) || '.csv'
        END as target_file
    FROM split_lines, header_discovery
    WHERE fn_index > 0 
      AND line NOT LIKE '%file_name%' 
      AND length(TRIM(line)) > 10
)
SELECT 
    8,
    'Fitness Data Files Existence: ' || e.target_file,
    CASE 
        WHEN EXISTS (SELECT 1 FROM base.stage_files s WHERE s.file_basename = e.target_file) THEN 'PASS'
        ELSE 'FAIL'
    END,
    CASE 
        WHEN EXISTS (SELECT 1 FROM base.stage_files s WHERE s.file_basename = e.target_file)
        THEN 'File ' || e.target_file || ' verified in ' || (SELECT global_folder_name FROM base.session_vars)
        ELSE 'File ' || e.target_file || ' is missing from ' || (SELECT global_folder_name FROM base.session_vars) 
    END
FROM expected_files e
WHERE NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id IN (1,2,3,4,5,6,7) AND status = 'FAIL');

---------------------------------------------------------------------
-- Fitness file content valdiation 
---------------------------------------------------------------------
INSERT INTO base.diagnostics (check_id, check_name, status, details)
WITH raw_data AS (
    SELECT REPLACE(REPLACE(CAST(full_content AS TEXT), '\x0A', E'\n'), E'\r', '') as clean_txt
    FROM base.stage_files WHERE file_basename LIKE 'fitness_file_metadata%' LIMIT 1
),
split_lines AS (
    SELECT unnest(str_split(clean_txt, E'\n')) as line FROM raw_data
),
header_discovery AS (
    SELECT list_indexof(list_transform(str_split(line, ','), x -> TRIM(LOWER(x))), 'file_name') as fn_index
    FROM split_lines LIMIT 1
),
child_files AS (
    SELECT DISTINCT 
        -- Extract, lowercase, and normalize hyphens to underscores for the search
        REPLACE(LOWER(TRIM(REPLACE(str_split(line, ',')[fn_index], '"', ''))), '-', '_') as search_key,
        -- Keep the original name just for the report label
        TRIM(REPLACE(str_split(line, ',')[fn_index], '"', '')) as original_name
    FROM split_lines, header_discovery
    WHERE fn_index > 0 AND line NOT LIKE '%file_name%' AND length(TRIM(line)) > 10
),
content_eval AS (
    SELECT 
        c.original_name,
        s.file_basename,
        -- Use a more resilient data check: check if a second line exists
        (len(str_split(REPLACE(CAST(s.full_content AS TEXT), '\x0A', E'\n'), E'\n')) > 1) as has_data
    FROM child_files c
    JOIN base.stage_files s ON (
        -- Match by lowercasing both and replacing hyphens on both sides
        REPLACE(REPLACE(LOWER(s.file_basename), '.csv', ''), '-', '_') = c.search_key
    )
)
SELECT 
    9,
    'Fitness Data Integrity: ' || original_name,
    CASE WHEN has_data THEN 'PASS' ELSE 'FAIL' END,
    CASE 
        WHEN has_data THEN 'Data rows detected for ' || original_name
        ELSE 'File ' || original_name || ' (matched as ' || file_basename || ') is empty or missing rows.'
    END
FROM content_eval
WHERE NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id = 4 AND status = 'FAIL')
  AND NOT EXISTS (SELECT 1 FROM base.diagnostics WHERE check_id IN (1,2,3,4,5,6,7) AND status = 'FAIL');

---------------------------------------------------------------------
-- FINAL BUNDLE (JSON)
---------------------------------------------------------------------
INSERT INTO base.validation_reports (folder_name, tenant_id, tenant_name, overall_status, report_json)
SELECT 
    (SELECT global_folder_name from base.session_vars limit 1),
    p.party_id, p.party_name,
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM base.diagnostics WHERE status = 'FAIL') THEN 'FAIL' ELSE 'PASS' END),
    json_object(
        'timestamp', CURRENT_TIMESTAMP,
        'folderName', (SELECT global_folder_name from base.session_vars limit 1),
        'tenantId', p.party_id,
        'tenantName', p.party_name,
        'overallStatus', (SELECT CASE WHEN EXISTS (SELECT 1 FROM base.diagnostics WHERE status = 'FAIL') THEN 'FAIL' ELSE 'PASS' END),
        'results', (SELECT json_group_array(json_object('check', check_name, 'status', status, 'details', details)) FROM (SELECT * FROM base.diagnostics ORDER BY check_id))
    )
FROM base.party p LIMIT 1;