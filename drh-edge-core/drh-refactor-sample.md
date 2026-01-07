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

### Pipeline & Study Configuration

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

```envrc prepare-env -C ./.envrc --gitignore -X --descr "Generate .envrc file and add it to local .gitignore if it's not already there"
export SPRY_DB="sqlite://resource-surveillance.sqlite.db?mode=rwc"
export PORT=9227
export STUDY_DATA_PATH="raw-data/simplera-synthetic-cgm/"
export TENANT_ID="FLCG"
export TENANT_NAME="Florida Clinical Group"
direnv allow
```

Then run `direnv allow` in this project directory to load the `.envrc` into your shell environment. direnv will evaluate `.envrc` only after you explicitly allow it.

-----

## Security and repository hygiene

- Never commit secrets or production credentials into `.envrc`. Treat `.envrc` like a local-only file.
- Add `.envrc` to your local `.gitignore` if you keep secrets there. Alternatively commit a `.envrc.example` or `.envrc.sample` with safe, non-secret defaults to document expected variables.
- The SQLite file (e.g. `resource-surveillance.sqlite.db`) is a binary database file — you will usually not check this into version control. Add that filename or the `data/` directory to `.gitignore` as well.

Why these variables matter here

- The YAML header at the top of this `drh-refactor-sample.md` reads `database_url: ${env.SPRY_DB}` and `port: ${env.PORT}` — Spry and the SQLPage tooling will substitute those environment values when building or serving the site.
- The `diagnostics-check` task explicitly checks for `STUDY_DATA_PATH`, `TENANT_ID`, and `TENANT_NAME` and will halt if any are missing.
- If `SPRY_DB` is not set, the tooling may fail to find the database or fall back to defaults; explicitly setting it ensures predictable, repeatable dev runs.

Quick troubleshooting

- If the server does not start on the expected port, verify `echo $PORT` (or `echo $SPRY_DB`) in your shell to confirm values are loaded.
- If direnv appears not to load `.envrc`, re-run `direnv allow` and ensure your shell config contains the direnv hook.

### Instructions

### Prepare Study Data and Dependencies

- Prepare your research data files according to the formats described on the **official DRH Website**: [https://drh.diabetestechnology.org/organize-cgm-data](https://drh.diabetestechnology.org/organize-cgm-data).
- Ensure your study data files are placed in the directory specified by **`$STUDY_DATA_PATH`**.
- Install the required tools and dependencies:
  - **surveilr** (latest release): [https://github.com/surveilr/packages/releases](https://github.com/surveilr/packages/releases)  
  
- Place the study data files in a **directory** in the same path as this markdown, then run the following command:
  - ` spry rb task diagnostics-check drh-refactor-sample.md `
- The `diagnostics-check` task, requires the **`$STUDY_DATA_PATH`**, **`${TENANT_ID}`**, and **`${TENANT_NAME}`** as parameters which are provided through env.
- This step cleans up old files, validates data ,performs a pre-etl-validation , performs ingestion, and runs all complex DuckDB transformations, generating the final resource-surveillance.sqlite.db file.

```bash diagnostics-check  --descr "Performs pre-etl-validation "
#!/bin/bash
# Define variables for clarity (assuming they are set by Spry/environment)
STUDY_DATA_PATH="${STUDY_DATA_PATH}"
TENANT_ID="${TENANT_ID}"
TENANT_NAME="${TENANT_NAME}"
TOOL_CMD="surveilr"
# 2. Cleanup
rm -f resource-surveillance.sqlite.db
rm -f *.sql
rm -rf dev-src.auto 
"${TOOL_CMD}" ingest files -r "${STUDY_DATA_PATH}" --tenant-id "${TENANT_ID}" --tenant-name "${TENANT_NAME}"
"${TOOL_CMD}" shell --engine duckdb duckdb-etl-sql/drh-preflight-validation.sql
"${TOOL_CMD}" shell common-sql/drh-pipeline.sql
spry sp spc --package --conf sqlpage/sqlpage.json -m drh-refactor-sample.md | sqlite3 resource-surveillance.sqlite.db  
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

-- 1. HERO SECTION: The Product "Hook"
SELECT 
    'hero' as component,
    'Diabetes Research Hub' as title,
    'The Edge UI for Centralized CGM Data Management' as subtitle,
    'The DRH platform empowers researchers to harmonize, validate, and analyze continuous glucose monitor data with clinical precision.' as description,
    'https://images.unsplash.com/photo-1576091160550-2173dba999ef?auto=format&fit=crop&w=1000&q=80' as image,
    'teal' as color;

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

-- 3. STATUS DISPLAY (The White/Green Border Design)
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
                    WHEN 'PASS'    THEN 'Your data is clean and ready for transformation.'
                    WHEN 'WARNING' THEN 'Data passed but found minor schema inconsistencies.'
                    ELSE 'Please correct your folder and files and try again. Check the diagnostic report for specific error details.'
                END || 
            '</div>' ||
        '</div>' ||
        '<div style="font-size: 2.5rem;">' ||
             CASE overall_status WHEN 'PASS' THEN '🛡️' WHEN 'WARNING' THEN '⚠️' ELSE '🚨' END || 
        '</div>' ||
    '</div>' AS html
FROM drh_validation_reports ORDER BY timestamp DESC LIMIT 1;

-- 4. ACTION CENTER (Product-style Buttons)
SELECT 'button' AS component, 'center' AS justify;

-- Primary Action (If Success)
SELECT 
    'Launch Data Orchestration' AS title,
    '/drh/pipeline-monitor.sql' AS link,
    'player-play-filled' AS icon,
    'teal' AS color,
    'outline' AS variant
FROM drh_validation_reports WHERE overall_status = 'PASS' ORDER BY timestamp DESC LIMIT 1;

SELECT 
    'Review Error Details' AS title,
    '/drh/diagnostics-report.sql' AS link,
    'alert-circle' AS icon,
    'red' AS color
FROM drh_validation_reports WHERE overall_status <> 'PASS' ORDER BY timestamp DESC LIMIT 1;

-- Detailed Report (Always available, but looks like a "Secondary" product action)
SELECT 
    'Explore Diagnostics' AS title,
    '/drh/diagnostics-report.sql' AS link,
    'database-search' AS icon,
    'azure' AS color;
```

## Diagnostics Report

```sql drh/diagnostics-report.sql { route: { caption: "Diagnostics Report" } }
-- @route.description "Detailed diagnostic Report."

SELECT 'html' AS component;

WITH latest_report AS (
    SELECT report_json 
    FROM drh_validation_reports 
    ORDER BY timestamp DESC 
    LIMIT 1
),
counts AS (
    SELECT 
        SUM(CASE WHEN json_extract(value, '$.status') = 'PASS' THEN 1 ELSE 0 END) as pass_count,
        SUM(CASE WHEN json_extract(value, '$.status') = 'WARNING' THEN 1 ELSE 0 END) as warn_count,
        SUM(CASE WHEN json_extract(value, '$.status') = 'FAIL' THEN 1 ELSE 0 END) as fail_count
    FROM latest_report, json_each(latest_report.report_json, '$.results')
)
SELECT 
    -- Change: justify-content: space-evenly and max-width: 100%
    '<div style="display: flex; justify-content: space-evenly; align-items: center; padding: 15px; background: rgba(255, 255, 255, 0.9); backdrop-filter: blur(10px); border-radius: 16px; border: 1px solid rgba(233, 236, 239, 0.6); box-shadow: 0 4px 15px rgba(0,0,0,0.05); margin: 20px 0; width: 100%; max-width: 100%;">' ||
        
        -- Passed Pill (Compact)
        '<div style="flex: 0 1 180px; background: #f0fdf4; color: #166534; padding: 8px 12px; border-radius: 10px; font-weight: 600; display: flex; align-items: center; justify-content: center; gap: 8px; border: 1px solid #dcfce7;">' ||
            '<span style="height: 8px; width: 8px; background-color: #22c55e; border-radius: 50%; box-shadow: 0 0 6px #22c55e;"></span>' || 
            '<span style="font-size: 1rem;">' || pass_count || '</span> <span style="font-size: 0.8rem; opacity: 0.8;">Passed</span>' ||
        '</div>' ||
        
        -- Warning Pill (Compact)
        '<div style="flex: 0 1 180px; background: #ecfeff; color: #0e7490; padding: 8px 12px; border-radius: 10px; font-weight: 600; display: flex; align-items: center; justify-content: center; gap: 8px; border: 1px solid #cffafe;">' ||
            '<span style="height: 8px; width: 8px; background-color: #06b6d4; border-radius: 50%; box-shadow: 0 0 6px #06b6d4;"></span>' || 
            '<span style="font-size: 1rem;">' || warn_count || '</span> <span style="font-size: 0.8rem; opacity: 0.8;">Warnings</span>' ||
        '</div>' ||
        
        -- Critical Pill (Compact)
        '<div style="flex: 0 1 180px; background: #fff1f2; color: #9f1239; padding: 8px 12px; border-radius: 10px; font-weight: 600; display: flex; align-items: center; justify-content: center; gap: 8px; border: 1px solid #ffe4e6;">' ||
            '<span style="height: 8px; width: 8px; background-color: #f43f5e; border-radius: 50%; box-shadow: 0 0 6px #f43f5e;"></span>' || 
            '<span style="font-size: 1rem;">' || fail_count || '</span> <span style="font-size: 0.8rem; opacity: 0.8;">Critical</span>' ||
        '</div>' ||
        
    '</div>' AS html
FROM counts;

-- 3. THE INSPECTION LOG
-- We use a divider to separate the summary from the granular data
SELECT 'divider' AS component, 'Granular Validation Logs' AS contents;

SELECT 
    'list' AS component,
    'Detailed Diagnostics' AS title;

SELECT     
    -- Using the soothing palette
    CASE json_extract(j.value, '$.status')
        WHEN 'FAIL' THEN 'pink'
        WHEN 'WARNING' THEN 'cyan'
        ELSE 'teal' 
    END AS color,    
    -- Icon Logic
    CASE         
        WHEN json_extract(j.value, '$.check') LIKE 'Folder%' THEN 'folder'
        WHEN json_extract(j.value, '$.check') LIKE 'File Format & Mandatory Files Existence' THEN 'folder-check'
        WHEN json_extract(j.value, '$.check') LIKE '%Files Existence%' THEN 'file-check'
        WHEN json_extract(j.value, '$.check') LIKE 'File Schema Check%' THEN 'file-stack'        
        WHEN json_extract(j.value, '$.check') LIKE '%Data Integrity%' THEN 'brand-databricks'
        ELSE 'info-circle'
    END AS icon,    
    json_extract(j.value, '$.check') AS title,    
    IFNULL(json_extract(j.value, '$.details'), 'No details provided.') AS description,
    -- This creates a small "tag" effect on the right side
    json_extract(j.value, '$.status') AS link_text
FROM 
    (SELECT report_json FROM drh_validation_reports ORDER BY timestamp DESC LIMIT 1) AS t,
    json_each(t.report_json, '$.results') AS j
ORDER BY 
    CASE json_extract(j.value, '$.status')
        WHEN 'FAIL' THEN 1 
        WHEN 'WARNING' THEN 2 
        ELSE 3 
    END;

```

## Pipleline Monitor

```sql drh/pipeline-monitor.sql { route: { caption: "Data Orchestration Pipeline"} }

-- 1. Check if everything is succeeded
SET all_done = (SELECT COUNT(*) FROM drh_pipeline_steps WHERE status != 'succeeded');


-- 3. Hero Section (Professional Teal Theme)
SELECT 'hero' AS component, 
    'Data Orchestration' AS title, 
    'Securely processing and validating medical research data.' AS description,
    'teal' AS color;

-- 4. Visual Progress Bar (Using Indigo for the "Ready" state)
SELECT 'steps' AS component, TRUE AS counter;
SELECT 
    name AS title,
    CASE status 
        WHEN 'succeeded' THEN 'Succeeded' 
        WHEN 'failed' THEN 'Failed'
        WHEN 'pending' THEN 'Waiting'
        ELSE 'Processing...' 
    END AS description,
    CASE status 
        WHEN 'succeeded' THEN 'greeen' 
        WHEN 'failed' THEN 'red' 
        WHEN 'pending' THEN 'teal' 
        ELSE 'cyan' 
    END AS color,
    status = 'succeeded' AS completed
FROM drh_pipeline_steps 
ORDER BY step;

-- 5. Detailed Status Cards
SELECT 'card' AS component, 3 AS columns;
SELECT 
    name AS title,
    'Pipeline status: ' || status AS description,
    CASE status 
        WHEN 'succeeded' THEN 'shield-check'   -- More "verified" look
        WHEN 'failed' THEN 'alert-triangle'     -- High visibility error
        WHEN 'pending' THEN 'hourglass-empty'   -- Waiting to start
        ELSE 'microscope' 
    END AS icon,
    CASE status 
        WHEN 'succeeded' THEN 'green' 
        WHEN 'failed' THEN 'red' 
        WHEN 'pending' THEN 'teal' 
        ELSE 'cyan' 
    END AS color,
    CASE 
        WHEN completed_at IS NOT NULL THEN 'Completed at: ' || completed_at
        WHEN started_at IS NOT NULL THEN 'Started at: ' || started_at 
        ELSE 'Queue Position: ' || step 
    END AS footer
FROM drh_pipeline_steps;

-- 6. Central Action Button
SELECT 'divider' AS component;

SELECT 'button' AS component, 'center' AS justify;
SELECT 
    'Execute ' || name AS title,
    '/drh/pipeline/trigger-step' || step || '.sql' AS link,
    'bolt' AS icon,
    'teal' AS color
FROM drh_pipeline_steps 
WHERE status = 'pending' 
ORDER BY step LIMIT 1;

SELECT
    'Proceed to Research Data Dashboard' AS title,
    '/drh/post-pipeline-research-dashboard.sql' AS link,
    'arrow-right' AS icon,
    'green' AS color
WHERE $all_done = 0;
```

## Pipeline Step

```sql drh/pipeline/trigger-step1.sql { route: { caption: "Data transformation pipeline" } }
-- 1. Run the update and the shell command in a single 'hidden' step
SET result = (
  SELECT sqlpage.exec('surveilr', 'orchestrate', 'transform-csv')
);

-- 2. Update the status now that the command above is finished
UPDATE drh_pipeline_steps 
SET status = 'succeeded', started_at = datetime('now', 'localtime'),
    completed_at = datetime('now', 'localtime') 
WHERE step = 1;

-- 3. NOW the redirect will work because it is the first 'component' sent
SELECT 'redirect' AS component, '/drh/pipeline-monitor.sql' AS link;
```

```sql drh/pipeline/trigger-step2.sql { route: { caption: "Data Validation pipeline" } }

SET result = (
  SELECT sqlpage.exec('surveilr', 'shell', 'common-sql/drh-data-validation.sql')
);


UPDATE drh_pipeline_steps 
SET status = 'succeeded', 
    started_at = CURRENT_TIMESTAMP,
    completed_at = CURRENT_TIMESTAMP 
WHERE step = 2;


SELECT 'redirect' AS component, '/drh/pipeline-monitor.sql' AS link;

```

```sql drh/pipeline/trigger-step3.sql { route: { caption: "Data Anonymization pipeline" } }
SET result = (
SELECT sqlpage.exec('surveilr', 'shell', 'common-sql/drh-anonymize-prepare.sql')
);

UPDATE drh_pipeline_steps 
SET status = 'succeeded', 
    started_at = CURRENT_TIMESTAMP,
    completed_at = CURRENT_TIMESTAMP 
WHERE step = 3;
SELECT 'redirect' AS component, '/drh/pipeline-monitor.sql' AS link;
```

```sql drh/pipeline/trigger-step4.sql { route: { caption: "Data ETL pipeline" } }
SET result = (
SELECT sqlpage.exec('surveilr', 'shell', '--engine', 'duckdb', 'duckdb-etl-sql/drh-master-etl.sql'))
;
UPDATE drh_pipeline_steps 
SET status = 'succeeded', 
    started_at = CURRENT_TIMESTAMP,
    completed_at = CURRENT_TIMESTAMP 
WHERE step = 4;
SELECT 'redirect' AS component, '/drh/pipeline-monitor.sql' AS link;
```

```sql drh/pipeline/trigger-step5.sql { route: { caption: "Data Metrics pipeline" } }
SET result = (
SELECT sqlpage.exec('surveilr', 'shell', 'common-sql/drh-metrics-pipeline.sql') 
);
UPDATE drh_pipeline_steps 
SET status = 'succeeded', 
    started_at = CURRENT_TIMESTAMP,
    completed_at = CURRENT_TIMESTAMP 
WHERE step = 5;
SELECT 'redirect' AS component, '/drh/pipeline-monitor.sql' AS link;
```

## Post Pipeline Research Dashboard

```sql drh/post-pipeline-research-dashboard.sql{ route: { caption: "Research Data Dashboard" } }
-- 1. BRANDING HERO
SELECT 'hero' AS component, 
    'Research Data Hub' AS title, 
    'Precision analytics platform for synchronized glycemic, nutritional, and metabolic activity research.' AS description,
    'teal' AS color;

-- 2. STUDY PROFILE SECTION
SELECT 'title' AS component, 
    (SELECT study_name FROM drh_study_vanity_metrics_details) AS contents,
    'Study Profile & Metadata' AS subtitle;

SELECT 'datagrid' AS component;
SELECT 'NCT ID' AS title, nct_number AS description FROM drh_study_vanity_metrics_details;
SELECT 'Clinical Investigators' AS title, investigators AS description FROM drh_study_vanity_metrics_details;
SELECT 'Timeline' AS title, start_date || ' to ' || end_date AS description FROM drh_study_vanity_metrics_details;

-- 3. STUDY DESCRIPTION
SELECT 'text' AS component, (SELECT study_description FROM drh_study_vanity_metrics_details) AS contents;

-- 4. DYNAMIC STUDY SNAPSHOT
SELECT 'big_number' AS component, 4 AS columns;
SELECT 'Participants' AS title, (SELECT total_number_of_participants FROM drh_study_vanity_metrics_details) AS value, 'users' AS icon, 'teal' AS color;
SELECT 'CGM Files' AS title, (SELECT number_of_cgm_raw_files FROM drh_number_cgm_count) AS value, 'file-analytics' AS icon, 'azure' AS color;
SELECT 'Avg Age' AS title, (SELECT average_age || ' yrs' FROM drh_study_vanity_metrics_details) AS value, 'calendar-stats' AS icon, 'indigo' AS color;
SELECT 'Gender Split' AS title, (SELECT percentage_of_females || '% Female' FROM drh_study_vanity_metrics_details) AS value, 'gender-femme' AS icon, 'teal' AS color;

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
    'binary' AS icon, 'teal' AS color;

-- 6. DIAGNOSTICS & SYSTEM AUDIT
SELECT 'card' AS component, 'File & Security Diagnostics' AS title, 3 AS columns;

SELECT 'Ingestion Log' AS title, '/drh/ingestion-log.sql' AS link,
    'Audit files accepted and converted into database format.' AS description,
    'database-import' AS icon, 'cyan' AS color;

SELECT 'Verification Log' AS title, '/drh/verification-validation-log.sql' AS link,
    'Quality review of file content and corrective actions taken.' AS description,
    'folder-check' AS icon, 'cyan' AS color;

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
-- 1. CLEAN HEADER (No more duplicated study description)
SELECT 'title' AS component, 
    'Study Participant Metrics' AS contents,
    'Clinical analysis and glycemic variability indicators' AS subtitle;

-- 2. COMPACT DEVICE SNAPSHOT (Using a single row card)
SELECT 'card' AS component, 1 AS columns;
SELECT 
    'Hardware Profile' AS title, 
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
(SELECT COUNT(*) FROM combined_meal_metadata_cached ) > 0
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
WHERE (SELECT COUNT(*) FROM combined_fitness_metadata_cached) > 0
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

