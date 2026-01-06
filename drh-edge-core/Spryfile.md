---
sqlpage-conf:
  database_url: ${env.SPRY_DB}
  web_root: "./dev-src.auto"
  allow_exec: true
  port: ${env.PORT}
---

# Diabetes Research Hub (DRH) SQLPage Application

This script automates the conversion of raw diabetes research data (e.g.,CSV, Parquet, or a private data warehouse export) into a structured SQLite database.

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

### Pipeline & Study Configuration (Required for `prepare-db` task)

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

```envrc prepare-env  -C ./.envrc --gitignore -X  --descr "Generate .envrc file and add it to local .gitignore if it's not already there"
export SPRY_DB="sqlite://resource-surveillance.sqlite.db?mode=rwc"
export PORT=9227
export STUDY_DATA_PATH="raw-data/simplera-synthetic-cgm/"
export TENANT_ID="FLCG"
export TENANT_NAME="Florida Clinical Group"
```

Then run `direnv allow` in this project directory to load the `.envrc` into your shell environment. direnv will evaluate `.envrc` only after you explicitly allow it.

-----

## Security and repository hygiene

- Never commit secrets or production credentials into `.envrc`. Treat `.envrc` like a local-only file.
- Add `.envrc` to your local `.gitignore` if you keep secrets there. Alternatively commit a `.envrc.example` or `.envrc.sample` with safe, non-secret defaults to document expected variables.
- The SQLite file (e.g. `resource-surveillance.sqlite.db`) is a binary database file — you will usually not check this into version control. Add that filename or the `data/` directory to `.gitignore` as well.

Why these variables matter here

- The YAML header at the top of this `Spryfile.md` reads `database_url: ${env.SPRY_DB}` and `port: ${env.PORT}` — Spry and the SQLPage tooling will substitute those environment values when building or serving the site.
- The `prepare-db` task explicitly checks for `STUDY_DATA_PATH`, `TENANT_ID`, and `TENANT_NAME` and will halt if any are missing.
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
  - `spry rb task prepare-db`
- The `prepare-db` task, requires the **`$STUDY_DATA_PATH`**, **`${TENANT_ID}`**, and **`${TENANT_NAME}`** as parameters which are provided through env.
- This step cleans up old files, validates data ,performs a pre-etl-validation , performs ingestion, and runs all complex DuckDB transformations, generating the final resource-surveillance.sqlite.db file.

```bash prepare-db --descr "Performs pre-etl-validation ,Extract data , Perform transformations through DuckDB and export to the SQLite database used by SQLPage"
#!/bin/bash
# Exit immediately if a command exits with a non-zero status (except for the Deno check)
# set -e
# Treat unset variables as an error
set -u

# Define variables for clarity (assuming they are set by Spry/environment)
STUDY_DATA_PATH="${STUDY_DATA_PATH}"
TENANT_ID="${TENANT_ID}"
TENANT_NAME="${TENANT_NAME}"
TOOL_CMD="surveilr"

# 2. Cleanup
rm -f resource-surveillance.sqlite.db
rm -f *.sql
rm -rf dev-src.auto validation-reports
echo "STUDY_DATA_PATH: ${STUDY_DATA_PATH}"
echo "Starting the pipeline.."


# 3. CRITICAL PRE-VALIDATION GATE
deno run -A drh-pre-etl-validation.ts "${STUDY_DATA_PATH}" "${TENANT_ID}" "${TENANT_NAME}"
VALIDATION_EXIT_CODE=$?
if [ ${VALIDATION_EXIT_CODE} -eq 0 ]; then        
    # Using 'set -e' locally to ensure these chained steps halt immediately on failure
    (
        set -e        
        "${TOOL_CMD}" ingest files -r "${STUDY_DATA_PATH}" --tenant-id "${TENANT_ID}" --tenant-name "${TENANT_NAME}"
        "${TOOL_CMD}" orchestrate transform-csv        
    )
    # Check if the ingestion/transformation subshell failed
    if [ $? -ne 0 ]; then
        echo "FAILURE: Ingestion or Initial Transformation failed. Halting pipeline........."
        exit 1
    fi    
    "${TOOL_CMD}" shell common-sql/drh-data-validation.sql    
    # Check SQL Validation success
    if [ $? -ne 0 ]; then
        echo "FAILURE: Post-Ingestion SQL Validation failed. Halting complex ETL........."
        exit 1
    fi   
    
    # Run all complex ETL steps, halting immediately on any failure
    (
        set -e
        "${TOOL_CMD}" shell common-sql/drh-anonymize-prepare.sql            
        "${TOOL_CMD}" shell --engine duckdb duckdb-etl-sql/drh-master-etl.sql
        "${TOOL_CMD}" shell common-sql/drh-metrics-pipeline.sql        
        echo "ETL process complete. Database generated successfully......... "
    )
    
    if [ $? -ne 0 ]; then
        echo "FAILURE: Complex ETL failed. Halting pipeline."
        exit 1
    fi   

else
    # This block executes if VALIDATION_EXIT_CODE is 1 (FAIL or WARNING)
    echo "FAILURE: Data Pre-Validation failed or returned a WARNING status (Exit Code 1)."    
    exit 1
fi
```

## SQLPage Dev / Watch mode

While you're developing, Spry's `dev-src.auto` generator should be used:

```bash  
spry sp spc --fs dev-src.auto --destroy-first --conf sqlpage/sqlpage.json  
```

```bash  clean --graph special --silent --descr "Clean up the project directory's generated artifacts"
rm -rf dev-src.auto
rm -f *.sql   
rm -rf validation-reports
```

In development mode, here’s the `--watch` convenience you can use so that
whenever you update `Spryfile.md`, it regenerates the SQLPage `dev-src.auto`,
which is then picked up automatically by the SQLPage server:

```bash
spry sp spc --fs dev-src.auto --destroy-first --conf sqlpage/sqlpage.json --watch --with-sqlpage
```

- `--watch` turns on watching all `--md` files passed in (defaults to `Spryfile.md`)
- `--with-sqlpage` starts and stops SQLPage after each build

Restarting SQLPage after each re-generation of dev-src.auto is **not**
necessary, so you can also use `--watch` without `--with-sqlpage` in one
terminal window while keeping the SQLPage server running in another terminal
window.

If you're running SQLPage in another terminal window, use:

```bash
spry sp spc  --fs dev-src.auto --destroy-first --conf sqlpage/sqlpage.json --watch
```

## SQLPage single database deployment mode

After development is complete, the `dev-src.auto` can be removed and
single-database deployment can be used:

```bash build-server   --descr "Generate sqlpage_files table upsert SQL and push them to SQLite"
#!/usr/bin/env -S bash
rm -rf dev-src.auto
echo "DRH EDGE UI Build is in progress............."
spry sp spc --package --conf sqlpage/sqlpage.json | sqlite3 resource-surveillance.sqlite.db  
echo "Data Pipeline and UI Build complete..."
echo "DRH EDGE UI will be available at http://localhost:9227/"
```

## Layout

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

```sql index.sql { route: { caption: "DRH Edge UI Home" } }
-- @route.description "Welcome to Diabetes Research Hub Edge UI."

SELECT
      'card'                      as component,
      'Welcome to the Diabetes Research Hub Edge UI' as title,
      1                           as columns;

SELECT
      'About' as title,
      'green'                        as color,
      'white'                  as background_color,
      'The Diabetes Research Hub (DRH) addresses a growing need for a centralized platform to manage and analyze continuous glucose monitor (CGM) data.Our primary focus is to collect data from studies conducted by various researchers. Initially, we are concentrating on gathering CGM data, with plans to collect additional types of data in the future.' as description,
      'home'                 as icon;

SELECT
      'card'                  as component,
      'Study Data Diagnostics' as title,      
      1                     as columns;

SELECT
    'alert' AS component,
    -- Color logic based on status
    CASE overall_status
        WHEN 'FAIL' THEN 'red'
        WHEN 'WARNING' THEN 'orange'
        WHEN 'PASS' THEN 'green'
        ELSE 'blue'
    END AS color,
    'Latest System & Data Diagnostics Report' AS title,
    -- Corrected syntax, date format (dd-mm-yy hh:mm:ss) and HTML bolding
    'Overall Status: ' || overall_status || '' AS description
FROM 
    validation_reports
WHERE 
    overall_status IS NOT NULL
ORDER BY
    timestamp DESC
LIMIT 1;


select 
    'list'                 as component,
    'Data and Dependency Diagnostics Report' as title,    
    TRUE                   as compact;  
select     
    CASE json_extract(j.value, '$.status')
        WHEN 'FAIL' THEN 'red'
        WHEN 'WARNING' THEN 'orange'
        WHEN 'PASS' THEN 'green'
        ELSE 'blue'
    END AS color,    
    CASE 
        WHEN json_extract(j.value, '$.check') LIKE '[Dependency]%' THEN 'settings' -- Dependency -> gear/settings
        WHEN json_extract(j.value, '$.check') LIKE 'Folder%' THEN 'folder'         -- Folder -> folder icon
        WHEN json_extract(j.value, '$.check') LIKE 'Schema%' THEN 'database'       -- Schema -> database icon
        WHEN json_extract(j.value, '$.check') LIKE '%File%' OR json_extract(j.value, '$.check') LIKE '%Metadata%' THEN 'file' -- File/Metadata -> file icon
        -- Fallback status icon
        WHEN json_extract(j.value, '$.status') = 'FAIL' THEN 'ban'
        WHEN json_extract(j.value, '$.status') = 'WARNING' THEN 'warning'
        WHEN json_extract(j.value, '$.status') = 'PASS' THEN 'check'
        ELSE 'info'
    END AS icon,    
    json_extract(j.value, '$.check') AS title,    
    IFNULL(json_extract(j.value, '$.details'), 'No details provided.') AS description
FROM 
    (
        SELECT report_json FROM validation_reports ORDER BY timestamp DESC LIMIT 1
    ) AS t,
    json_each(t.report_json, '$.results') AS j
WHERE t.report_json IS NOT NULL
ORDER BY 
    CASE json_extract(j.value, '$.status')
        WHEN 'FAIL' THEN 1 
        WHEN 'WARNING' THEN 2 
        ELSE 3 
    END;


SELECT
      'card'                  as component,
      'File Detailed Diagnostics' as title,
      2                    as columns;


SELECT
    'Study Files Log'  as title,
    '/drh/ingestion-log.sql' as link,
    'This section provides an overview of the files that have been accepted and converted into database format for research purposes' as description,
    'book'                as icon,
    'red'                    as color;





SELECT
    'Verification Log' AS title,
    '/drh/verification-validation-log.sql' AS link,
    'Use this section to review the issues identified in the file content and take appropriate corrective actions.' AS description,
    'table' AS icon,
    'red' AS color;



SELECT
      'card'                  as component,
      'Features ' as title,
      11                     as columns;


SELECT
    'Study Participant Dashboard'  as title,
    '/drh/study-participant-dashboard.sql' as link,
    'The dashboard presents key study details and participant-specific metrics in a clear, organized table format' as description,
    'table'                as icon,
    'red'                    as color;
;




SELECT
    'Researcher and Associated Information'  as title,
    '/drh/researcher-related-data.sql' as link,
    'This section provides detailed information about the individuals , institutions and labs involved in the research study.' as description,
    'book'                as icon,
    'red'                    as color;
;

SELECT
    'Study ResearchSite Details'  as title,
    '/drh/study-related-data.sql' as link,
    'This section provides detailed information about the study , and sites involved in the research study.' as description,
    'book'                as icon,
    'red'                    as color;
;

SELECT
    'Participant Demographics'  as title,
    '/drh/participant-related-data.sql' as link,
    'This section provides detailed information about the the participants involved in the research study.' as description,
    'book'                as icon,
    'red'                    as color;
;

SELECT
    'Author and Publication Details'  as title,
    '/drh/author-pub-data.sql' as link,
    'Information about research publications and the authors involved in the studies are also collected, contributing to the broader understanding and dissemination of research findings.' as description,
     'book' AS icon,
    'red'                    as color;
;



SELECT
    'CGM Meta Data and Associated information'  as title,
    '/drh/cgm-associated-data.sql' as link,
    'This section provides detailed information about the CGM device used, the relationship between the participant''s raw CGM tracing file and related metadata, and other pertinent information.' as description,
    'book'                as icon,
    'red'                    as color;

;


SELECT
    'Raw CGM Data Description' AS title,
    '/drh/cgm-data.sql' AS link,
    'Explore detailed information about glucose levels over time, including timestamp, and glucose value.' AS description,
    'book'                as icon,
    'red'                    as color;     


SELECT
   'Combined CGM Tracing' AS title,
    '/drh/cgm-combined-data.sql' AS link,
    'Explore the comprehensive CGM dataset, integrating glucose monitoring data from all participants for in-depth analysis of glycemic patterns and trends across the study.' AS description,
    'chart-line'                as icon,
    'red'                    as color;                   

SELECT
 'Combined Meal Data' AS title,
 '/drh/combined-meal-data.sql' AS link,
 'Detailed logs of dietary intake across all study participants. This dataset includes meal type, calorie information, and precise timestamps, providing essential contextual data for analyzing post-prandial glucose responses.' AS description,
 'soup' as icon,
 'red' as color;


SELECT
 'Combined Fitness Data' AS title,
 '/drh/combined-fitness-data.sql' AS link,
 'Aggregated summary of physical activity metrics captured by participant tracking devices. This includes daily steps, duration of activity, heart rate data, and distance, crucial for assessing the impact of exercise on metabolic outcomes.' AS description,
 'run' as icon,
 'red' as color;

SELECT
    'PHI De-Identification Results' AS title,
    '/drh/deidentification-log.sql' AS link,
    'Explore the results of PHI de-identification and review which columns have been modified.' AS description,
    'book'                as icon,
    'red'                    as color;
;

```

## Study Files Log Page

```sql drh/ingestion-log.sql { route: { caption: "Study Files Log" } }
-- @route.description "This section provides an overview of the files that have been accepted and converted into database format for research purposes"

SELECT 'text' AS component, $page_title AS title;

${paginate("drh_study_files_table_info")}

SELECT
  '
  This section provides an overview of the files that have been accepted and converted into database format for research purposes. The conversion process ensures that data from various sources is standardized, making it easier for researchers to analyze and draw meaningful insights.
  Additionally, the corresponding database table names generated from these files are listed for reference.' as contents;

SELECT 'table' AS component,
  TRUE AS sort,
  TRUE AS search;

SELECT
  file_name,
  file_format,
  table_name
FROM drh_study_files_table_info
ORDER BY file_name ASC
${pagination.limit}; 
${pagination.navigation} 

```

## Verification Validation log page

```sql drh/verification-validation-log.sql { route: { caption: "Verification And Validation Results" } }
-- @route.description "This section provides the verification and valdiation results performed on the study files"


SELECT 'text' AS component, $page_title AS title;

${paginate("drh_vandv_orch_issues")}

SELECT
    'text' as component,
    '
    Validation is a detailed process where we assess if the data within the files conforms to expecuted rules or constraints. This step ensures that the content of the files is both correct and meaningful before they are utilized for further processing.' as contents;



SELECT
  'steps' AS component,
  TRUE AS counter,
  'green' AS color;


SELECT
  'Check the Validation Log' AS title,
  'file' AS icon,
  '#' AS link,
  'If the log is empty, no action is required. Your files are good to go! If the log has entries, follow the steps below to fix any issues.' AS description;


SELECT
  'Note the Issues' AS title,
  'note' AS icon,
  '#' AS link,
  'Review the log to see what needs fixing for each file. Note them down to make a note on what needs to be changed in each file.' AS description;


SELECT
  'Stop the Edge UI' AS title,
  'square-rounded-x' AS icon,
  '#' AS link,
  'Make sure to stop the UI (press CTRL+C in the terminal).' AS description;


SELECT
  'Make Corrections in Files' AS title,
  'edit' AS icon,
  '#' AS link,
  'Edit the files according to the instructions provided in the log. For example, if a file is empty, fill it with the correct data.' AS description;


SELECT
  'Copy the modified Files to the folder' AS title,
  'copy' AS icon,
  '#' AS link,
  'Once you’ve made the necessary changes, replace the old files with the updated ones in the folder.' AS description;


SELECT
  'Execute the run book again' AS title,
  'retry' AS icon,
  '#' AS link,
  'Execute the run book again.' AS description;


SELECT
  'Repeat the steps until issues are resolved' AS title,
  'refresh' AS icon,
  '#' AS link,
  'Continue this process until the log is empty and all issues are resolved' AS description;


SELECT
    'text' as component,
    '
    Reminder: Keep updating and re-running the process until you see no entries in the log below.' as contents;


SELECT
  'alert' AS component,
  'success' AS color,
  '✅ There are no validation or verification issues. All checks passed successfully!' AS title,
  'Your data has passed all verification and validation checks.' AS description
WHERE (SELECT COUNT(*) FROM drh_vandv_orch_issues) = 0;



SELECT 'table' AS component,
  TRUE AS sort,
  TRUE AS search
WHERE (SELECT COUNT(*) FROM drh_vandv_orch_issues) > 0;

SELECT *
FROM drh_vandv_orch_issues
WHERE (SELECT COUNT(*) FROM drh_vandv_orch_issues) > 0
${pagination.limit}; 
${pagination.navigation}

```

## Study Participant Dashboard

```sql drh/study-participant-dashboard.sql{ route: { caption: "Study Participant Dashboard" } }
-- @route.description "The dashboard presents key study details and participant-specific metrics in a clear, organized table format"


${paginate("participant_dashboard_cached")}

SELECT
'datagrid' AS component; 

SELECT
    'Study Name' AS title,
    '' || study_name || '' AS description
FROM
    drh_study_vanity_metrics_details;

SELECT
    'Start Date' AS title,
    '' || start_date || '' AS description
FROM
    drh_study_vanity_metrics_details;

SELECT
    'End Date' AS title,
    '' || end_date || '' AS description
FROM
    drh_study_vanity_metrics_details;

SELECT
    'NCT Number' AS title,
    '' || nct_number || '' AS description
FROM
    drh_study_vanity_metrics_details;




SELECT
   'card'     as component,
   '' as title,
    4         as columns;

SELECT
   'Total Number Of Participants' AS title,
   '' || total_number_of_participants || '' AS description
FROM
    drh_study_vanity_metrics_details;

SELECT

    'Total CGM Files' AS title,
   '' || number_of_cgm_raw_files || '' AS description
FROM
  drh_number_cgm_count;



SELECT
   '% Female' AS title,
   '' || percentage_of_females || '' AS description
FROM
    drh_study_vanity_metrics_details;


SELECT
   'Average Age' AS title,
   '' || average_age || '' AS description
FROM
    drh_study_vanity_metrics_details;




SELECT
'datagrid' AS component;


SELECT
    'Study Description' AS title,
    '' || study_description || '' AS description
FROM
    drh_study_vanity_metrics_details;

    SELECT
    'Study Team' AS title,
    '' || investigators || '' AS description
FROM
    drh_study_vanity_metrics_details;


    SELECT
   'card'     as component,
   '' as title,
    1         as columns;

    SELECT
    'Device Wise Raw CGM File Count' AS title,
    GROUP_CONCAT(' ' || devicename || ': ' || number_of_files || '') AS description
    FROM
        drh_device_file_count_view;

    
    ${paginate("participant_dashboard_cached")}


  
  SELECT 'table' AS component,
        'participant_id' as markdown,
        TRUE AS sort,
        TRUE AS search;        
--   SELECT tenant_id,format('[%s]('||sqlpage.environment_variable('SQLPAGE_SITE_PREFIX') || '/drh/participant-info.sql?participant_id='||'%s)',
    SELECT tenant_id,${md.link("participant_id", [`'participant-info.sql?participant_id='`, "participant_id"])} as participant_id,gender,age,study_arm,baseline_hba1c,cgm_devices,cgm_files,tir,tar_vh,tar_h,tbr_l,tbr_vl,tar,tbr,gmi,percent_gv,gri,days_of_wear,data_start_date,data_end_date FROM participant_dashboard_cached    
    order by participant_id
${pagination.limit}; 


${pagination.navigation}
;
```

## Researcher and Associated Information

```sql drh/researcher-related-data.sql{ route: { caption: "Researcher and Associated Information" } }
-- @route.description "This section provides detailed information about the individuals , institutions and labs involved in the research study."

SELECT 'text' AS component, $page_title AS title;

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

SELECT 'text' AS component, $page_title AS title;

${paginate("drh_cgmfilemetadata_view")}

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
SELECT * FROM drh_cgmfilemetadata_view
${pagination.limit}; 
${pagination.navigation}
        ;

```

## Combined CGM Tracing

```sql drh/cgm-combined-data.sql{ route: { caption: "Combined CGM Tracing" } }
-- @route.description "Explore the comprehensive CGM dataset, integrating glucose monitoring data from all participants for in-depth analysis of glycemic patterns and trends across the study."

SELECT 'text' AS component, $page_title AS title;

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

```sql drh/cgm-data.sql{ route: { caption: "Raw CGM Data Description" } }
-- @route.description "Explore detailed information about glucose levels over time, including timestamp, and glucose value."

SELECT 'text' AS component, $page_title AS title;

SELECT
'text' as component,
'
The raw CGM data includes the following key elements.

- **Date_Time**:
The exact date and time when the glucose level was recorded. This is crucial for tracking glucose trends and patterns over time. The timestamp is usually formatted as YYYY-MM-DD HH:MM:SS.
- **CGM_Value**:
The measured glucose level at the given timestamp. This value is typically recorded in milligrams per deciliter (mg/dL) or millimoles per liter (mmol/L) and provides insight into the participant''s glucose fluctuations throughout the day.' as contents_md;

SELECT 
    'table' AS component,
    'RAW FILES' AS markdown,
    TRUE AS sort,
    TRUE AS search;

SELECT 
    '[' || REPLACE(r.table_name, 'uniform_resource_', '') || '](cgm-data/raw-cgm/' || r.table_name || '.sql)' AS "RAW FILES"
FROM 
    drh_raw_cgm_table_lst AS r
JOIN 
    sqlpage_files AS f 
    ON f.path = 'drh/cgm-data/raw-cgm/' || r.table_name || '.sql'
ORDER BY 
    r.table_name;


```

## Meal Data

```sql drh/combined-meal-data.sql{ route: { caption: "Combined Meal Data" } }
-- @page.description "Detailed logs of dietary intake across all study participants, including meal type and calorie information."

SELECT 'text' AS component, $page_title AS title;

SELECT
'text' as component,
'
This page provides a consolidated, static view of the **Meal Data** stream collected during the study. These logs of dietary intake provide crucial context for understanding and analyzing continuous glucose fluctuations.
' as contents_md;


SELECT
    'text' as component,
    'The **Meal Data** section contains records of all logged dietary events, including meal type and calorie information, linked by participant ID.' as contents_md;


SELECT 'text' AS component,
    '**Total Meal Records:** ' || (SELECT COUNT(*) FROM combined_meal_metadata_cached )
    AS contents_md;


SELECT
    'alert' AS component,
    'Error' AS color,
    '✅ No Meal data found for the current study cohort.' AS title,
    'The Meal data table is empty.' AS description
WHERE (SELECT COUNT(*) FROM combined_meal_metadata_cached ) = 0;

SELECT 'table' AS component,
    TRUE AS sort,
    TRUE AS search
WHERE (SELECT COUNT(*) FROM combined_meal_metadata_cached ) > 0;

${paginate("combined_meal_metadata_cached")}
SELECT
    *
FROM
    combined_meal_metadata_cached
where
(SELECT COUNT(*) FROM combined_meal_metadata_cached ) > 0;
${pagination.limit};
${pagination.navigation};

```

## Fitness Data

```sql drh/combined-fitness-data.sql{ route: { caption: "Combined Fitness Data" } }
-- @page.description "Summary of physical activity metrics (steps, heart rate, distance) captured by tracking devices for all participants."

SELECT 'text' AS component, $page_title AS title;

SELECT
'text' as component,
'
This page provides a consolidated, static view of the **Fitness Data** stream collected during the study. These records of physical activity are a key behavioral factor influencing metabolism and glucose control.

' as contents_md;


SELECT
    'text' as component,
    'The **Fitness Data** section summarizes physical activity metrics (steps, heart rate, distance) captured by tracking devices for all participants.' as contents_md;


SELECT 'text' AS component,
    '**Total Fitness Records:** ' || (SELECT COUNT(*) FROM combined_fitness_metadata_cached )
    AS contents_md;


SELECT
    'alert' AS component,
    'Error' AS color,
    '✅ No Fitness data found for the current study cohort.' AS title,
    'The Fitness data table is empty.' AS description
WHERE (SELECT COUNT(*) FROM combined_fitness_metadata_cached ) = 0;

SELECT 'table' AS component,
    TRUE AS sort,
    TRUE AS search
WHERE (SELECT COUNT(*) FROM combined_fitness_metadata_cached) > 0;

${paginate("combined_fitness_metadata_cached")}
SELECT
    * FROM
    combined_fitness_metadata_cached
WHERE (SELECT COUNT(*) FROM combined_fitness_metadata_cached) > 0;
${pagination.limit};
${pagination.navigation};

```

## PHI De-Identification Results

```sql drh/deidentification-log.sql{ route: { caption: "PHI De-Identification Results" } }
-- @route.description "Explore the results of PHI de-identification and review which columns have been modified."

SELECT
  'text' as component,
  'DeIdentification Results' as title;
 SELECT
  'The DeIdentification Results section provides a view of the outcomes from the de-identification process ' as contents;


SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
SELECT input_text as "deidentified column", orch_started_at,orch_finished_at ,diagnostics_md from drh_vw_orchestration_deidentify;


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

```sql drh/participant-info.sql
-- @route.caption "Participant Information"
-- @route.description "The Participants Detail page is a comprehensive report that includes glucose statistics, such as the Ambulatory Glucose Profile (AGP), Glycemia Risk Index (GRI), Daily Glucose Profile, and all other metrics data."
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
     "/drh/chart/daily-gluecose-profile/index.sql?_sqlpage_embed&participant_id=" || $participant_id as embed;  
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

```sql drh/chart/daily-gluecose-profile/index.sql
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
