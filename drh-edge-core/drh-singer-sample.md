---
sqlpage-conf:
  database_url: ${env.SPRY_DB}
  web_root: "./dev-src.auto"
  allow_exec: true
  port: ${env.PORT}
---

# Diabetes Research Hub (DRH) SQLPage Application

This script automates the conversion of raw diabetes research data (e.g.,
CSV, Parquet, or a private data warehouse export) into a structured SQLite database.

- Uses Spry to manage tasks and generate the SQLPage presentation layer.
- surveilr tool performs csv files conversation and transformation to RSSD
- Uses DuckDB for data transformation.(file meta ingest data,meal fitness data(if present),combined CGM data)
- Export back to sqlite db to be used in SQLpage

## Spry Axiom Configuration

```code DEFAULTS
sql * --interpolate --injectable
```

## Setup

## Environment variables and .envrc

This project reads configuration from environment variables. All variables listed below must be set in your `.envrc` file for the pipeline to run.

### Pipeline & Study Configuration (Required for `prepare-db-deploy-server ` task)

These variables link your study data to the ETL process:

- **`STUDY_DATA_PATH`**: The path to the folder containing your raw study files (e.g., `raw-data/synthetic data`). This is the **input folder** for the ingestion process.
- **`TENANT_ID`**: A unique, short identifier for your study or tenant (e.g., `FLCG`). Used for metadata tracking.
- **`TENANT_NAME`**: The full, human-readable name for your study or organization (e.g., `"Florida Clinical Group"`).

### Core Tool Configuration

- **`SPRY_DB`**: The database connection URL used by SQLPage and Spry. Example value used here:
    `sqlite://resource-surveillance.sqlite.db?mode=rwc`

  - Scheme: `sqlite://` followed by a path (relative or absolute) to the SQLite file.
  - Query `mode=rwc` tells SQLite/DuckDB to open the file for read/write and create it if missing.
  - If you prefer a path under a `data/` directory, set e.g. `sqlite://./data/resource-surveillance.sqlite.db?mode=rwc`.

- **`PORT`**: The TCP port the local SQLPage server or other local web component should listen on (example: `9227`).

Recommended practice is to keep these values in a local, directory-scoped environment file. If you use direnv (recommended), create a file named `.envrc` in this directory.

POSIX-style example (bash/zsh):

```envrc prepare-env -C ./.envrc --gitignore -X  --descr "Generate .envrc file and add it to local .gitignore if it's not already there"
export SPRY_DB="sqlite://resource-surveillance.sqlite.db?mode=rwc"
export PORT=9227
export STUDY_DATA_PATH="raw-data/dexcom-synthetic-cgm/"
export TENANT_ID="DSG"
export TENANT_NAME="DSG"
```

Then run `direnv allow` in this project directory to load the `.envrc` into your shell environment. direnv will evaluate `.envrc` only after you explicitly allow it.

-----

## Security and repository hygiene

- Never commit secrets or production credentials into `.envrc`. Treat `.envrc` like a local-only file.
- Add `.envrc` to your local `.gitignore` if you keep secrets there. Alternatively commit a `.envrc.example` or `.envrc.sample` with safe, non-secret defaults to document expected variables.
- The SQLite file (e.g. `resource-surveillance.sqlite.db`) is a binary database file — you will usually not check this into version control. Add that filename or the `data/` directory to `.gitignore` as well.

Why these variables matter here

- The YAML header at the top of this `drh-simplera-spry.md` reads `database_url: ${env.SPRY_DB}` and `port: ${env.PORT}` — Spry and the SQLPage tooling will substitute those environment values when building or serving the site.
- The `prepare-db-deploy-server ` task explicitly checks for `STUDY_DATA_PATH`, `TENANT_ID`, and `TENANT_NAME` and will halt if any are missing.
- If `SPRY_DB` is not set, the tooling may fail to find the database or fall back to defaults; explicitly setting it ensures predictable, repeatable dev runs.

Quick troubleshooting

- If the server does not start on the expected port, verify `echo $PORT` (or `echo $SPRY_DB`) in your shell to confirm values are loaded.
- If direnv appears not to load `.envrc`, re-run `direnv allow` and ensure your shell config contains the direnv hook.

### Instructions

### Prepare Study Data and Dependencies

- Prepare your research data files according to the formats described on the **official DRH Website**: [https://drh.diabetestechnology.org/organize-cgm-data](https://drh.diabetestechnology.org/organize-cgm-data).
- Ensure your study data files are placed in the directory specified by **`$STUDY_DATA_PATH`**.
- Install the required tools and dependencies:
  - **deno** (latest)
  - **surveilr** (latest release): [https://github.com/surveilr/packages/releases](https://github.com/surveilr/packages/releases)
  - **DuckDB**: Used by `surveilr` for complex in-memory ETL and data transformation.
  - **SQLite3**: The final destination database engine used for persistence and serving data via SQLPage (the file path is specified by `$SPRY_DB`).

- Place the study data files in a **directory** in the same path as this markdown, then run the following command:
  - `spry rb task prepare-db-deploy-server  drh-simplera-spry.md`
- The `prepare-db-deploy-server` task, requires the **`$STUDY_DATA_PATH`**, **`${TENANT_ID}`**, and **`${TENANT_NAME}`** as parameters which are provided through env.
- This step cleans up old files, validates data ,performs a pre-etl-validation , performs ingestion, and runs all complex DuckDB transformations, generating the final resource-surveillance.sqlite.db file.

```bash prepare-db-deploy-server   --descr "Performs pre-etl-validation , Ingestion, ETL and Server Deployment"
#!/bin/bash
set -u
# 1. Cleanup
rm -f resource-surveillance.sqlite.db 
rm -rf dev-src.auto 
# 2. Execute Dataset specific Singer Tap
surveilr ingest files -r singer-tap/tap-dexcom.surveilr\[singer]\.py 
# 3. EXTRACT VIEWS FROM TAP OUTPUT
surveilr shell common-sql/drh-data-extraction.sql  
RAW_STATUS=$(surveilr shell "select overall_status from drh_vv_session_summary DESC LIMIT 1;")
VALIDATION_STATUS=$(echo "$RAW_STATUS" | jq -r '.[0].overall_status')
# 4. CONDITIONAL ETL EXECUTION
if [ "$VALIDATION_STATUS" == "PASS" ]; then    
    (
        set -e   
        surveilr shell common-sql/drh-data-etl.sql        
    )
    
    if [ $? -ne 0 ]; then        
        exit 1
    fi
else
    echo "Validation FAILED ($VALIDATION_STATUS). Skipping ETL steps."    
fi
# 5. INITIALIZE SQLPAGE (Runs in both PASS and FAIL scenarios)
# This allows the UI to show either the 'Launch' or 'Error' buttons based on your SQL queries
spry sp spc --package --conf sqlpage/sqlpage.json -m drh-singer-sample.md | sqlite3 resource-surveillance.sqlite.db
```

```bash  clean --graph special --silent --descr "Clean up the project directory's generated artifacts"
rm -rf dev-src.auto
rm -f *.sql   
```

## Layout

This cell instructs Spry to automatically inject the SQL `PARTIAL` into all
SQLPage content cells. The name `global-layout.sql` is not significant (it's
required by Spry but only used for reference), but the `--inject **/*` argument
is how matching occurs. The `--BEGIN` and `--END` comments are not required by
Spry but make it easier to trace where _partial_ injections are occurring.

```sql PARTIAL global-layout.sql --inject *.sql --inject drh/*.sql

-- BEGIN: PARTIAL global-layout.sql
SELECT 'shell' AS component,
       'Diabetes Research Hub Edge' AS title,
       NULL AS icon,
       'https://drh.diabetestechnology.org/_astro/favicon.CcrFY5y9.ico' AS favicon,
       'https://drh.diabetestechnology.org/images/diabetic-research-hub-logo.png' AS image,
       'fluid' AS layout,
       true AS fixed_top_menu,
       '/' AS link,
       '{"link":"/","title":"Home"}' AS menu_item,
       'https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/highlight.min.js' AS javascript,
       'https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/languages/sql.min.js' AS javascript,
       'https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/languages/handlebars.min.js' AS javascript,
       'https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/languages/json.min.js' AS javascript,
        'https://app.devl.drh.diabetestechnology.org/js/d3-aide.js' AS javascript,
        '/d3-aide-component.js' AS javascript,  
        '{"link":"https://drh.diabetestechnology.org/","title":"DRH Home","target": "__blank"}' AS menu_item, 
        '{"link":"https://www.diabetestechnology.org/index.shtml","title":"DTS Home","target": "__blank"}' AS menu_item,         
       '/js/wc/d3/stacked-bar-chart.js' AS javascript_module,
       '/js/wc/d3/gri-chart.js' AS javascript_module,
       '/js/wc/d3/dgp-chart.js' AS javascript_module,
       '/js/wc/d3/agp-chart.js' AS javascript_module,
       '/js/wc/formula-component.js' AS javascript_module
       ;

SET resource_json = sqlpage.read_file_as_text('spry.d/auto/resource/${path}.auto.json');
SET page_title  = json_extract($resource_json, '$.route.caption');
SET page_description  = json_extract($resource_json, '$.route.description');
SET page_path = json_extract($resource_json, '$.route.path');
${ctx.breadcrumbs()}
-- END: PARTIAL global-layout.sql
-- this is the `${cell.info}` cell on line ${cell.startLine}
```

```sql PARTIAL api-head.sql --inject drh/api/**
-- BEGIN: PARTIAL api-head.sql
select
   'http_header' as component,
   'application/json' as "Content-Type";
-- END: PARTIAL api-head.sql
```

```sql PARTIAL chart-head.sql --inject drh/chart/**
-- BEGIN: PARTIAL chart-head.sql
-- END: PARTIAL chart-head.sql
```

```contribute sqlpage_files --base sqlpage/templates --mode package
**/* templates --mime text/plain
```

```contribute sqlpage_files --base https://app.devl.drh.diabetestechnology.org/
https://app.devl.drh.diabetestechnology.org/js/d3-aide.js .
https://app.devl.drh.diabetestechnology.org/js/wc/d3/stacked-bar-chart.js .
https://app.devl.drh.diabetestechnology.org/js/wc/d3/gri-chart.js .
https://app.devl.drh.diabetestechnology.org/js/wc/d3/dgp-chart.js .
https://app.devl.drh.diabetestechnology.org/js/wc/d3/agp-chart.js .
https://app.devl.drh.diabetestechnology.org/js/wc/formula-component.js .
https://app.devl.drh.diabetestechnology.org/js/wc/assets/axis-D3QohQNI.js .
https://app.devl.drh.diabetestechnology.org/js/wc/assets/line-Co2p4suz.js .
https://app.devl.drh.diabetestechnology.org/js/wc/assets/lit-element-CA3xe_EJ.js .
https://app.devl.drh.diabetestechnology.org/js/wc/assets/state-DQ3nVIzR.js .
https://app.devl.drh.diabetestechnology.org/js/wc/assets/transform-CPUYrfNj.js .
https://app.devl.drh.diabetestechnology.org/js/wc/assets/custom-W6OohYNa.js .
https://app.devl.drh.diabetestechnology.org/js/wc/assets/band-B4BH55T4.js .
```

```contribute sqlpage_files --base .
./d3-aide-component.js .
```

## DRH EDGE  Home Page

Index page which automatically generates links to all `/drh` pages.

```sql index.sql { route: { caption: "Home" } }
-- @route.description "Welcome to Diabetes Research Hub Edge UI."

SELECT 'html' AS component;
SELECT 
    '<div style="max-width: 800px; margin: 2rem auto; background-color: white; border: 1px solid #e9ecef; border-left: 6px solid ' || 
        CASE overall_status WHEN 'PASS' THEN '#2fb344' WHEN 'WARNING' THEN '#f76707' ELSE '#d63939' END || 
    '; padding: 2rem; border-radius: 12px; display: flex; align-items: center; justify-content: space-between; box-shadow: 0 10px 15px -3px rgba(0,0,0,0.1);">' ||
        '<div>' ||
            '<span style="display: inline-block; padding: 4px 12px; border-radius: 20px; font-size: 0.75rem; font-weight: bold; margin-bottom: 10px; background: #f1f3f5; color: #495057; text-transform: uppercase;">System Health</span>' ||
            '<div style="font-size: 1.25rem; font-weight: 600; color: #1d273b;">' ||
                CASE overall_status
                    WHEN 'PASS'    THEN 'Validation Successful'
                    WHEN 'WARNING' THEN 'Attention Required'
                    ELSE 'Action Needed'
                END || 
            '</div>' ||
            '<div style="color: #64748b; margin-top: 4px;">' ||
                CASE overall_status
                    WHEN 'PASS'    THEN 'Your ' || service_name || ' data is clean and ready for transformation.'
                    WHEN 'WARNING' THEN 'Data passed but found minor schema inconsistencies.'
                    ELSE 'Please correct your folder and files and try again. Check the diagnostic report for specific error details.'
                END || 
            '</div>' ||
        '</div>' ||
        '<div style="font-size: 2.5rem;">' ||
             CASE overall_status WHEN 'PASS' THEN '🛡️' WHEN 'WARNING' THEN '⚠️' ELSE '🚨' END || 
        '</div>' ||
    '</div>' AS html
FROM drh_vv_session_summary;

-- 4. ACTION CENTER (Product-style Buttons)
SELECT 'button' AS component, 'center' AS justify;

-- 1. PRIMARY SUCCESS ACTION
-- Only shows if the status is PASS
SELECT 
    'Launch Data Dashboard' AS title,
    '/drh/research-dashboard.sql' AS link,
    'circle-chevrons-right' AS icon,
    'teal' AS color
FROM drh_vv_session_summary 
WHERE overall_status = 'PASS' LIMIT 1;

-- 2. PRIMARY ERROR ACTION
-- Only shows if the status is NOT PASS
SELECT 
    'Review Error Details' AS title,
    '/drh/diagnostics-report.sql' AS link,
    'alert-circle' AS icon,
    'red' AS color
FROM drh_vv_session_summary 
WHERE overall_status <> 'PASS' 
LIMIT 1;

-- 3. SECONDARY DIAGNOSTICS ACTION (The "Avoid Duplication" fix)
-- We only show this if status is PASS. 
-- If status is FAIL, the red button above covers this navigation.
SELECT 
    'Explore Diagnostics' AS title,
    '/drh/diagnostics-report.sql' AS link,
    'database-search' AS icon,
    'azure' AS color,
    'outline' AS variant
FROM drh_vv_session_summary 
WHERE overall_status = 'PASS' 
LIMIT 1;

Select 'divider' as component;

-- 2. CORE UTILITY SECTION (Horizontal Product Features)
SELECT 'card' as component, 3 as columns;

SELECT 
    'Study Management' as title,
    'Centralized collection of various research studies.' as description,
    'microscope' as icon,
    'azure' as color;

SELECT 
    'Data Diagnostics' as title,
    'Real-time validation against clinical schemas.' as description,
    'shield-check' as icon,
    'teal' as color;

SELECT 
    'Orchestration' as title,
    'Seamless transformation of CSV to research-ready data.' as description,
    'adjustments' as icon,
    'indigo' as color;


Select 'divider' as component;

-- 1. HERO SECTION: The Product "Hook"
SELECT 
    'hero' as component,
    'Diabetes Research Hub' as title,
    'The Edge UI for Centralized CGM Data Management' as subtitle,
    'The DRH platform empowers researchers to harmonize, validate, and analyze continuous glucose monitor data with clinical precision.' as description,
    'https://images.unsplash.com/photo-1576091160550-2173dba999ef?auto=format&fit=crop&w=1000&q=80' as image,
    'teal' as color;

```

## Diagnostics Report

```sql drh/diagnostics-report.sql { route: { caption: "Diagnostics Report" } }
-- @route.description "Observability Diagnostics - Trace & Metrics View"

select 
    'card'                     as component,    
    2                          as columns; 

-- 2. SUMMARY SECTION (Side-by-Side)
-- Card 1: The "Hero" Status
SELECT 
    CASE overall_status WHEN 'PASS' THEN 'System Healthy' ELSE 'Action Required' END as title,
    CASE overall_status WHEN 'PASS' THEN 'teal' ELSE 'red' END as color,
    CASE overall_status WHEN 'PASS' THEN 'circle-check' ELSE 'alert-triangle' END as icon,
    'Service: ' || service_name || ' | Status: ' || overall_status as description
FROM drh_vv_session_summary;

-- Card 2: KPI Grid
SELECT 
    'Execution Metrics' as title,
    'datagrid' as component;
SELECT 'Duration' as title, duration as description, 'clock' as icon FROM drh_vv_session_summary;
SELECT 'Passed' as title, pass_count as description, 'check' as icon, 'teal' as color FROM drh_vv_session_summary;
SELECT 'Critical' as title, fail_count as description, 'x' as icon, 'red' as color FROM drh_vv_session_summary;

SELECT 'card' AS component, 2 AS columns;
-- LEFT PANEL: The Trace List
SELECT 
    'list' AS component,
    'Evidence Trace' AS title;
SELECT 
    CASE WHEN lvl = 3 THEN '　↳ ' || span_name ELSE span_name END AS title,
    evidence AS description,
    CASE WHEN status <> 'OK' THEN 'red' WHEN lvl = 2 THEN 'azure' ELSE 'teal' END AS color,
    CASE WHEN status <> 'OK' THEN 'alert-circle' ELSE 'circle-check' END AS icon,
    status as link_text
FROM drh_vv_hierarchy
WHERE lvl > 1
ORDER BY start_time_unix_nano ASC;

```

## Research Dashboard

```sql drh/research-dashboard.sql{ route: { caption: "Research Data Dashboard" } }
-- @route.description "Research Data Dashboard"

-- 1. BRANDING HERO
SELECT 'hero' AS component, 
    'Research Data Dashboard' AS title, 
    'Precision analytics platform for synchronized glycemic, nutritional, and metabolic activity research.' AS description,
    'teal' AS color;

-- 2. STUDY PROFILE SECTION

SELECT 'datagrid' AS component;
SELECT 'Study Name' AS title, study_name AS description FROM drh_study_vanity_metrics_details;


SELECT 'datagrid' AS component;
SELECT 'NCT ID' AS title, nct_number AS description FROM drh_study_vanity_metrics_details;
SELECT 'Clinical Investigators' AS title, investigators AS description FROM drh_study_vanity_metrics_details;
SELECT 'Timeline' AS title, start_date || ' to ' || end_date AS description FROM drh_study_vanity_metrics_details;

-- Long description in a dedicated text area

SELECT 'datagrid' AS component;
SELECT 'Study Description' AS title, study_description AS description FROM drh_study_vanity_metrics_details;

-- 4. DYNAMIC STUDY SNAPSHOT
SELECT 'big_number' AS component, 4 AS columns;
SELECT 'Participants' AS title, (SELECT total_number_of_participants FROM drh_study_vanity_metrics_details) AS value, 'users' AS icon, 'teal' AS color;
SELECT 'NUmber of CGM Raw Files' AS title, (SELECT number_of_cgm_raw_files FROM drh_number_cgm_count) AS value, 'file-analytics' AS icon, 'azure' AS color;
SELECT 'Avg Age' AS title, (SELECT average_age || ' yrs' FROM drh_study_vanity_metrics_details) AS value, 'calendar-stats' AS icon, 'indigo' AS color;
SELECT 'Gender (F/M)' AS title, 
    (SELECT percentage_of_females || '% / ' || percentage_of_males || '%' FROM drh_study_vanity_metrics_details) AS value, 
    'gender-intercellular' AS icon, 'teal' AS color;

-- 5. CORE RESEARCH FEATURES (Cleaned of duplicates)
SELECT 'card' AS component, 'Research Insights & Feature Sets' AS title, 3 AS columns;

SELECT 'Study Participant Dashboard' AS title, '/drh/study-participant-dashboard.sql' AS link,
    'Access participant-specific clinical metrics: TIR, GMI, and HbA1c table.' AS description,
    'layout-dashboard' AS icon, 'teal' AS color;

SELECT 'Combined CGM Tracing' AS title, '/drh/cgm-combined-data.sql' AS link,
    'Aggregated glucose monitoring data for trend analysis across the study.' AS description,
    'chart-line' AS icon, 'teal' AS color;

SELECT 'Combined Meal Data' AS title, '/drh/combined-meal-data.sql' AS link,
    'Nutritional intake logs and post-prandial glycemic response analysis.' AS description,
    'soup' AS icon, 'teal' AS color;

SELECT 'Combined Fitness Data' AS title, '/drh/combined-fitness-data.sql' AS link,
    'Physical activity metrics: steps, heart rate, and metabolic outcomes.' AS description,
    'run' AS icon, 'teal' AS color;

SELECT 'Raw CGM Data' AS title, '/drh/cgm-data.sql' AS link,
    'Direct access to time-series glucose values and raw timestamps.' AS description,
    'device-airtag' AS icon, 'teal' AS color;

-- 6. DIAGNOSTICS & SYSTEM AUDIT
SELECT 'card' AS component, 'Data Deidentification And File Logs' AS title, 2 AS columns;

SELECT 'Ingestion Log' AS title, '/drh/ingestion-log.sql' AS link,
    'Raw Data files accepted and converted into database format.' AS description,
    'database-import' AS icon, 'cyan' AS color;

-- SELECT 'Verification Log' AS title, '/drh/verification-validation-log.sql' AS link,
--     'Quality review of file content and corrective actions taken.' AS description,
--     'folder-check' AS icon, 'cyan' AS color;

SELECT 'De-Identification Audit' AS title, '/drh/deidentification-log.sql' AS link,
    'Review results of PHI masking and column modifications.' AS description,
    'shield-lock' AS icon, 'cyan' AS color;

-- 7. SUPPORTING METADATA (Combined and point-to-point accurate)
SELECT 'card' AS component, 'Supporting Metadata' AS title, 4 AS columns;

SELECT 'Participant Demographics' AS title, '/drh/participant-related-data.sql' AS link, 
    'Detailed breakdown of age, gender, ethnicity, and cohort background.' AS description, 
    'user-circle' AS icon, 'teal' AS color;

SELECT 'CGM Metadata' AS title, '/drh/cgm-associated-data.sql' AS link,
    'Device specs and metadata mapping.' AS description, 'settings' AS icon, 'teal' AS color;

SELECT 'Researchers & Partners' AS title, '/drh/researcher-related-data.sql' AS link, 
    'Institutional affiliations and laboratory investigators.' AS description, 
    'building-community' AS icon, 'teal' AS color;

SELECT 'Research Sites' AS title, '/drh/study-related-data.sql' AS link, 
    'Clinical site locations and facility-specific metadata.' AS description, 
    'map-pin' AS icon, 'teal' AS color;

SELECT 'Authors & Publications' AS title, '/drh/author-pub-data.sql' AS link, 
    'Scientific dissemination, manuscripts, and author affiliations.' AS description, 
    'news' AS icon, 'teal' AS color;
```

## Raw Data Files Log Page

```sql drh/ingestion-log.sql { route: { caption: "Raw Data Files Log" } }

-- @route.description "Ingestion log documenting "

-- 1. Navigation & Header
SELECT 'button' AS component, 'start' AS justify;
SELECT 
    'Back' AS title,
    '/drh/research-dashboard.sql' AS link, 
    'chevron-left' AS icon,
    'outline-secondary' AS outline;

SELECT 'text' AS component, 'Raw Data Ingestion Log' AS title;

-- 2. Refactored Output Description
-- Modified to explicitly mention the focus on CGM, Meal, and Fitness streams.
SELECT 'text' AS component, 
'The ingestion process monitors source folders for specific research data types. Each detected file is processed through a specialized Singer Tap, standardized into structured tables, and logged for auditability. 
This log specifically tracks the availability of raw data across the **CGM**, **Meal**, and **Fitness** research streams.' AS contents_md;

-- 3. Folder & File Count Summary (Based on raw research data views)
SELECT 'datagrid' AS component, 'Research Data Stream Summary' AS title;

SELECT 
    'Raw CGM File Count' AS title, 
    COUNT(*) || ' files' AS description,    
    'blue' AS color
FROM drh_raw_cgm_tracing;

SELECT 
    'Raw Meal File Count' AS title, 
    COUNT(*) || ' files' AS description,    
    'orange' AS color
FROM drh_raw_meal_data;

SELECT 
    'Raw Fitness File Count' AS title, 
    COUNT(*) || ' files' AS description,       
    'green' AS color
FROM drh_raw_fitness_data;

-- 4. Audit Table (Optional: Listing actual files logged in the tracing table)
SELECT 'table' AS component, 'Ingested Raw File Audit' AS title, TRUE AS sort, TRUE AS search;
SELECT 
    raw_file_name AS "File Name",
    'CGM' AS "Stream",
    'drh_raw_cgm_tracing' AS "Destination Table"
FROM drh_raw_cgm_tracing
UNION ALL
SELECT 
    raw_file_name,
    'Meal',
    'drh_raw_meal_data'
FROM drh_raw_meal_data
UNION ALL
SELECT 
    raw_file_name,
    'Fitness',
    'drh_raw_fitness_data'
FROM drh_raw_fitness_data;

```

## Study Participant Dashboard

```sql drh/study-participant-dashboard.sql{ route: { caption: "Study Participant Dashboard" } }
-- @route.description "The dashboard presents key study details and participant-specific metrics in a clear, organized table format"

-- Place this immediately after the shell
SELECT 'button' AS component, 'start' AS justify;

SELECT 'button' AS component, 'xs' AS size; -- Very small
SELECT 
    'Back' AS title,
    '/drh/research-dashboard.sql' AS link, 
    'chevron-left' AS icon,
    'outline-secondary' AS outline;

-- 1. CLEAN HEADER (No more duplicated study description)
SELECT 'title' AS component, 
    'Study Participant Metrics' AS contents,
    'Clinical analysis and glycemic variability indicators' AS subtitle;

-- 2. COMPACT DEVICE SNAPSHOT (Using a single row card)
SELECT 'card' AS component, 1 AS columns;
SELECT 
    'CGM Device Profile' AS title, 
    'Device Distribution: ' || GROUP_CONCAT(devicename || ' (' || number_of_files || ')') AS description,
    'device-heart-monitor' AS icon,
    'teal' AS color
FROM drh_device_file_count_view;

-- 3. KEY CLINICAL AGGREGATES (Relevant to the table below)
SELECT 'big_number' AS component, 4 AS columns;
SELECT 'Cohort Size' AS title, (SELECT total_number_of_participants FROM drh_study_vanity_metrics_details) AS value, 'teal' AS color;
SELECT 'Avg HbA1c' AS title, '7.2%' AS value, 'indigo' AS color; -- Example: Replace with actual calculation
SELECT 'Total Days Wear' AS title, (SELECT SUM(days_of_wear) FROM participant_dashboard_cached) AS value, 'azure' AS color;
SELECT 'Female/Male' AS title, (SELECT percentage_of_females || '%' FROM drh_study_vanity_metrics_details) AS value, 'teal' AS color;

-- 4. THE PARTICIPANT DATA TABLE
-- We keep the columns focused on Clinical Success (TIR, GMI, etc.)
${paginate("participant_dashboard_cached")}

SELECT 'table' AS component,
    TRUE AS sort,
    TRUE AS search,
    'participant_id' AS markdown,
    'Clinical Outcomes' AS title;

SELECT 
    ${md.link("participant_id", [`'participant-info.sql?participant_id='`, "participant_id"])} AS participant_id,
    gender, 
    age, 
    study_arm AS arm,
    baseline_hba1c AS hba1c,
    tir AS "TIR %", 
    tar AS "TAR %", 
    tbr AS "TBR %", 
    gmi AS GMI,
    percent_gv AS "CV %", 
    days_of_wear AS "Days Wear",
    data_start_date AS "Start", 
    data_end_date AS "End" 
FROM participant_dashboard_cached    
ORDER BY participant_id
${pagination.limit}; 

${pagination.navigation}
```

## Researcher and Associated Information

```sql drh/researcher-related-data.sql{ route: { caption: "Researcher and Associated Information" } }
-- @route.description "This section provides detailed information about the individuals , institutions and labs involved in the research study."

SELECT 'text' AS component, $page_title AS title;

SELECT 'button' AS component, 'start' AS justify;

SELECT 'button' AS component, 'xs' AS size; -- Very small
SELECT 
    'Back' AS title,
    '/drh/research-dashboard.sql' AS link, 
    'chevron-left' AS icon,
    'outline-secondary' AS outline;

SELECT
  'text' as component,
  'The Diabetes Research Hub collaborates with a diverse group of researchers or investigators dedicated to advancing diabetes research. This section provides detailed information about the individuals and institutions involved in the research studies.' as contents;


SELECT
  'text' as component,
  'Researcher / Investigator ' as title;
SELECT
  'These are scientific professionals and medical experts who design and conduct studies related to diabetes management and treatment. Their expertise ranges from clinical research to data analysis, and they are crucial in interpreting results and guiding future research directions.Principal investigators lead the research projects, overseeing the study design, implementation, and data collection. They ensure the research adheres to ethical standards and provides valuable insights into diabetes management.' as contents;
SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
SELECT * from drh_investigator;

SELECT
  'text' as component,
  'Institution' as title;
SELECT
  'The researchers and investigators are associated with various institutions, including universities, research institutes, and hospitals. These institutions provide the necessary resources, facilities, and support for conducting high-quality research. Each institution brings its unique strengths and expertise to the collaborative research efforts.' as contents;
SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
SELECT * from drh_institution;


SELECT
  'text' as component,
  'Lab' as title;
SELECT
  'Within these institutions, specialized labs are equipped with state-of-the-art technology to conduct diabetes research. These labs focus on different aspects of diabetes studies, such as glucose monitoring, metabolic analysis, and data processing. They play a critical role in executing experiments, analyzing samples, and generating data that drive research conclusions.' as contents;
SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
SELECT * from drh_lab;


```

## Study ResearchSite Details

```sql drh/study-related-data.sql{ route: { caption: "Study ResearchSite Details" } }
-- @route.description "This section provides detailed information about the study , and sites involved in the research study."

SELECT 'text' AS component, $page_title AS title;

SELECT 'button' AS component, 'start' AS justify;

SELECT 'button' AS component, 'xs' AS size; -- Very small
SELECT 
    'Back' AS title,
    '/drh/research-dashboard.sql' AS link, 
    'chevron-left' AS icon,
    'outline-secondary' AS outline;



    SELECT
  'text' as component,
  '
  In Continuous Glucose Monitoring (CGM) research, studies are designed to evaluate the effectiveness, accuracy, and impact of CGM systems on diabetes management. Each study aims to gather comprehensive data on glucose levels, treatment efficacy, and patient outcomes to advance our understanding of diabetes care.

  ### Study Details

  - **Study ID**: A unique identifier assigned to each study.
  - **Study Name**: The name or title of the study.
  - **Start Date**: The date when the study begins.
  - **End Date**: The date when the study concludes.
  - **Treatment Modalities**: Different treatment methods or interventions used in the study.
  - **Funding Source**: The source(s) of financial support for the study.
  - **NCT Number**: ClinicalTrials.gov identifier for the study.
  - **Study Description**: A description of the study’s objectives, methodology, and scope.

  ' as contents_md;

  SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
  SELECT * from drh_study;


      SELECT
          'text' as component,
          '

## Site Information

Research sites are locations where the studies are conducted. They include clinical settings where participants are recruited, monitored, and data is collected.

### Site Details

  - **Study ID**: A unique identifier for the study associated with the site.
  - **Site ID**: A unique identifier for each research site.
  - **Site Name**: The name of the institution or facility where the research is carried out.
  - **Site Type**: The type or category of the site (e.g., hospital, clinic).

      ' as contents_md;

      SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
      SELECT * from drh_site;

```

## Participant Demographics

```sql drh/participant-related-data.sql{ route: { caption: "Participant Demographics" } }
-- @route.description "This section provides detailed information about the the participants involved in the research study."

SELECT 'button' AS component, 'start' AS justify;

SELECT 'button' AS component, 'xs' AS size; -- Very small
SELECT 
    'Back' AS title,
    '/drh/research-dashboard.sql' AS link, 
    'chevron-left' AS icon,
    'outline-secondary' AS outline;

${paginate("drh_participant")}

  SELECT
      'text' as component,
      '
## Participant Information

Participants are individuals who volunteer to take part in CGM research studies. Their data is crucial for evaluating the performance of CGM systems and their impact on diabetes management.

### Participant Details

  - **Participant ID**: A unique identifier assigned to each participant.
  - **Study ID**: A unique identifier for the study in which the participant is involved.
  - **Site ID**: The identifier for the site where the participant is enrolled.
  - **Diagnosis ICD**: The diagnosis code based on the International Classification of Diseases (ICD) system.
  - **Med RxNorm**: The medication code based on the RxNorm system.
  - **Treatment Modality**: The type of treatment or intervention administered to the participant.
  - **Gender**: The gender of the participant.
  - **Race Ethnicity**: The race and ethnicity of the participant.
  - **Age**: The age of the participant.
  - **BMI**: The Body Mass Index (BMI) of the participant.
  - **Baseline HbA1c**: The baseline Hemoglobin A1c level of the participant.
  - **Diabetes Type**: The type of diabetes diagnosed for the participant.
  - **Study Arm**: The study arm or group to which the participant is assigned.


      ' as contents_md;

    

    -- Display uniform_resource table with pagination
    SELECT 'table' AS component,
          TRUE AS sort,
          TRUE AS search;
    SELECT * FROM drh_participant
    ${pagination.limit}; 


${pagination.navigation}
        ;


```

## Author and Publication Details

```sql drh/author-pub-data.sql{ route: { caption: "Author and Publication Details" } }
-- @route.description "Information about research publications and the authors involved in the studies are also collected, contributing to the broader understanding and dissemination of research findings."


SELECT 'button' AS component, 'start' AS justify;

SELECT 'button' AS component, 'xs' AS size; -- Very small
SELECT 
    'Back' AS title,
    '/drh/research-dashboard.sql' AS link, 
    'chevron-left' AS icon,
    'outline-secondary' AS outline;

SELECT
  'text' as component,
  '

## Authors

This section contains information about the authors involved in study publications. Each author plays a crucial role in contributing to the research, and their details are important for recognizing their contributions.

### Author Details

- **Author ID**: A unique identifier for the author.
- **Name**: The full name of the author.
- **Email**: The email address of the author.
- **Investigator ID**: A unique identifier for the investigator the author is associated with.
- **Study ID**: A unique identifier for the study associated with the author.


      ' as contents_md;

  SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
  SELECT * from drh_author;
  SELECT
  'text' as component,
  '
## Publications Overview

This section provides information about the publications resulting from a study. Publications are essential for sharing research findings with the broader scientific community.

### Publication Details

- **Publication ID**: A unique identifier for the publication.
- **Publication Title**: The title of the publication.
- **Digital Object Identifier (DOI)**: Identifier for the digital object associated with the publication.
- **Publication Site**: The site or journal where the publication was released.
- **Study ID**: A unique identifier for the study associated with the publication.


  ' as contents_md;

  SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
  SELECT * from drh_publication;

```

## CGM Meta Data and Associated information

```sql drh/cgm-associated-data.sql{ route: { caption: "CGM Meta Data and Associated information" } }
-- @route.description "This section provides detailed information about the CGM device used, the relationship between the participant''s raw CGM tracing file and related metadata, and other pertinent information."


SELECT 'button' AS component, 'start' AS justify;

SELECT 'button' AS component, 'xs' AS size; -- Very small
SELECT 
    'Back' AS title,
    '/drh/research-dashboard.sql' AS link, 
    'chevron-left' AS icon,
    'outline-secondary' AS outline;


SELECT 'text' AS component, $page_title AS title;

${paginate("drh_cgm_file_metadata")}

 SELECT
'text' as component,
'

CGM file metadata provides essential information about the Continuous Glucose Monitoring (CGM) data files used in research studies. This metadata is crucial for understanding the context and quality of the data collected.

### Metadata Details

- **Metadata ID**: A unique identifier for the metadata record.
- **Device Name**: The name of the CGM device used to collect the data.
- **Device ID**: A unique identifier for the CGM device.
- **Source Platform**: The platform or system from which the CGM data originated.
- **Patient ID**: A unique identifier for the patient from whom the data was collected.
- **File Name**: The name of the uploaded CGM data file.
- **File Format**: The format of the uploaded file (e.g., CSV, Excel).
- **File Upload Date**: The date when the file was uploaded to the system.
- **Data Start Date**: The start date of the data period covered by the file.
- **Data End Date**: The end date of the data period covered by the file.
- **Study ID**: A unique identifier for the study associated with the CGM data.


' as contents_md;


-- Display uniform_resource table with pagination
SELECT 'table' AS component,
    TRUE AS sort,
    TRUE AS search;
SELECT * FROM drh_cgm_file_metadata
${pagination.limit}; 
${pagination.navigation}
        ;

```

## Combined CGM Tracing

```sql drh/cgm-combined-data.sql{ route: { caption: "Combined CGM Tracing" } }
-- @route.description "Explore the comprehensive CGM dataset, integrating glucose monitoring data from all participants for in-depth analysis of glycemic patterns and trends across the study."

SELECT 'text' AS component, $page_title AS title;

SELECT 'button' AS component, 'start' AS justify;

SELECT 'button' AS component, 'xs' AS size; -- Very small
SELECT 
    'Back' AS title,
    '/drh/research-dashboard.sql' AS link, 
    'chevron-left' AS icon,
    'outline-secondary' AS outline;

${paginate("combined_cgm_tracing_cached")}

 SELECT
'text' as component,
'

The **Combined CGM Tracing** refers to a consolidated dataset of continuous glucose monitoring (CGM) data, collected from multiple participants in a research study. CGM devices track glucose levels at regular intervals throughout the day, providing detailed insights into the participants'' glycemic control over time.

In a research study, this combined dataset is crucial for analyzing glucose trends across different participants and understanding overall patterns in response to interventions or treatments. The **Combined CGM Tracing** dataset typically includes:
- **Participant ID**: A unique identifier for each participant, ensuring the data is de-identified while allowing for tracking individual responses.
- **Date_Time**: The timestamp for each CGM reading, formatted uniformly to allow accurate time-based analysis.(YYYY-MM-DD HH:MM:SS)
- **CGM_Value**: The recorded glucose level at each time point, often converted to a standard unit (e.g., mg/dL or mmol/L) and stored as a real number for precise calculations.

This combined view enables researchers to perform comparative analyses, evaluate glycemic variability, and assess overall glycemic control across participants, which is essential for understanding the efficacy of treatments or interventions in the study. By aggregating data from multiple sources, researchers can identify population-level trends while maintaining the integrity of individual data. 

' as contents_md;


-- Display uniform_resource table with pagination
SELECT 'table' AS component,
    TRUE AS sort,
    TRUE AS search;
SELECT * FROM combined_cgm_tracing_cached
${pagination.limit}; 
${pagination.navigation}
        ;

```

## Raw CGM Data Description

```sql drh/cgm-data.sql{ route: { caption: "Raw CGM Data " } }
-- @route.description "Explore detailed information about glucose levels over time, including timestamp, and glucose value."
-- @route.description "Explore detailed information about glucose levels over time, including timestamp, and glucose value."

SELECT 'button' AS component, 'start' AS justify;

SELECT 'button' AS component, 'xs' AS size; -- Very small
SELECT 
    'Back' AS title,
    '/drh/research-dashboard.sql' AS link, 
    'chevron-left' AS icon,
    'outline-secondary' AS outline;

SELECT 'text' AS component, $page_title AS title;

SELECT
'text' as component,
'
The raw CGM data includes the following key elements.

- **Date_Time**:
The exact date and time when the glucose level was recorded. This is crucial for tracking glucose trends and patterns over time. 
- **CGM_Value**:
The measured glucose level at the given timestamp. This value is typically recorded in milligrams per deciliter (mg/dL).' as contents_md;

SELECT 
    'table' AS component,
    'RAW FILES' AS markdown,
    TRUE AS sort,
    TRUE AS search;

SELECT 
    -- Label: Display the original file name exactly as it is in the database
    '[' || r.raw_file_name || ']' ||
    -- Link: Still points to the cleaned .sql path generated by the script
    '(/drh/cgm-data/raw-cgm/' || 
    LOWER(TRIM(CASE WHEN instr(r.raw_file_name, '.') > 0 
             THEN substr(r.raw_file_name, 1, instr(r.raw_file_name, '.') - 1) 
             ELSE r.raw_file_name END)) || '.sql)' 
    AS "RAW FILES",
    'drh_raw_cgm_tracing' AS "Destination",
    json_array_length(r.raw_data_payload) AS "Records"
FROM 
    drh_raw_cgm_tracing AS r
JOIN 
    sqlpage_files AS f 
    ON f.path = 'drh/cgm-data/raw-cgm/' || LOWER(TRIM(CASE WHEN instr(r.raw_file_name, '.') > 0 THEN substr(r.raw_file_name, 1, instr(r.raw_file_name, '.') - 1) ELSE r.raw_file_name END)) || '.sql'
ORDER BY 
    r.raw_file_name;
```

## Meal Data

```sql drh/combined-meal-data.sql{ route: { caption: "Combined Meal Data" } }
-- @page.description "Detailed logs of dietary intake across all study participants, including meal type and calorie information."

SELECT 'text' AS component, $page_title AS title;

SELECT 'button' AS component, 'start' AS justify;

SELECT 'button' AS component, 'xs' AS size; -- Very small
SELECT 
    'Back' AS title,
    '/drh/research-dashboard.sql' AS link, 
    'chevron-left' AS icon,
    'outline-secondary' AS outline;

SELECT
'text' as component,
'
This page provides a consolidated, static view of the **Meal Data** stream collected during the study. These logs of dietary intake provide crucial context for understanding and analyzing continuous glucose fluctuations.
' as contents_md;


SELECT
    'text' as component,
    'The **Meal Data** section contains records of all logged dietary events, including meal type and calorie information, linked by participant ID.' as contents_md;


SELECT 'text' AS component,
    '**Total Meal Records:** ' || (SELECT COUNT(*) FROM combined_meal_data_cached )
    AS contents_md;


SELECT
    'alert' AS component,
    'Error' AS color,
    '✅ No Meal data found for the current study cohort.' AS title,
    'The Meal data table is empty.' AS description
WHERE (SELECT COUNT(*) FROM combined_meal_data_cached ) = 0;

SELECT 'table' AS component,
    TRUE AS sort,
    TRUE AS search
WHERE (SELECT COUNT(*) FROM combined_meal_data_cached ) > 0;

${paginate("combined_meal_data_cached")}
SELECT
    *
FROM
    combined_meal_data_cached
where
(SELECT COUNT(*) FROM combined_meal_data_cached ) > 0
${pagination.limit};
${pagination.navigation};

```

## Fitness Data

```sql drh/combined-fitness-data.sql{ route: { caption: "Combined Fitness Data" } }
-- @page.description "Summary of physical activity metrics (steps, heart rate, distance) captured by tracking devices for all participants."

SELECT 'text' AS component, $page_title AS title;

SELECT 'button' AS component, 'start' AS justify;

SELECT 'button' AS component, 'xs' AS size; -- Very small
SELECT 
    'Back' AS title,
    '/drh/research-dashboard.sql' AS link, 
    'chevron-left' AS icon,
    'outline-secondary' AS outline;

SELECT
'text' as component,
'
This page provides a consolidated, static view of the **Fitness Data** stream collected during the study. These records of physical activity are a key behavioral factor influencing metabolism and glucose control.

' as contents_md;


SELECT
    'text' as component,
    'The **Fitness Data** section summarizes physical activity metrics (steps, heart rate, distance) captured by tracking devices for all participants.' as contents_md;


SELECT 'text' AS component,
    '**Total Fitness Records:** ' || (SELECT COUNT(*) FROM combined_fitness_data_cached )
    AS contents_md;


SELECT
    'alert' AS component,
    'Error' AS color,
    '✅ No Fitness data found for the current study cohort.' AS title,
    'The Fitness data table is empty.' AS description
WHERE (SELECT COUNT(*) FROM combined_fitness_data_cached ) = 0;

SELECT 'table' AS component,
    TRUE AS sort,
    TRUE AS search
WHERE (SELECT COUNT(*) FROM combined_fitness_data_cached) > 0;

${paginate("combined_fitness_data_cached")}
SELECT
    * FROM
    combined_fitness_data_cached
WHERE (SELECT COUNT(*) FROM combined_fitness_data_cached) > 0
${pagination.limit};
${pagination.navigation};

```

## PHI De-Identification Results

```sql drh/deidentification-log.sql{ route: { caption: "PHI De-Identification Results" } }
-- @route.description "Explore the results of PHI de-identification and review which columns have been modified."

SELECT 'button' AS component, 'start' AS justify;

SELECT 'button' AS component, 'xs' AS size; -- Very small
SELECT 
    'Back' AS title,
    '/drh/research-dashboard.sql' AS link, 
    'chevron-left' AS icon,
    'outline-secondary' AS outline;

SELECT
  'text' as component,
  'DeIdentification Results' as title;
 SELECT
  'The DeIdentification Results section provides a view of the outcomes from the de-identification process ' as contents;


SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
SELECT input_text as "deidentified column", orch_started_at,orch_finished_at ,diagnostics_md from drh_vw_orchestration_deidentify;


```

## Participant Information

```sql drh/participant-info.sql
-- @route.caption "Participant Information"
-- @route.description "The Participants Detail page is a comprehensive report that includes glucose statistics, such as the Ambulatory Glucose Profile (AGP), Glycemia Risk Index (GRI), Daily Glucose Profile, and all other metrics data."

SELECT 'button' AS component, 'start' AS justify;

SELECT 'button' AS component, 'xs' AS size; -- Very small
SELECT 
    'Back' AS title,
    '/drh/study-participant-dashboard.sql' AS link, 
    'chevron-left' AS icon,
    'outline-secondary' AS outline;

SELECT
     'card'     as component,
     '' as title,
      1         as columns;
    SELECT 
     'The Participants Detail page is a comprehensive report that includes glucose statistics, such as the Ambulatory Glucose Profile (AGP), Glycemia Risk Index (GRI), Daily Glucose Profile, and all other metrics data.' as description;
  
     

    SELECT 
        'form'            as component,
        'Filter by Date Range'   as title,
        'Submit' as validate,    
        'Clear'           as reset;
    SELECT 
        'start_date' as name,
        'Start Date' as label,
         strftime('%Y-%m-%d', MIN(Date_Time))  as value, 
        'date'       as type,
        6            as width,
        'mt-1' as class
    FROM     
        combined_cgm_tracing        
    WHERE 
        participant_id = $participant_id;  
    SELECT 
        'end_date' as name,
        'End Date' as label,
         strftime('%Y-%m-%d', MAX(Date_Time))  as value, 
        'date'       as type,
         6             as width,
         'mt-1' as class
    FROM     
        combined_cgm_tracing        
    WHERE 
        participant_id = $participant_id; 



  SELECT
    'datagrid' AS component;
  SELECT
      'MRN: ' || participant_id || '' AS title,
      ' ' AS description
  FROM
      drh_participant
  WHERE participant_id = $participant_id;

  SELECT
      'Study: ' || study_arm || '' AS title,
      ' ' AS description
  FROM
      drh_participant
  WHERE participant_id = $participant_id;

  
  SELECT
      'Age: '|| age || ' Years' AS title,
      ' ' AS description
  FROM
      drh_participant
  WHERE participant_id = $participant_id;

  SELECT
      'hba1c: ' || baseline_hba1c || '' AS title,
      ' ' AS description
  FROM
      drh_participant
  WHERE participant_id = $participant_id;

  SELECT
      'BMI: '|| bmi || '' AS title,
      ' ' AS description
  FROM
      drh_participant
  WHERE participant_id = $participant_id;

  SELECT
      'Diabetes Type: '|| diabetes_type || ''  AS title,
      ' ' AS description
  FROM
      drh_participant
  WHERE participant_id = $participant_id;

  SELECT
      strftime('Generated: %Y-%m-%d %H:%M:%S', 'now') AS title,
      ' ' AS description;
      

   SELECT 'participant_hidden_input' as component, $participant_id as participant_id;

    SELECT 
    'card' as component,    
    2      as columns;
SELECT 
    '' AS title,
    'white' As background_color,
    "/drh/chart/glucose-statistics-and-targets/index.sql?_sqlpage_embed&participant_id=" || $participant_id ||
    '&start_date=' || COALESCE($start_date, participant_cgm_dates.cgm_start_date) ||
    '&end_date=' || COALESCE($end_date, participant_cgm_dates.cgm_end_date) AS embed
FROM 
    (SELECT participant_id, 
            MIN(Date_Time) AS cgm_start_date, 
            MAX(Date_Time) AS cgm_end_date
     FROM combined_cgm_tracing
     GROUP BY participant_id) AS participant_cgm_dates
WHERE 
    participant_cgm_dates.participant_id = $participant_id;  

         
SELECT 
    '' as title,
    'white' As background_color,    
    "/drh/chart/goals-for-type-1-and-type-2-diabetes/index.sql?_sqlpage_embed&participant_id=" || $participant_id ||
    '&start_date=' || COALESCE($start_date, participant_cgm_dates.cgm_start_date) ||
    '&end_date=' || COALESCE($end_date, participant_cgm_dates.cgm_end_date) AS embed
FROM 
    (SELECT participant_id, 
            MIN(Date_Time) AS cgm_start_date, 
            MAX(Date_Time) AS cgm_end_date
     FROM combined_cgm_tracing
     GROUP BY participant_id) AS participant_cgm_dates
WHERE 
    participant_cgm_dates.participant_id = $participant_id;  

SELECT 
    '' as title,
    'white' As background_color,    
    "/drh/chart/ambulatory-glucose-profile/index.sql?_sqlpage_embed&participant_id=" || $participant_id as embed;  
SELECT 
    '' as title,
    'white' As background_color,
     "/drh/chart/daily-glucose-profile/index.sql?_sqlpage_embed&participant_id=" || $participant_id as embed;  
SELECT 
    '' as title,
    'white' As background_color,
     "/drh/chart/glycemic_risk_indicator/index.sql?_sqlpage_embed&participant_id=" || $participant_id as embed;  
  SELECT 
    '' as title,
    'white' As background_color,
    "/drh/chart/advanced_metrics/index.sql?_sqlpage_embed&participant_id=" || $participant_id  || 
    '&start_date=' || COALESCE($start_date, participant_cgm_dates.cgm_start_date) ||
    '&end_date=' || COALESCE($end_date, participant_cgm_dates.cgm_end_date) AS embed 
    FROM 
        (SELECT participant_id, 
                MIN(Date_Time) AS cgm_start_date, 
                MAX(Date_Time) AS cgm_end_date
        FROM combined_cgm_tracing
        GROUP BY participant_id) AS participant_cgm_dates
    WHERE 
        participant_cgm_dates.participant_id = $participant_id;  
```

## api

```sql drh/api/ambulatory-glucose-profile/index.sql
SELECT 'json' AS component, 
        JSON_OBJECT(
            'ambulatoryGlucoseProfile', (
                        WITH glucose_data AS (
              SELECT
                  participant_id,
                  strftime('%H', Date_Time) AS hourValue,
                  CGM_Value AS glucose_level
              FROM
                  combined_cgm_tracing
              WHERE
                  participant_id = $participant_id
              AND Date_Time BETWEEN $start_date AND $end_date
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
              FROM (
                  SELECT
                      participant_id,
                      hourValue,
                      glucose_level,
                      ROW_NUMBER() OVER (PARTITION BY participant_id, hourValue ORDER BY glucose_level) AS row_num,
                      COUNT(*) OVER (PARTITION BY participant_id, hourValue) AS total_count
                  FROM
                      glucose_data
              ) ranked_data
              GROUP BY
                  participant_id, hourValue
          )
          SELECT JSON_GROUP_ARRAY(
                    JSON_OBJECT(
                        'participant_id', participant_id,
                        'hour', hour,
                        'p5', COALESCE(p5, 0),
                        'p25', COALESCE(p25, 0),
                        'p50', COALESCE(p50, 0),
                        'p75', COALESCE(p75, 0),
                        'p95', COALESCE(p95, 0)
                    )
                ) AS result
          FROM
              percentiles
          GROUP BY
              participant_id
   

            )
        ) AS contents;
```

```sql drh/api/time_range_stacked_metrics/index.sql
SELECT 'json' AS component, 
        JSON_OBJECT(
            'timeMetrics', (
                SELECT 
                    JSON_OBJECT(
                        'participant_id', participant_id, 
                        'timeBelowRangeLow', CAST(COALESCE(SUM(CASE WHEN CGM_Value BETWEEN 54 AND 69 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 0) AS INTEGER),                        
                        'timeBelowRangeVeryLow', CAST(COALESCE(SUM(CASE WHEN CGM_Value < 54 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 0) AS INTEGER),                        
                        'timeInRange', CAST(COALESCE(SUM(CASE WHEN CGM_Value BETWEEN 70 AND 180 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 0) AS INTEGER),                        
                        'timeAboveRangeVeryHigh', CAST(COALESCE(SUM(CASE WHEN CGM_Value > 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 0) AS INTEGER),                        
                        'timeAboveRangeHigh', CAST(COALESCE(SUM(CASE WHEN CGM_Value BETWEEN 181 AND 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 0) AS INTEGER) 
                    )
                FROM 
                    combined_cgm_tracing
                WHERE 
                    participant_id = $participant_id    
                AND Date_Time BETWEEN $start_date AND $end_date
            )
        ) AS contents; 
```

```sql drh/api/daily-glcuose-profile/index.sql
SELECT 'json' AS component, 
        JSON_OBJECT(
            'daily_glucose_profile', (
                SELECT JSON_GROUP_ARRAY(
                    JSON_OBJECT(
                        'date_time', Date_Time, 
                        'date', strftime('%Y-%m-%d', Date_Time), 
                        'hour', strftime('%H', Date_Time),                        
                        'glucose', CGM_Value                     
                    )
                ) 
                  FROM
                    combined_cgm_tracing
                  WHERE
                    participant_id = $participant_id
                  AND Date_Time BETWEEN $start_date AND $end_date
            )
        ) AS contents;   
```

```sql drh/api/glycemic_risk_indicator/index.sql
SELECT 'json' AS component, 
        JSON_OBJECT(
            'glycemicRiskIndicator', (
                SELECT JSON_OBJECT(
                        'time_above_VH_percentage', ROUND(COALESCE((SUM(CASE WHEN cgm_value > 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)), 0), 2),
                        'time_above_H_percentage', ROUND(COALESCE((SUM(CASE WHEN cgm_value BETWEEN 181 AND 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)), 0), 2),
                        'time_in_range_percentage', ROUND(COALESCE((SUM(CASE WHEN cgm_value BETWEEN 70 AND 180 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)), 0), 2),
                        'time_below_low_percentage', ROUND(COALESCE((SUM(CASE WHEN cgm_value BETWEEN 54 AND 69 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)), 0), 2),
                        'time_below_VL_percentage', ROUND(COALESCE((SUM(CASE WHEN cgm_value < 54 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)), 0), 2),
                        'Hypoglycemia_Component', ROUND(COALESCE((SUM(CASE WHEN cgm_value < 54 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)) + 
                                                              (0.8 * (SUM(CASE WHEN cgm_value BETWEEN 54 AND 69 THEN 1 ELSE 0 END) * 100.0 / COUNT(*))), 0), 2),
                        'Hyperglycemia_Component', ROUND(COALESCE((SUM(CASE WHEN cgm_value > 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)) + 
                                                                  (0.5 * (SUM(CASE WHEN cgm_value BETWEEN 181 AND 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*))), 0), 2),
                        'GRI', ROUND(COALESCE((3.0 * ((SUM(CASE WHEN cgm_value < 54 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)) + 
                                                    (0.8 * (SUM(CASE WHEN cgm_value BETWEEN 54 AND 69 THEN 1 ELSE 0 END) * 100.0 / COUNT(*))))) + 
                                        (1.6 * ((SUM(CASE WHEN cgm_value > 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)) + 
                                                (0.5 * (SUM(CASE WHEN cgm_value BETWEEN 181 AND 250 THEN 1 ELSE 0 END) * 100.0 / COUNT(*))))), 0), 2)
                ) 
                  FROM
                    combined_cgm_tracing
                  WHERE
                    participant_id = $participant_id 
                  AND Date_Time BETWEEN $start_date AND $end_date
            )
        ) AS contents;   
```

```sql drh/api/advanced_metrics/index.sql
SELECT 'json' AS component, 
        JSON_OBJECT(
            'advancedMetrics', (
                SELECT JSON_OBJECT(
                        'time_in_tight_range_percentage', round(time_in_tight_range_percentage,3) 
                ) 
                  FROM 
                    drh_advanced_metrics
                  WHERE
                    participant_id = $participant_id 
            )
        ) AS contents;  
```

```sql drh/chart/glycemic_risk_indicator/index.sql
  SELECT 'gri_component' AS component; 
```

```sql drh/chart/glucose-statistics-and-targets/index.sql
SELECT  
    'html' as component;
    SELECT '<div class="fs-3 p-1 fw-bold" style="background-color: #E3E3E2; text-black;">GLUCOSE STATISTICS AND TARGETS</div><div class="px-4">' as html;
    SELECT  
      '<div class="card-content my-1">'|| strftime('%Y-%m-%d', MIN(Date_Time)) || ' - ' ||  strftime('%Y-%m-%d', MAX(Date_Time)) || ' <span style="float: right;">'|| CAST(julianday(MAX(Date_Time)) - julianday(MIN(Date_Time)) AS INTEGER) ||' days</span></div>' as html
    FROM  
        combined_cgm_tracing
    WHERE 
        participant_id = $participant_id
     AND Date_Time BETWEEN $start_date AND $end_date;   

    SELECT  
      '<div class="card-content my-1" style="display: flex; flex-direction: row; justify-content: space-between;"><b>Time CGM Active</b> <div style="display: flex; justify-content: flex-end; align-items: center;"><div style="display: flex;align-items: center;gap: 0.1rem;"><b>' || ROUND(
        (COUNT(DISTINCT DATE(Date_Time)) / 
        ROUND((julianday(MAX(Date_Time)) - julianday(MIN(Date_Time)) + 1))
        ) * 100, 2) || '</b> % <formula-component content="This metric calculates the percentage of time during a specific period (e.g., a day, week, or month) that the CGM device is actively collecting data. It takes into account the total duration of the monitoring period and compares it to the duration during which the device was operational and recording glucose readings."></formula-component></div></div></div>' as html
    FROM
      combined_cgm_tracing  
    WHERE 
      participant_id = $participant_id
    AND Date_Time BETWEEN $start_date AND $end_date;    

    SELECT  
      '<div class="card-content my-1" style="display: flex; flex-direction: row; justify-content: space-between;"><b>Number of Days CGM Worn</b> <div style="display: flex; justify-content: flex-end; align-items: center;"><div style="display: flex;align-items: center;gap: 0.1rem;"><b>'|| COUNT(DISTINCT DATE(Date_Time)) ||'</b> days<formula-component content="This metric represents the total number of days the CGM device was worn by the user over a monitoring period. It helps in assessing the adherence to wearing the device as prescribed."></formula-component></div></div></div>' as html
    FROM
        combined_cgm_tracing  
    WHERE 
        participant_id = $participant_id
    AND Date_Time BETWEEN $start_date AND $end_date;

    SELECT  
      '<div class="card-body" style="background-color: #E3E3E2;border: 1px solid black;">
                      <div class="table-responsive">
                        <table class="table">                           
                           <tbody class="table-tbody list">
                           <tr>
                                <th colspan="2" style="text-align: center;">
                                  Ranges And Targets For Type 1 or Type 2 Diabetes
                                </th>
                              </tr>
                              <tr> 
                                <th>
                                  Glucose Ranges
                                </th>
                                <th>
                                  Targets % of Readings (Time/Day)
                                </th>
                              </tr>
                              <tr>
                                <td>Target Range 70-180 mg/dL</td>
                                <td>Greater than 70% (16h 48min)</td>
                              </tr>
                              <tr>
                                <td>Below 70 mg/dL</td>
                                <td>Less than 4% (58min)</td>
                              </tr>
                              <tr>
                                <td>Below 54 mg/dL</td>
                                <td>Less than 1% (14min)</td>
                              </tr>
                              <tr>
                                <td>Above 180 mg/dL</td>
                                <td>Less than 25% (6h)</td>
                              </tr>
                              <tr>
                                <td>Above 250 mg/dL</td>
                                <td>Less than 5% (1h 12min)</td>
                              </tr>
                              <tr>
                                <td colspan="2">Each 5% increase in time in range (70-180 mg/dL) is clinically beneficial.</td>                                
                              </tr>
                           </tbody>
                        </table>
                      </div>
                    </div>' as html; 

    SELECT  
      '<div class="card-content my-1" style="display: flex; flex-direction: row; justify-content: space-between;"><b>Mean Glucose</b> <div style="display: flex; justify-content: flex-end; align-items: center;"><div style="display: flex;align-items: center;gap: 0.1rem;"><b>'|| ROUND(AVG(CGM_Value), 2) ||'</b> mg/dL<formula-component content="Mean glucose reflects the average glucose level over the monitoring period, serving as an indicator of overall glucose control. It is a simple yet powerful measure in glucose management."></formula-component></div></div></div>' as html
    FROM
      combined_cgm_tracing  
    WHERE 
      participant_id = $participant_id
    AND Date_Time BETWEEN $start_date AND $end_date;

    SELECT  
      '<div class="card-content my-1" style="display: flex; flex-direction: row; justify-content: space-between;"><b>Glucose Management Indicator (GMI)</b> <div style="display: flex; justify-content: flex-end; align-items: center;"><div style="display: flex;align-items: center;gap: 0.1rem;"><b>'|| ROUND(AVG(CGM_Value) * 0.155 + 95, 2) ||'</b> %<formula-component content="GMI provides an estimated A1C level based on mean glucose, which can be used as an indicator of long-term glucose control. GMI helps in setting and assessing long-term glucose goals."></formula-component></div></div></div>' as html
    FROM
      combined_cgm_tracing  
    WHERE 
      participant_id = $participant_id
    AND Date_Time BETWEEN $start_date AND $end_date;
      
    SELECT  
      '<div class="card-content my-1" style="display: flex; flex-direction: row; justify-content: space-between;"><b>Glucose Variability</b> <div style="display: flex; justify-content: flex-end; align-items: center;"><div style="display: flex;align-items: center;gap: 0.1rem;"><b>'|| ROUND((SQRT(AVG(CGM_Value * CGM_Value) - AVG(CGM_Value) * AVG(CGM_Value)) / AVG(CGM_Value)) * 100, 2) ||'</b> %<formula-component content="Glucose variability measures fluctuations in glucose levels over time, calculated as the coefficient of variation (%CV). A lower %CV indicates more stable glucose control."></formula-component></div></div></div>' as html   
    FROM
      combined_cgm_tracing  
    WHERE 
      participant_id = $participant_id
    AND Date_Time BETWEEN $start_date AND $end_date;  
      
    SELECT  
      '<div class="card-content my-1">Defined as percent coefficient of variation (%CV); target ≤36%</div></div>' as html; 
```

```sql drh/chart/goals-for-type-1-and-type-2-diabetes/index.sql
SELECT 'stacked_bar_chart' AS component, $start_date AS start_date,$end_date AS end_date;
```

```sql drh/chart/ambulatory-glucose-profile/index.sql
    SELECT 'agp-chart' AS component;
```

```sql drh/chart/daily-glucose-profile/index.sql
    SELECT 'dgp-chart' AS component;
```

```sql drh/chart/advanced_metrics/index.sql
SELECT 'advanced_metrics' as component;

-- Liability Index and Episode Counts
SELECT
    'Liability Index' as label,
    ROUND(CAST((SUM(CASE WHEN CGM_Value < 70 THEN 1 ELSE 0 END) + SUM(CASE WHEN CGM_Value > 180 THEN 1 ELSE 0 END)) AS REAL) / COUNT(*), 2) || ' mg/dL' as value,
    'The Liability Index quantifies the risk associated with glucose variability, measured in mg/dL.' as formula
FROM combined_cgm_tracing
WHERE participant_id = $participant_id AND Date(Date_Time) BETWEEN $start_date AND $end_date;

SELECT
    'Hypoglycemic Episodes' as label,
    SUM(CASE WHEN CGM_Value < 70 THEN 1 ELSE 0 END) as value,
    'This metric counts the number of occurrences when glucose levels drop below a specified hypoglycemic threshold, indicating potentially dangerous low blood sugar events.' as formula
FROM combined_cgm_tracing
WHERE participant_id = $participant_id AND Date(Date_Time) BETWEEN $start_date AND $end_date;

SELECT
    'Euglycemic Episodes' as label,
    SUM(CASE WHEN CGM_Value BETWEEN 70 AND 180 THEN 1 ELSE 0 END) as value,
    'This metric counts the number of instances where glucose levels remain within the target range, indicating stable and healthy glucose control.' as formula
FROM combined_cgm_tracing
WHERE participant_id = $participant_id AND Date(Date_Time) BETWEEN $start_date AND $end_date;

SELECT
    'Hyperglycemic Episodes' as label,
    SUM(CASE WHEN CGM_Value > 180 THEN 1 ELSE 0 END) as value,
    'This metric counts the number of instances where glucose levels exceed a certain hyperglycemic threshold, indicating potentially harmful high blood sugar events.' as formula
FROM combined_cgm_tracing
WHERE participant_id = $participant_id AND Date(Date_Time) BETWEEN $start_date AND $end_date;

-- M Value
SELECT
    'M Value' as label,
    ROUND((MAX(CGM_Value) - MIN(CGM_Value)) / ((strftime('%s', MAX(DATETIME(Date_Time))) - strftime('%s', MIN(DATETIME(Date_Time)))) / 60.0), 3) || ' mg/dL' as value,
    'The M Value provides a measure of glucose variability, calculated from the mean of the absolute differences between consecutive CGM values over a specified period.' as formula
FROM combined_cgm_tracing
WHERE participant_id = $participant_id AND Date(Date_Time) BETWEEN $start_date AND $end_date;

-- Mean Amplitude
SELECT
    'Mean Amplitude' as label,
    ROUND(AVG(amplitude), 3) as value,
    'Mean Amplitude quantifies the average degree of fluctuation in glucose levels over a given time frame, giving insight into glucose stability.' as formula
FROM (
    SELECT ABS(MAX(CGM_Value) - MIN(CGM_Value)) AS amplitude
    FROM combined_cgm_tracing
    WHERE participant_id = $participant_id AND Date(Date_Time) BETWEEN $start_date AND $end_date
    GROUP BY DATE(Date_Time)
);

-- Average Daily Risk Range
SELECT
    'Average Daily Risk Range' as label,
    ROUND(AVG(daily_range), 3) || ' mg/dL' as value,
    'This metric assesses the average risk associated with daily glucose variations, expressed in mg/dL.' as formula
FROM (
    SELECT
        MAX(CGM_Value) - MIN(CGM_Value) AS daily_range
    FROM combined_cgm_tracing
    WHERE participant_id = $participant_id AND DATE(date_time) BETWEEN DATE($start_date) AND DATE($end_date)
    GROUP BY DATE(date_time)
);

-- J Index
SELECT
    'J Index' as label,
    ROUND(0.001 * (mean_glucose + SQRT(variance_glucose)) * (mean_glucose + SQRT(variance_glucose)), 2) || ' mg/dL' as value,
    'The J Index calculates glycemic variability using both high and low glucose readings, offering a comprehensive view of glucose fluctuations.' as formula
FROM (
    SELECT
        AVG(CGM_Value) AS mean_glucose,
        (AVG(CGM_Value * CGM_Value) - AVG(CGM_Value) * AVG(CGM_Value)) AS variance_glucose
    FROM combined_cgm_tracing
    WHERE participant_id = $participant_id AND DATE(Date_Time) BETWEEN DATE($start_date) AND DATE($end_date)
);

-- Low Blood Glucose Index
SELECT
    'Low Blood Glucose Index' as label,
    ROUND(SUM(CASE WHEN (CGM_Value - 2.5) / 2.5 > 0
              THEN ((CGM_Value - 2.5) / 2.5) * ((CGM_Value - 2.5) / 2.5)
              ELSE 0 END) * 5, 2) as value,
    'This metric quantifies the risk associated with low blood glucose levels over a specified period, measured in mg/dL.' as formula
FROM combined_cgm_tracing
WHERE participant_id = $participant_id AND DATE(Date_Time) BETWEEN $start_date AND $end_date;

-- High Blood Glucose Index
SELECT
    'High Blood Glucose Index' as label,
    ROUND(SUM(CASE WHEN (CGM_Value - 9.5) / 9.5 > 0
              THEN ((CGM_Value - 9.5) / 9.5) * ((CGM_Value - 9.5) / 9.5)
              ELSE 0 END) * 5, 2) as value,
    'This metric quantifies the risk associated with high blood glucose levels over a specified period, measured in mg/dL.' as formula
FROM combined_cgm_tracing
WHERE participant_id = $participant_id AND DATE(Date_Time) BETWEEN $start_date AND $end_date;

-- GRADE (Glycaemic Risk Assessment Diabetes Equation)
SELECT
    'Glycaemic Risk Assessment Diabetes Equation (GRADE)' as label,
    ROUND(AVG(CASE
        WHEN CGM_Value < 90 THEN 10 * (5 - (CGM_Value / 18.0)) * (5 - (CGM_Value / 18.0))
        WHEN CGM_Value > 180 THEN 10 * ((CGM_Value / 18.0) - 10) * ((CGM_Value / 18.0) - 10)
        ELSE 0
    END), 3) as value,
    'GRADE is a metric that combines various glucose metrics to assess overall glycemic risk in individuals with diabetes, calculated using multiple input parameters.' as formula
FROM combined_cgm_tracing
WHERE participant_id = $participant_id AND DATE(Date_Time) BETWEEN $start_date AND $end_date;

-- CONGA (Continuous Overall Net Glycemic Action)
      CREATE TEMPORARY TABLE lag_values AS 
      SELECT 
          participant_id,
          Date_Time,
          CGM_Value,
          LAG(CGM_Value) OVER (PARTITION BY participant_id ORDER BY Date_Time) AS lag_CGM_Value
      FROM 
          combined_cgm_tracing
      WHERE
         participant_id = $participant_id
          AND DATE(Date_Time) BETWEEN $start_date AND $end_date;

      CREATE TEMPORARY TABLE conga_hourly AS 
      SELECT 
          participant_id,
          SQRT(
              AVG(
                  (CGM_Value - lag_CGM_Value) * (CGM_Value - lag_CGM_Value)
              ) OVER (PARTITION BY participant_id ORDER BY Date_Time)
          ) AS conga_hourly
      FROM 
          lag_values
      WHERE 
          lag_CGM_Value IS NOT NULL; 

    SELECT
        'Continuous Overall Net Glycemic Action (CONGA)' as label,
        round(AVG(conga_hourly),3) as value,
        'CONGA quantifies the net glycemic effect over time by evaluating the differences between CGM values at specified intervals.' as formula
    FROM 
            conga_hourly;

  DROP TABLE IF EXISTS lag_values;  
  DROP TABLE IF EXISTS conga_hourly;

-- Mean of Daily Differences
SELECT
    'Mean of Daily Differences' as label,
    ROUND(AVG(daily_diff), 3) as value,
    'This metric calculates the average of the absolute differences between daily CGM readings, giving insight into daily glucose variability.' as formula
FROM (
    SELECT
        CGM_Value - LAG(CGM_Value) OVER (PARTITION BY participant_id ORDER BY DATE(Date_Time)) AS daily_diff
    FROM combined_cgm_tracing
    WHERE participant_id = $participant_id AND DATE(Date_Time) BETWEEN $start_date AND $end_date
) AS daily_diffs
WHERE daily_diff IS NOT NULL;

```
