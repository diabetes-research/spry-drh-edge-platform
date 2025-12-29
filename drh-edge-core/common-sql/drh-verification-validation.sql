-- =====================================================================
-- PURE SQLITE PRE-ETL VALIDATOR (STRICT SEQUENTIAL PHASE 1)
-- =====================================================================

-- 0. PERSISTENCE & STAGING
CREATE TABLE IF NOT EXISTS validation_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT, 
    timestamp TEXT DEFAULT CURRENT_TIMESTAMP,
    folder_name TEXT,
    tenant_id TEXT,
    tenant_name TEXT,
    overall_status TEXT NOT NULL,
    report_json TEXT 
);

DROP TABLE IF EXISTS stage_files;
CREATE TABLE stage_files AS
SELECT 
    entry.file_basename,
    res.size_bytes,
    entry.file_extn,
    entry.file_path_rel,
    CAST(res.content AS TEXT) AS full_content,
    LOWER(TRIM(SUBSTR(CAST(res.content AS TEXT), 1, 
        CASE WHEN INSTR(CAST(res.content AS TEXT), CHAR(10)) > 0 THEN INSTR(CAST(res.content AS TEXT), CHAR(10)) - 1
             ELSE LENGTH(CAST(res.content AS TEXT)) END
    ))) AS actual_header_row
FROM ur_ingest_session_fs_path_entry entry
JOIN uniform_resource res ON entry.uniform_resource_id = res.uniform_resource_id;

-- 1. DIAGNOSTICS TABLE
DROP TABLE IF EXISTS diagnostics;
CREATE TABLE diagnostics (check_id INTEGER, check_name TEXT, status TEXT, details TEXT);

-- ---------------------------------------------------------------------
-- STEP 1: Folder Name & Resource Count Check
-- ---------------------------------------------------------------------
INSERT INTO diagnostics (check_id, check_name, status, details)
SELECT 1, 'Folder & Resource Check',
    CASE WHEN (SELECT COUNT(*) FROM stage_files) > 0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN (SELECT COUNT(*) FROM stage_files) > 0 
         THEN 'Resources identified: ' || (SELECT CASE WHEN INSTR(file_path_rel, '/') > 0 THEN SUBSTR(file_path_rel, 1, INSTR(file_path_rel, '/') - 1) ELSE 'root' END FROM stage_files LIMIT 1)
         ELSE 'No records found in uniform_resource. Ingestion failed.' END;

-- ---------------------------------------------------------------------
-- STEP 2: File Extension and Existence Check
-- ---------------------------------------------------------------------
INSERT INTO diagnostics (check_id, check_name, status, details)
SELECT 2, 'Extension & Existence',
    CASE 
        WHEN (SELECT status FROM diagnostics WHERE check_id = 1) = 'FAIL' THEN 'FAIL'
        WHEN EXISTS (SELECT 1 FROM stage_files WHERE file_extn != 'csv') THEN 'FAIL'
        WHEN NOT EXISTS (SELECT 1 FROM stage_files WHERE file_basename = 'participant.csv') THEN 'FAIL'
        WHEN NOT EXISTS (SELECT 1 FROM stage_files WHERE file_basename = 'cgm_file_metadata.csv') THEN 'FAIL'
        ELSE 'PASS'
    END,
    CASE 
        WHEN (SELECT status FROM diagnostics WHERE check_id = 1) = 'FAIL' THEN 'Skipped due to previous failure.'
        ELSE 'Ensuring all files are .csv and mandatory files exist.' 
    END;

-- ---------------------------------------------------------------------
-- STEP 3: File Schema Check (Header Validation)
-- ---------------------------------------------------------------------

DROP VIEW IF EXISTS schema_dna;
CREATE VIEW schema_dna AS
SELECT 
    REPLACE(tbl, 'uniform_resource_', '') || '.csv' AS file_basename,
    column_name,
    is_mandatory
FROM (
    -- Include your provided view logic here
    -- institution
    SELECT 'uniform_resource_institution' AS tbl, 'institution_id' AS column_name, 1 AS is_mandatory UNION ALL
    SELECT 'uniform_resource_institution', 'institution_name', 1 UNION ALL
    SELECT 'uniform_resource_institution', 'city', 1 UNION ALL
    SELECT 'uniform_resource_institution', 'state', 1 UNION ALL
    SELECT 'uniform_resource_institution', 'country', 1 UNION ALL
    -- lab
    SELECT 'uniform_resource_lab', 'lab_id', 1 UNION ALL
    SELECT 'uniform_resource_lab', 'lab_name', 1 UNION ALL
    SELECT 'uniform_resource_lab', 'lab_pi', 1 UNION ALL
    SELECT 'uniform_resource_lab', 'institution_id', 1 UNION ALL
    SELECT 'uniform_resource_lab', 'study_id', 1 UNION ALL
    -- study
    SELECT 'uniform_resource_study', 'study_id', 1 UNION ALL
    SELECT 'uniform_resource_study', 'study_name', 1 UNION ALL
    SELECT 'uniform_resource_study', 'start_date', 1 UNION ALL
    SELECT 'uniform_resource_study', 'end_date', 1 UNION ALL
    SELECT 'uniform_resource_study', 'treatment_modalities', 1 UNION ALL
    SELECT 'uniform_resource_study', 'funding_source', 1 UNION ALL
    SELECT 'uniform_resource_study', 'nct_number', 1 UNION ALL
    SELECT 'uniform_resource_study', 'study_description', 1 UNION ALL
    -- participant
    SELECT 'uniform_resource_participant', 'participant_id', 1 UNION ALL
    SELECT 'uniform_resource_participant', 'study_id', 1 UNION ALL
    SELECT 'uniform_resource_participant', 'site_id', 1 UNION ALL
    SELECT 'uniform_resource_participant', 'diagnosis_icd', 1 UNION ALL
    SELECT 'uniform_resource_participant', 'med_rxnorm', 1 UNION ALL
    SELECT 'uniform_resource_participant', 'treatment_modality', 0 UNION ALL
    SELECT 'uniform_resource_participant', 'gender', 1 UNION ALL
    SELECT 'uniform_resource_participant', 'race_ethnicity', 0 UNION ALL
    SELECT 'uniform_resource_participant', 'age', 1 UNION ALL
    SELECT 'uniform_resource_participant', 'bmi', 1 UNION ALL
    SELECT 'uniform_resource_participant', 'baseline_hba1c',1 UNION ALL
    SELECT 'uniform_resource_participant', 'diabetes_type', 1 UNION ALL
    SELECT 'uniform_resource_participant', 'study_arm', 1 UNION ALL
    --site
    SELECT 'uniform_resource_site', 'site_id', 1 UNION ALL
    SELECT 'uniform_resource_site', 'study_id', 1 UNION ALL
    SELECT 'uniform_resource_site', 'site_name', 1 UNION ALL
    SELECT 'uniform_resource_site', 'site_type', 1 UNION ALL    
    -- investigator table
    SELECT 'uniform_resource_investigator', 'investigator_id',  1 UNION ALL
    SELECT 'uniform_resource_investigator', 'investigator_name',  1 UNION ALL
    SELECT 'uniform_resource_investigator', 'email',  1 UNION ALL
    SELECT 'uniform_resource_investigator', 'institution_id',  1 UNION ALL
    SELECT 'uniform_resource_investigator', 'study_id',  1 UNION ALL
    -- publication table
    SELECT 'uniform_resource_publication', 'publication_id', 1 UNION ALL
    SELECT 'uniform_resource_publication', 'publication_title', 1 UNION ALL
    SELECT 'uniform_resource_publication', 'digital_object_identifier', 0 UNION ALL
    SELECT 'uniform_resource_publication', 'publication_site',  0 UNION ALL
    SELECT 'uniform_resource_publication', 'study_id',  1 UNION ALL
    -- author table
    SELECT 'uniform_resource_author', 'author_id',  1  UNION ALL
    SELECT 'uniform_resource_author', 'name',  1 UNION ALL
    SELECT 'uniform_resource_author', 'email',  1 UNION ALL
    SELECT 'uniform_resource_author', 'investigator_id',  1 UNION ALL
    SELECT 'uniform_resource_author', 'study_id',  1 UNION ALL
    -- cgm file metadata
    SELECT 'uniform_resource_cgm_file_metadata', 'metadata_id', 1 UNION ALL
    SELECT 'uniform_resource_cgm_file_metadata', 'devicename', 1 UNION ALL
    SELECT 'uniform_resource_cgm_file_metadata', 'device_id', 1 UNION ALL
    SELECT 'uniform_resource_cgm_file_metadata', 'source_platform', 1 UNION ALL
    SELECT 'uniform_resource_cgm_file_metadata', 'patient_id', 1 UNION ALL
    SELECT 'uniform_resource_cgm_file_metadata', 'file_name', 1 UNION ALL
    SELECT 'uniform_resource_cgm_file_metadata', 'file_format', 1 UNION ALL
    SELECT 'uniform_resource_cgm_file_metadata', 'file_upload_date',  1 UNION ALL
    SELECT 'uniform_resource_cgm_file_metadata', 'data_start_date',  1 UNION ALL
    SELECT 'uniform_resource_cgm_file_metadata', 'data_end_date',  1 UNION ALL    
    SELECT 'uniform_resource_cgm_file_metadata', 'map_field_of_cgm_date', 1 UNION ALL
    SELECT 'uniform_resource_cgm_file_metadata', 'map_field_of_cgm_value', 1 UNION ALL
    SELECT 'uniform_resource_cgm_file_metadata', 'study_id', 1 UNION ALL
    -- (Add other tables like meal_file_metadata as needed)
-- Optional: Meal (Your Schema)
    SELECT 'uniform_resource_meal_file_metadata', 'meal_meta_id', 1 UNION ALL
    SELECT 'uniform_resource_meal_file_metadata', 'participant_id', 1 UNION ALL
    SELECT 'uniform_resource_meal_file_metadata', 'file_name', 1 UNION ALL
    -- Optional: Fitness (Your Schema)
    SELECT 'uniform_resource_fitness_file_metadata', 'fitness_meta_id', 1 UNION ALL
    SELECT 'uniform_resource_fitness_file_metadata', 'participant_id', 1 UNION ALL
    SELECT 'uniform_resource_fitness_file_metadata', 'file_name', 1
);

-- ---------------------------------------------------------------------
-- STEP 3: Granular File Schema Check (Grouped by File)
-- ---------------------------------------------------------------------
INSERT INTO diagnostics (check_id, check_name, status, details)
SELECT 
    3, 
    'Header Check: ' || dna.file_basename,
    CASE 
        -- Waterfall: If Step 2 failed, this fails
        WHEN (SELECT status FROM diagnostics WHERE check_id = 2 AND status = 'FAIL' LIMIT 1) IS NOT NULL THEN 'FAIL'
        -- If file is missing entirely
        WHEN s.file_basename IS NULL THEN 'FAIL'
        -- If any mandatory column is missing (checks the concatenated list of results)
        WHEN GROUP_CONCAT(CASE WHEN (',' || s.actual_header_row || ',') NOT LIKE '%,' || dna.column_name || ',%' THEN 'MISSING' ELSE 'OK' END) LIKE '%MISSING%' THEN 'FAIL'
        ELSE 'PASS'
    END,
    CASE 
        WHEN (SELECT status FROM diagnostics WHERE check_id = 2 AND status = 'FAIL' LIMIT 1) IS NOT NULL THEN 'Skipped due to previous failure'
        WHEN s.file_basename IS NULL THEN 'File not found in folder'
        ELSE 'Status: ' || GROUP_CONCAT(
            dna.column_name || CASE WHEN (',' || s.actual_header_row || ',') LIKE '%,' || dna.column_name || ',%' THEN ': OK' ELSE ': MISSING' END, 
            ' | '
        )
    END
FROM schema_dna dna
LEFT JOIN stage_files s ON dna.file_basename = s.file_basename
WHERE dna.is_mandatory = 1
GROUP BY dna.file_basename;

-- ---------------------------------------------------------------------
-- STEP 4: CGM Metadata Integrity (Normalization Fixed)
-- ---------------------------------------------------------------------

-- Check 4a: Verify every file mentioned in metadata exists physically
INSERT INTO diagnostics (check_id, check_name, status, details)
SELECT 
    4,
    'Metadata Link: ' || s.file_basename,
    CASE 
        WHEN (SELECT status FROM diagnostics WHERE check_id = 3 AND status = 'FAIL' LIMIT 1) IS NOT NULL THEN 'FAIL'
        WHEN s.size_bytes > 0 THEN 'PASS'
        ELSE 'FAIL'
    END,
    CASE 
        WHEN (SELECT status FROM diagnostics WHERE check_id = 3 AND status = 'FAIL' LIMIT 1) IS NOT NULL THEN 'Skipped'
        WHEN s.size_bytes > 0 THEN 'Metadata record matches file (Normalized hyphen/underscore check)'
        ELSE 'File mentioned in metadata but is empty or missing.'
    END
FROM stage_files s
WHERE s.file_basename LIKE 'cgm_tracing_%'
AND (
    -- Normalizing metadata content: Hyphens (-) become Underscores (_) for comparison
    SELECT REPLACE(full_content, '-', '_') 
    FROM stage_files 
    WHERE file_basename = 'cgm_file_metadata.csv'
) LIKE '%' || s.file_basename || '%';

-- Check 4b: Check for "Orphan" files (Files in folder but NOT in metadata)
INSERT INTO diagnostics (check_id, check_name, status, details)
SELECT 
    4,
    'Unregistered File: ' || s.file_basename,
    'FAIL',
    'Tracing file ' || s.file_basename || ' found in folder but NOT listed in cgm_file_metadata.csv'
FROM stage_files s
WHERE s.file_basename LIKE 'cgm_tracing_%'
AND (
    -- Normalizing metadata content for the 'NOT LIKE' check
    SELECT REPLACE(full_content, '-', '_') 
    FROM stage_files 
    WHERE file_basename = 'cgm_file_metadata.csv'
) NOT LIKE '%' || s.file_basename || '%'
AND (SELECT status FROM diagnostics WHERE check_id = 3 AND status = 'FAIL' LIMIT 1) IS NULL;

-- ---------------------------------------------------------------------
-- STEP 5: Meal Metadata Check (Conditional)
-- ---------------------------------------------------------------------
INSERT INTO diagnostics (check_id, check_name, status, details)
SELECT 5, 'Meal Metadata Check',
    CASE 
        WHEN (SELECT status FROM diagnostics WHERE check_id = 4) = 'FAIL' THEN 'FAIL'
        -- Logic: If meal data files exist, meal metadata MUST exist
        WHEN EXISTS (SELECT 1 FROM stage_files WHERE file_basename LIKE 'meal_%' AND file_basename != 'meal_file_metadata.csv')
             AND NOT EXISTS (SELECT 1 FROM stage_files WHERE file_basename = 'meal_file_metadata.csv') THEN 'FAIL'
        ELSE 'PASS'
    END,
    CASE 
        WHEN (SELECT status FROM diagnostics WHERE check_id = 4) = 'FAIL' THEN 'Skipped due to previous failure.'
        WHEN NOT EXISTS (SELECT 1 FROM stage_files WHERE file_basename LIKE 'meal_%') THEN 'No meal data found; skipping validation.'
        ELSE 'Meal data detected; metadata validated.' 
    END;

-- ---------------------------------------------------------------------
-- STEP 6: Fitness Metadata Check (Conditional)
-- ---------------------------------------------------------------------
INSERT INTO diagnostics (check_id, check_name, status, details)
SELECT 6, 'Fitness Metadata Check',
    CASE 
        WHEN (SELECT status FROM diagnostics WHERE check_id = 5) = 'FAIL' THEN 'FAIL'
        -- Logic: If fitness data files exist, fitness metadata MUST exist
        WHEN EXISTS (SELECT 1 FROM stage_files WHERE file_basename LIKE 'fitness_%' AND file_basename != 'fitness_file_metadata.csv')
             AND NOT EXISTS (SELECT 1 FROM stage_files WHERE file_basename = 'fitness_file_metadata.csv') THEN 'FAIL'
        ELSE 'PASS'
    END,
    CASE 
        WHEN (SELECT status FROM diagnostics WHERE check_id = 5) = 'FAIL' THEN 'Skipped due to previous failure.'
        WHEN NOT EXISTS (SELECT 1 FROM stage_files WHERE file_basename LIKE 'fitness_%') THEN 'No fitness data found; skipping validation.'
        ELSE 'Fitness data detected; metadata validated.' 
    END;

-- ---------------------------------------------------------------------
-- 4. FINAL JSON REPORT
-- ---------------------------------------------------------------------
INSERT INTO validation_reports (folder_name, tenant_id, tenant_name, overall_status, report_json)
SELECT 
    (SELECT CASE WHEN INSTR(file_path_rel, '/') > 0 THEN SUBSTR(file_path_rel, 1, INSTR(file_path_rel, '/') - 1) ELSE 'root' END FROM stage_files LIMIT 1),
    p.party_id, p.party_name,
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM diagnostics WHERE status = 'FAIL') THEN 'FAIL' ELSE 'PASS' END),
    json_object(
        'timestamp', CURRENT_TIMESTAMP,
        'overallStatus', (SELECT CASE WHEN EXISTS (SELECT 1 FROM diagnostics WHERE status = 'FAIL') THEN 'FAIL' ELSE 'PASS' END),
        'results', (SELECT json_group_array(json_object('check', check_name, 'status', status, 'details', details)) FROM (SELECT * FROM diagnostics ORDER BY check_id))
    )
FROM party p LIMIT 1;