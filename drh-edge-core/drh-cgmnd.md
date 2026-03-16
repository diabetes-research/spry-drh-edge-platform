---
sqlpage-conf:
  database_url: "sqlite://resource-surveillance.sqlite.db?mode=rwc"
  web_root: "./dev-src.auto"
  allow_exec: true
  port: 9228
---

# CGMND Research Data Hub (DRH) SQLPage Application

This script automates the conversion of raw CGMND research data into a structured SQLite database and deploys a monitoring UI.

- Uses Spry to manage tasks and generate the SQLPage presentation layer.
- `surveilr` tool performs CSV ingestion and transformation using a specialized Singer tap.
- Uses DuckDB via `surveilr` for high-performance data transformation and validation.
- Final data is persisted in a SQLite database for the SQLPage UI.

## Spry Axiom Configuration

```code DEFAULTS
sql * --interpolate --injectable
```

## Setup & Environment

This project reads configuration from environment variables. Ensure your `.env` file at the root contains the following:

```envrc prepare-env -C ./.env --gitignore -X  --descr "Generate .envfile for CGMND"
OTEL_SERVICE_NAME="tap-cgmnd" 
OTEL_SERVICE_VERSION="1.0.0"
STUDY_DATA_PATH="raw-data/cgmnd-table-data/"
TENANT_ID="CGMND"
TENANT_NAME="CGMND Study"
```

## Core Pipeline Task

Run this task to ingestion data and start the server:
`spry rb task prepare-db-deploy-server drh-cgmnd.md`

```bash prepare-db-deploy-server   --descr "Cleanup, Ingestion via tap-cgmnd, ETL, and SQLPage deployment."
#!/bin/bash
set -u
# --- SOURCING THE ENVIRONMENT ---
if [ -f ".env" ]; then
    set -a
    source ".env"
    set +a
    echo "DEBUG: Environment sourced from $(pwd)/.env"
else
    echo "WARN: .env file not found in $(pwd)"
fi

# 1. Cleanup
rm -f resource-surveillance.sqlite.db 
rm -rf dev-src.auto 

# 2. Ingest via CGMND Singer Tap
# Note: Using the specific CGMND tap developed for scalability
surveilr ingest files -r singer-tap/tap-cgmnd.surveilr\[singer\].py

# 3. Extract Views & Validation
surveilr shell common-sql/drh-data-extraction.sql  
RAW_STATUS=$(surveilr shell "select overall_status from drh_vv_session_summary DESC LIMIT 1;")
VALIDATION_STATUS=$(echo "$RAW_STATUS" | jq -r '.[0].overall_status')

# 4. Conditional ETL
if [ "$VALIDATION_STATUS" == "PASS" ]; then    
    surveilr shell common-sql/drh-data-etl.sql        
else
    echo "Validation FAILED ($VALIDATION_STATUS). Skipping ETL steps."    
fi

# 5. Initialize SQLPage UI
spry sp spc --package --conf sqlpage/sqlpage.json -m drh-cgmnd.md | sqlite3 resource-surveillance.sqlite.db
```

```bash  clean --graph special --silent --descr "Clean up generated artifacts"
rm -rf dev-src.auto
rm -f *.sql   
```

## Layout & Styling

```sql PARTIAL global-layout.sql --inject *.sql --inject drh/*.sql
SELECT 'shell' AS component,
       'CGMND Research Hub Edge' AS title,
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

## Home Page

```sql index.sql { route: { caption: "Home" } }
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
                    ELSE 'Action Needed'
                END || 
            '</div>' ||
            '<div style="color: #64748b; margin-top: 4px;">' ||
                CASE overall_status
                    WHEN 'PASS'    THEN 'CGMND data is harmonized and ready.'
                    ELSE 'Please review the diagnostics report for ingestion errors.'
                END || 
            '</div>' ||
        '</div>' ||
        '<div style="font-size: 2.5rem;">' ||
             CASE overall_status WHEN 'PASS' THEN '🛡️' ELSE '🚨' END || 
        '</div>' ||
    '</div>' AS html
FROM drh_vv_session_summary WHERE health_category = 'DATA_CONTENT_CHECK';

SELECT 'button' AS component, 'center' AS justify;
SELECT 'Launch Dashboard' AS title, '/drh/research-dashboard.sql' AS link, 'circle-chevrons-right' AS icon, 'teal' AS color
FROM drh_vv_session_summary WHERE overall_status = 'PASS' AND health_category = 'DATA_CONTENT_CHECK';

SELECT 'hero' as component, 'CGMND Research Hub' as title, 'Edge UI for Scalable CGM Data Management' as subtitle;
```

## Research Dashboard

```sql drh/research-dashboard.sql{ route: { caption: "Research Data Dashboard" } }
SELECT 'hero' AS component, 'Research Data Dashboard' AS title, 'Precision analytics for CGMND study activity.' AS description, 'teal' AS color;

SELECT 'datagrid' AS component;
SELECT 'Study Name' AS title, study_name AS description FROM drh_study_vanity_metrics_details;
SELECT 'NCT ID' AS title, nct_number AS description FROM drh_study_vanity_metrics_details;

SELECT 'big_number' AS component, 3 AS columns;
SELECT 'Participants' AS title, (SELECT total_number_of_participants FROM drh_study_vanity_metrics_details) AS value, 'users' AS icon, 'teal' AS color;
SELECT 'CGM Files' AS title, (SELECT number_of_cgm_raw_files FROM drh_number_cgm_count) AS value, 'file-analytics' AS icon, 'azure' AS color;
SELECT 'Avg Age' AS title, (SELECT average_age || ' yrs' FROM drh_study_vanity_metrics_details) AS value, 'calendar-stats' AS icon, 'indigo' AS color;

SELECT 'card' AS component, 'Research Insight Modules' AS title, 2 AS columns;
SELECT 'Participant Metrics' AS title, '/drh/study-participant-dashboard.sql' AS link, 'Clinical metrics: TIR, GMI, and wear-time.' AS description, 'layout-dashboard' AS icon;
SELECT 'Combined CGM Tracing' AS title, '/drh/cgm-combined-data.sql' AS link, 'Exploratory trend analysis of time-series data.' AS description, 'chart-line' AS icon;

SELECT 'card' AS component, 'System & Audit Logs' AS title, 2 AS columns;
SELECT 'Ingestion Log' AS title, '/drh/ingestion-log.sql' AS link, 'Audit trail of raw CSV files accepted.' AS description, 'database-import' AS icon;
SELECT 'Diagnostics Report' AS title, '/drh/diagnostics-report.sql' AS link, 'Detailed trace of validation rules and errors.' AS description, 'shield-check' AS icon;
```

## Diagnostics Report

```sql drh/diagnostics-report.sql { route: { caption: "Diagnostics Report" } }
SELECT 'title' AS component, 'Observability Diagnostics' AS contents;
SELECT 'Duration' as title, duration as description, 'clock' as icon FROM drh_vv_session_summary WHERE health_category = 'DATA_CONTENT_CHECK';
SELECT 'table' AS component, 'Evidence Trace' AS title;
SELECT span_name AS "Check", evidence AS "Finding", status AS "Status" FROM drh_vv_hierarchy WHERE lvl > 1;
```

## Ingestion Log

```sql drh/ingestion-log.sql { route: { caption: "Raw Data Ingestion Log" } }
SELECT 'title' AS component, 'Data Stream Ingestion Audit' AS contents;
SELECT 'Raw CGM File Count' AS title, COUNT(*) || ' files' AS description FROM drh_raw_cgm_tracing;
SELECT 'table' AS component, 'Ingested Files' AS title;
SELECT raw_file_name AS "File Name", 'CGM' AS "Stream" FROM drh_raw_cgm_tracing;
```

## Participant Dashboard

```sql drh/study-participant-dashboard.sql{ route: { caption: "Study Participant Dashboard" } }
SELECT 'title' AS component, 'Study Participant Metrics' AS contents;
SELECT 'table' AS component, TRUE AS sort, TRUE AS search, 'Clinical Outcomes' AS title;
SELECT participant_id, gender, age, study_arm, tir AS "TIR %", gmi AS GMI, days_of_wear AS "Days Wear" FROM participant_dashboard_cached;
```
