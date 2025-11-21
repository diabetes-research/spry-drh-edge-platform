# SPRY DRH EDGE PLATFORM

**End-to-end platform for Diabetes Research Hub (DRH) Edge data integration using Spry and SQLPage.**

## Overview

The **Diabetes Research Hub (DRH) SQLPage Application** is an ETL (Extract, Transform, Load) pipeline and web interface designed to process and visualize raw diabetes research data. This project automates the conversion of raw study files (e.g., CSV) into a structured **SQLite database** and uses the **Spry** framework to generate a user interface powered by **SQLPage**.

The goal is to provide a centralized platform for managing and analyzing continuous glucose monitor (CGM) data from research study.

-----

## 🌟 Features

The platform performs a complete workflow for converting raw diabetes research data (CGM, meal, fitness) into a structured SQLite database and presenting it via a rich, interactive web UI.

* **Pre-Validation Gate:** Checks file structure, metadata, and dependencies (Deno, surveilr). The pipeline halts if this step fails.
* **Data Conversion:** Automates the ingestion and conversion of raw study files (e.g., CSV) into a structured format using the `surveilr` tool.
* **DuckDB ETL:** Utilizes **DuckDB** for complex data transformation and integration, including combining CGM tracings and generating derived meal and fitness metadata.
* **SQLPage UI:** Generates a modern, interactive data dashboard using **SQLPage** powered by the resulting SQLite database.
* **Comprehensive Dashboards:** Includes dedicated pages for:
  * Study Participant Dashboard (metrics, demographics)
  * Combined CGM Tracing, Meal, and Fitness Data
  * Ingestion, Verification, and De-Identification Logs
  * Associated metadata (Researchers, Institutions, Devices)

-----

## 💻 Technology Stack

| Technology | Role |
| :--- | :--- |
| **Spry** | Manages the project tasks and generates the SQLPage presentation layer. |
| **SQLPage** | The core web application framework, using SQL to render dynamic web pages. |
| **surveilr** | Performs CSV file conversion and transformation into an RSSD (Research Study Data Database) format. |
| **DuckDB** | Utilized for complex data transformations and ETL operations. |
| **SQLite** | The final, structured database format used by SQLPage. |

-----

## 🛠️ Prerequisites & Setup

### Prerequisites

Ensure you have the following installed to run the platform:

1. **[Deno](https://deno.land/):** Used to run the Spry CLI tool (`spry.ts`).
2. **[Surveilr](https://github.com/surveilr/packages/releases):** The data-processing utility for file ingestion and orchestration.
3. **DuckDB**: Used within the data preparation scripts for ETL operations.
4. **SQLITE**: The final destination database engine used for data persistence and serving via SQLPage (specified by `$SPRY_DB`).
5. **direnv**: Recommended for managing environment variables easily.

### ⚙️ Installation Steps

Follow these steps to install the required tools on a Linux system.

#### 1. Install Deno

Deno is required to run the Spry CLI.

```bash
# Using the recommended installation script
curl -fsSL https://deno.land/x/install/install.sh | sh
# Ensure Deno is added to your PATH (the script usually suggests the line)
# Example: export PATH="$HOME/.deno/bin:$PATH"
```

#### 2. Install DuckDB (v1.4.1+)

DuckDB is used for complex ETL and data transformations.

```bash
# Download and install the latest stable version
wget https://github.com/duckdb/duckdb/releases/download/v1.4.1/duckdb_cli-linux-amd64.zip
unzip duckdb_cli-linux-amd64.zip
chmod +x duckdb
sudo mv duckdb /usr/local/bin/
```

#### 3. Install SQLite

SQLite is the final structured database used by SQLPage. On most systems, it can be installed via the package manager.

```bash
# For Debian/Ubuntu-based systems
sudo apt update
sudo apt install sqlite3 libsqlite3-dev
```

#### 4. Install Surveilr

Surveilr is the data-processing utility for file ingestion.The latest surveilr packages can be found [here.](https://github.com/surveilr/packages/releases)
Surveilr has inbuilt duckdb and sqlite features.but it would be advisable to install them.

```bash
# Download the latest stable release (e.g., v3.7.0) . check in https://github.com/surveilr/packages/releases
wget https://github.com/surveilr/packages/releases/download/3.7.0/surveilr_3.7.0_x86_64-unknown-linux-gnu.tar.gz

# Extract it
tar -xzf surveilr_3.7.0_x86_64-unknown-linux-gnu.tar.gz

# Install it by moving the executable to a directory in your PATH
sudo mv surveilr /usr/local/bin/
```

### Environment Variables

Configuration is handled through environment variables, ideally managed with **direnv** and stored in a local `.envrc` file.

You can generate a starter `.envrc` file and add it to your local configuration using Spry:

```bash
./spry.ts task prepare-env
direnv allow
```

| Variable | Description | Example Value | Required for `prepare-db` |
| :--- | :--- | :--- | :--- |
| **`SPRY_DB`** | The database connection URL used by SQLPage and Spry. | `sqlite://resource-surveillance.sqlite.db?mode=rwc` | Yes |
| **`PORT`** | The TCP port for the local SQLPage server. | `9227` | Yes |
| **`STUDY_DATA_PATH`** | The path to the folder containing your raw study files (the input folder for ingestion). | `raw-data/simplera-synthetic-cgm/` | Yes |
| **`TENANT_ID`** | A unique, short identifier for your study or tenant. | `FLCG` | Yes |
| **`TENANT_NAME`** | The full, human-readable name for your study or organization. | `"Florida Clinical Group"` | Yes |

**Example `.envrc` content:**

```envrc
export SPRY_DB="sqlite://resource-surveillance.sqlite.db?mode=rwc"
export PORT=9227
export STUDY_DATA_PATH="raw-data/simplera-synthetic-cgm/"
export TENANT_ID="FLCG"
export TENANT_NAME="Florida Clinical Group"
direnv allow
```

> ⚠️ **Security Note:** Never commit secrets or production credentials into `.envrc`. Ensure `.envrc` and the generated database file (e.g., `resource-surveillance.sqlite.db`) are added to your `.gitignore`.

## Core Pipeline Overview

The entire data preparation workflow is defined in the dataset specific  markdown file, executed through the `prepare-db` task.

| Stage | Tool | Description |
| :--- | :--- | :--- |
| 1. **Pre-Validation Gate** | Deno Script | Checks dependencies, file structure, and metadata quality. **Pipeline halts if this fails.** |
| 2. **Ingestion** | `surveilr` | Converts raw files into the standardized **RSSD** (Resource Surveillance Study Data) format. |
| 3. **SQL Validation** | `surveilr` Shell | Runs data quality checks against the newly ingested data. |
| 4. **Complex ETL** | DuckDB | Performs advanced transformations: tracing, combining CGM data, anonymization, and calculating metrics. |
| 5. **Persistence** | DuckDB → SQLite | Exports all final, processed tables into the SQLite database (`$SPRY_DB`). |
| 6. **Presentation** | SQLPage | Reads the SQLite database to render the web dashboard. |

-----

### Prepare Study Data

* Organize your raw research data files according to the formats described on the official DRH website: [https://drh.diabetestechnology.org/organize-cgm-data](https://drh.diabetestechnology.org/organize-cgm-data).
* Place the data directory at the location specified by the **`$STUDY_DATA_PATH`** environment variable.
* Depending on the structure of each dataset, you can create dedicated executable Markdown workflows containing DuckDB or SQLite SQL tailored for dataset-specific transformations and analytics.
  For example, for CGM study data obtained from the SIMPLERA device, you can create a file such as **`drh-simplera-spry.md`** and invoke the relevant SQL scripts within it.

-----

## Standard Workflow Instructions

### Inspect the Pipeline Structure (Runbook)

Before executing, you can view the dependency graph and sequence of tasks defined in **`drh-simplera-spry`** using the Spry `runbook` command.

**command:** ./spry.ts runbook -m [markdown file name] --visualize ascii-tree

**Example:**

```bash
# View the runbook as a dependency tree (ASCII visualization)
./spry.ts runbook -m drh-simplera-spry.md --visualize ascii-tree
```

### Option A: Execute All Steps Sequentially (Recommended for Development)

Execute the three main tasks in order. Use the `-m` flag to explicitly reference the Spryfile if it's not the default `Spryfile.md`.

#### Step 1: Run ETL (Cleanup, Data validation, Data Preparation and Transformation)

This script performs cleanup, validation, ingestion, and the complete complex ETL sequence.

```bash
./spry.ts task prepare-db
```

If you need to explicitly reference the Spryfile, use the `-m` flag:

**command:** ./spry.ts task -m [markdown file name]  [task name]

**Example:**

```bash
./spry.ts task -m drh-simplera-spry.md prepare-db
```

#### Step 2: Integrated Build

This is the preferred method for running the application. This command executes the following pipeline: it performs the data build `build-server`, compiling the SQLPage content files, generating the necessary SQL, and pushing the entire application structure into the database `$SPRY_DB`.

**command:**

```bash
./spry.ts task -m [markdown file name]  [task name]
```

**Example:**

```bash
./spry.ts task -m drh-simplera-spry.md build-server
```

Expected Result: The console will display messages for the application build, and finally, the URL where the server is running (e.g., <http://localhost:9227/>).

#### Step 3: Start the Local SQLPage Server manually

This task start the local SQLPage server automatically

**command:**

```bash
 ./spry.ts task -m [markdown file name]  [task name]
 ```

**Example:**

```bash
./spry.ts task -m drh-simplera-spry.md run-server
```

You can run the SQLPage server directly using:

```bash
SQLPAGE_SITE_PREFIX="" sqlpage
```

### Option B: Execute the Entire Workflow via Runbook

Since the tasks are designed to be executed sequentially, you can run the entire workflow in a single command using `runbook`. This executes Step 1, then Step 2 and Step 3 in sequential order.

**command:** ./spry.ts runbook -m [markdown file name] 

**Example:**

```bash
# This command runs prepare-db, build-to-db, and run-server in sequence
./spry.ts runbook -m drh-simplera-spry.md
```

-----

## Customization and Modification Guide

To modify the pipeline's behavior, you must edit the source files that control the specific logic, as defined in **`drh-simplera-spry`**.

### Modifying Pre-Validation Logic

This logic dictates the rules for checking data integrity and dependencies *before* ETL starts.

| Logic | File to Modify |
| :--- | :--- |
| **Pre-Validation Rules** | `drh-pre-etl-validation.ts` |
| **Validation Execution** | The `deno run` command within the **`prepare-db`** task in **`drh-simplera-spry`**. |

### Modifying ETL and Data Quality Logic

All SQL files are segregated into dedicated directories for modularity.

| ETL Component | Directory | Purpose |
| :--- | :--- | :--- |
| **Complex DuckDB Transformations** | `duckdb-etl-sql/` | Contains scripts for resource-intensive operations like combined CGM tracing and advanced data processing. |
| **Common SQL / Validation** | `common-sql/` | Contains common SQL used for post-ingestion data quality checks and utility views. |

**To customize the transformation logic for a new dataset:**

1. Create a new SQL file within the appropriate directory (`duckdb-etl-sql/` or `common-sql/`).
2. Reference this new file in your custom Spryfile .

-----

## Handling Multiple Datasets (Custom Pipelines)

If a new dataset requires a **unique sequence of ETL steps** or specialized transformations, the most maintainable approach is to create a dedicated **custom Spryfile**.

### Strategy: Use a Custom `Spryfile`

1. **Duplicate the Base File:** Copy the main Spryfile and rename it (e.g., `cp drh-simplera-spry study-x-etl.spry.md`).
2. **Customize the Logic:** Modify the task steps within **`study-x-etl.spry.md`**. You can replace existing SQL steps with calls to your newly created custom SQL files (from Section `Modifying ETL and Data Quality Logic`) to bring the data views into the required DRH format.
3. **Execute the Custom Pipeline:** Use the `-f` flag to point Spry to your custom definition for both the ETL and the build steps.

| Action | Command |
| :--- | :--- |
| **Run Custom ETL** | `./spry.ts -m study-x-etl.spry.md task prepare-db` |
| **Build Custom Site** | `./spry.ts -m study-x-etl.spry.md task build-server` |
| **Run Server** | `./spry.ts -m study-x-etl.spry.md task run-server` |

## Security and Hygiene (`.gitignore` Summary)

The following files and directories are typically generated during the workflow and should **NEVER** be committed to Git, as they are large binary outputs, derived code, or contain sensitive configuration.

| Path/File | Reason for Exclusion |
| :--- | :--- |
| **`.envrc`** | Contains local environment variables and potentially secrets. |
| **`drh-edge-core/resource-surveillance.sqlite.db`** | The large, binary database file generated by the pipeline. |
| **`drh-edge-core/*.sql`** | Temporary SQL files generated during the ETL process. |
| **`dev-src.auto`** | The generated directory used by SQLPage to serve content in development mode. |
| **`validation-reports`** | Output reports from the pre-validation gate. |
| **`sqlpage/`** | contains the handlebars and sqlpage.json |
