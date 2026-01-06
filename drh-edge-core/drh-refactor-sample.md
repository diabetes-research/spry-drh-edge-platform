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

```envrc prepare-env -C ./.envrc --gitignore --descr "Generate .envrc file and add it to local .gitignore if it's not already there"
export SPRY_DB="sqlite://resource-surveillance.sqlite.db?mode=rwc"
export PORT=9227
export STUDY_DATA_PATH="raw-data/dexcom-synthetic-cgm/"
export TENANT_ID="DSG"
export TENANT_NAME="DSG"
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
  - **surveilr** (latest release): [https://github.com/surveilr/packages/releases](https://github.com/surveilr/packages/releases)  
  
- Place the study data files in a **directory** in the same path as this markdown, then run the following command:
  - ` spry rb task prepare-db drh-refactor-sample.md `
- The `prepare-db` task, requires the **`$STUDY_DATA_PATH`**, **`${TENANT_ID}`**, and **`${TENANT_NAME}`** as parameters which are provided through env.
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

## SQLPage Dev / Watch mode

While you're developing, Spry's `dev-src.auto` generator should be used:

```bash  
spry sp spc --fs dev-src.auto --destroy-first --conf sqlpage/sqlpage.json -m drh-refactor-sample.md
```

```bash  clean --graph special --silent --descr "Clean up the project directory's generated artifacts"
rm -rf dev-src.auto
rm -f *.sql   
```

In development mode, here’s the `--watch` convenience you can use so that
whenever you update `drh-refactor-sample.md`, it regenerates the SQLPage `dev-src.auto`,
which is then picked up automatically by the SQLPage server:

```bash
spry sp spc  --fs dev-src.auto --destroy-first --conf sqlpage/sqlpage.json --watch --with-sqlpage -m drh-refactor-sample.md 
```

- `--watch` turns on watching all `--md` files passed in (defaults to `Spryfile.md`)
- `--with-sqlpage` starts and stops SQLPage after each build

Restarting SQLPage after each re-generation of dev-src.auto is **not**
necessary, so you can also use `--watch` without `--with-sqlpage` in one
terminal window while keeping the SQLPage server running in another terminal
window.

If you're running SQLPage in another terminal window, use:

```bash
spry sp spc  --fs dev-src.auto --destroy-first --conf sqlpage/sqlpage.json --watch -m drh-refactor-sample.md 
```

## SQLPage single database deployment mode

After development is complete, the `dev-src.auto` can be removed and
single-database deployment can be used:

```bash
#!/usr/bin/env -S bash
rm -rf dev-src.auto
echo "DRH EDGE UI Build is in progress............."
spry sp spc --package --conf sqlpage/sqlpage.json -m drh-refactor-sample.md | sqlite3 resource-surveillance.sqlite.db  
echo "Data Pipeline and UI Build complete..."
echo "DRH EDGE UI will be available at http://localhost:9227/"
```

## Layout

This cell instructs Spry to automatically inject the SQL `PARTIAL` into all
SQLPage content cells. The name `global-layout.sql` is not significant (it's
required by Spry but only used for reference), but the `--inject **/*` argument
is how matching occurs. The `--BEGIN` and `--END` comments are not required by
Spry but make it easier to trace where _partial_ injections are occurring.

```sql PARTIAL global-layout.sql --inject *.sql --inject drh/*.sql

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

```contribute sqlpage_files --base sqlpage/templates --mode package
**/* templates --mime text/plain
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
                    ELSE 'The current data folder failed mandatory structural checks.'
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

```sql drh/pipeline-monitor.sql { route: { caption: "Data Orchestration Pipeline" } }

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
        ELSE 'orange' 
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
        ELSE 'orange' 
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

```sql drh/post-pipeline-research-dashboard.sql{ route: { caption: "Research Data Hub Dashboard" } }
-- 1. HEADER HERO
SELECT 'hero' AS component, 
    'Research Data Hub' AS title, 
    'Orchestration complete. All datasets are now synchronized, de-identified, and ready for analysis.' AS description,
    'teal' AS color;

-- 2. KEY METRICS (Big Number component)
-- This shows the user that the pipeline actually DID something
SELECT 'big_number' AS component, 4 AS columns;
SELECT 'Participants' AS title, (SELECT COUNT(*) FROM drh_participant) AS value, 'users' AS icon, 'teal' AS color;
SELECT 'CGM Records' AS title, (SELECT COUNT(*) FROM combined_cgm_tracing_cached) AS value, 'chart-dots' AS icon, 'azure' AS color;
SELECT 'Health Alerts' AS title, '0' AS value, 'shield-check' AS icon, 'green' AS color;

-- 3. CORE RESEARCH FEATURES (Using 'card' but with 'teal' theme)
SELECT 'card' AS component, 'Research Insights & Feature Sets' AS title, 3 AS columns;

SELECT 'Participant Dashboard' AS title, '/drh/study-participant-dashboard.sql' AS link,
       'Participant-specific metrics and master study details.' AS description,
       'users' AS icon, 'teal' AS color;

SELECT 'Combined CGM Tracing' AS title, '/drh/cgm-combined-data.sql' AS link,
       'Aggregated glycemic patterns across the entire study.' AS description,
       'chart-line' AS icon, 'teal' AS color;

SELECT 'Combined Meal Data' AS title, '/drh/combined-meal-data.sql' AS link,
       'Dietary intake logs and post-prandial timestamps.' AS description,
       'apple' AS icon, 'teal' AS color;

-- 4. SYSTEM LOGS (Using a 'list' component for a cleaner feel than cards)
-- This separates "Data" from "Logs" visually
SELECT 'list' AS component, 'Data Integrity & Diagnostics' AS title;

SELECT 'Study Files Ingestion Log' AS title, '/drh/ingestion-log.sql' AS link,
       'Accepted files and database conversion status.' AS description,
       'database-import' AS icon, 'azure' AS color;

SELECT 'Data Validation Log' AS title, '/drh/verification-validation-log.sql' AS link,
       'Quality issues and corrective actions.' AS description,
       'shield-check' AS icon, 'azure' AS color;

SELECT 'PHI De-Identification Log' AS title, '/drh/deidentification-log.sql' AS link,
       'Audit of PII masking results.' AS description,
       'lock-check' AS icon, 'azure' AS color;

-- 5. SUPPORTING METADATA (Grid of 4 for compact view)
SELECT 'card' AS component, 'Supporting Metadata' AS title, 4 AS columns;

SELECT 'Researchers' AS title, '/drh/researcher-related-data.sql' AS link, 'Institutions & Labs.' AS description, 'building-community' AS icon, 'gray' AS color;
SELECT 'Study Sites' AS title, '/drh/study-related-data.sql' AS link, 'Site-specific details.' AS description, 'map-pin' AS icon, 'gray' AS color;
SELECT 'Demographics' AS title, '/drh/participant-related-data.sql' AS link, 'Participant backgrounds.' AS description, 'user-circle' AS icon, 'gray' AS color;
SELECT 'Publications' AS title, '/drh/author-pub-data.sql' AS link, 'Authors & Dissemination.' AS description, 'news' AS icon, 'gray' AS color;
```
