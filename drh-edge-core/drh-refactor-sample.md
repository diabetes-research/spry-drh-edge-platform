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

## DRH EDGE  Home Page

Index page which automatically generates links to all `/drh` pages.

```sql index.sql { route: { caption: "DRH Edge UI Home" } }

WITH latest_report AS (
    SELECT report_json ,overall_status,tenant_name,folder_name
    FROM validation_reports 
    ORDER BY timestamp DESC 
    LIMIT 1
)
SELECT 
    'variables' AS component,
    overall_status AS status,
    folder_name AS folder,
    tenant_name AS tenant,
    (SELECT count(*) FROM diagnostics WHERE status = 'FAIL') AS total_errors
FROM latest_report;

---
-- 2. HERO BRANDING (No Image - Clean Layout)
---
SELECT 'hero' AS component,
      'DRH Edge: ' || $tenant AS title,
      'Source Folder: ' || $folder AS subtitle;

---
-- 3. OVERALL HEALTH ALERT
---
SELECT 'alert' AS component,
    CASE WHEN $status = 'PASS' THEN 'green' ELSE 'red' END AS color,
    CASE WHEN $status = 'PASS' THEN 'check' ELSE 'alert-circle' END AS icon,
    'System Health: ' || $status AS title,
    CASE WHEN $status = 'PASS' 
         THEN 'All checks passed. Data orchestration is unlocked and ready.' 
         ELSE 'Found ' || COALESCE($total_errors, 0) || ' critical issues. Orchestration is locked.' 
    END AS description;

-- 6. SECONDARY LOGS (Always available)
SELECT 'card' AS component, 'System Exploration' AS title, 2 AS columns;

SELECT 'Ingestion Log' AS title, '/drh/ingestion-log.sql' AS link, 
       'View raw file conversion status' AS description, 'book' AS icon;

SELECT 'Verification Log' AS title, '/drh/verification-validation-log.sql' AS link, 
       'Content-level data issues' AS description, 'list-check' AS icon;
```

## orchestration page

```sql orchestration.sql { route: { caption: "Surveilr orchestration" } }
-- Show a spinner/hero while the CLI runs
SELECT 'hero' AS component, 'Processing' AS title, 'Running surveilr orchestrate transform-csv...' AS subtitle;

-- Execute the command
SELECT 'shell' AS component, 'exec' AS command, 
       'surveilr' AS argument, 'orchestrate' AS argument, 'transform-csv' AS argument;

-- Redirect back to index with a success toast
SELECT 'redirect' AS component, 'index.sql?message=Transformation Complete&type=success' AS link;
```