# SPRY DRH EDGE PLATFORM

**End-to-end platform for Diabetes Research Hub (DRH) Edge data integration using Spry and SQLPage.**

## Overview

The **Diabetes Research Hub (DRH) SQLPage Application** is an ETL (Extract, Transform, Load) pipeline and web interface designed to process and visualize raw diabetes research data. This project automates the conversion of raw study files (e.g., CSV) into a structured SQLite database and uses the SQLPage framework to generate a user interface powered by SQLPage.

The goal is to provide a centralized platform for managing and analyzing continuous glucose monitor (CGM) data from research study.

-----

## 🌟 Features

The platform performs a complete workflow for converting raw diabetes research data (CGM, meal, fitness) into a structured SQLite database and presenting it via a rich, interactive web UI.

* **Pre-Validation Gate:** Checks file structure, metadata, and dependencies (Deno, surveilr). The pipeline halts if this step fails.
* **Data Conversion:** Automates the ingestion and conversion of raw study files (e.g., CSV) into a structured format using the `surveilr` tool.
* **DuckDB ETL:** Utilizes DuckDB for complex data transformation and integration, including combining CGM tracings and generating derived meal and fitness metadata using surveilr tool.
* **SQLPage UI:** Generates a modern, interactive data dashboard using SQLPage powered by the resulting SQLite database.
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

> **Note: SQLPage, Duckdb and Sqlite is integrated in surveilr.**
-----

## 🛠️ Prerequisites & Setup

### Prerequisites

Ensure you have the following installed to run the platform:

1. **[Spry binary](https://github.com/programmablemd/homebrew-packages):** The core command-line tool, installed via Homebrew.
2. **[Surveilr](https://github.com/surveilr/packages/releases):** The data-processing utility for file ingestion and orchestration.
3. **Deno:** Required for pre-validation typescript execution[version 2.5.6]
4. **direnv**: Recommended for managing environment variables easily.

### ⚙️ Installation Steps

Follow these steps to install the required tools on a Linux system.

#### 1. Install Spry binary (via Homebrew)

Install the unified `spry` binary, which contains all the necessary commands (tasks, runbooks, sqlpage compiler).

```bash
## Installation
brew tap programmablemd/packages
brew install spry
```

##### Usage

After installation, you can run:

```bash
spry --version
```

##### How to Update

To update to the latest version:

```bash
brew update
brew upgrade spry
```

##### Uninstall

To remove Spry:

```bash
brew uninstall spry
```

To remove the tap:

```bash
brew untap programmablemd/packages
```

#### 2. Install Deno

Deno is required to run the Spry CLI.

```bash
# Using the recommended installation script
curl -fsSL https://deno.land/x/install/install.sh | sh
# Ensure Deno is added to your PATH (the script usually suggests the line)
# Example: export PATH="$HOME/.deno/bin:$PATH"
```

#### 3. Install Surveilr

Surveilr is the data-processing utility for file ingestion.The latest surveilr packages can be found [here.](https://github.com/surveilr/packages/releases)
Surveilr includes built-in DuckDB and SQLite support, from surveilr version 3.10 for smoother ETL execution and debugging.

> Note: Only Surveilr v3.10.0 and above, provide support for DuckDB-based ETL SQL execution.

```bash
# Download the latest stable release (e.g., v3.13.0) . check in https://github.com/surveilr/packages/releases
wget https://github.com/surveilr/packages/releases/download/3.13.0/surveilr_3.13.0_x86_64-unknown-linux-gnu.tar.gz

# Extract it
tar -xzf surveilr_3.13.0_x86_64-unknown-linux-gnu.tar.gz

# Install it by moving the executable to a directory in your PATH
sudo mv surveilr /usr/local/bin/
```

## Execution Directory

After cloning this repository, switch to:

```bash
cd drh-edge-core
```

### Environment Variables

Configuration is handled through environment variables, ideally managed with **direnv** and stored in a local `.envrc` file.

* Modify the **`STUDY_DATA_PATH`** ,**`TENANT_ID`** and **`TENANT_NAME`**  in the markdown file specific to the dataset.
  
You can generate a starter `.envrc` file and add it to your local configuration using Spry:

```bash
spry rb task prepare-env [markdownfilename]
direnv allow
```

**Example:**

```bash
spry rb task prepare-env drh-simplera-spry.md
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
| 2. **Ingestion and transformation** | `surveilr ingest and orchestrate transform-csv` | Converts raw files into the standardized **RSSD** (Resource Surveillance Study Data) format. |
| 3. **SQL Validation** | `surveilr shell` | Runs data quality checks against the newly ingested data. |
| 4. **Complex ETL** | DuckDB sql execution through `surveilr shell --engine duckdb` | Performs advanced transformations: tracing, combining CGM data, anonymization, and calculating metrics. |
| 5. **Persistence** | DuckDB → SQLite(through `surveilr shell --engine duckdb` ) | Exports all final, processed tables into the SQLite database (`$SPRY_DB`). |
| 6. **Presentation**| SQLPage(through `surveilr` and `spry binary`) | Reads the SQLite database to render the web dashboard. |

-----

### Prepare Study Data

* Organize your raw research data files according to the formats described on the official DRH website: [https://drh.diabetestechnology.org/organize-cgm-data](https://drh.diabetestechnology.org/organize-cgm-data).
* Place the data directory at the location specified by the **`$STUDY_DATA_PATH`** environment variable.
* Depending on the structure of each dataset, you can create dedicated executable Markdown workflows containing DuckDB or SQLite SQL tailored for dataset-specific transformations and analytics.
  * For example, for CGM study data obtained from the SIMPLERA device(`simplera-synthetic-cgm` folder), you can create a file such as **`drh-simplera-spry.md`** and invoke the relevant SQL scripts within it.
  * As an additional example, we have also provided an executable Markdown workflow for CGM data from the Dexcom device and Dexcom API(`dexcom-synthetic-cgm` folder), available as `drh-dexcom-cgm-spry.md`.

-----

## Standard Workflow Instructions

### Inspect the task Structure as dependancy graph

Before executing, you can view the dependency graph and sequence of tasks defined in any markdown file using the Spry `rb run` command.

**command:**

```bash
 spry rb run [markdownfilename] --visualize ascii-tree
 ```

**Example:**

```bash
# View the runbook as a dependency tree (ASCII visualization)
spry rb run drh-simplera-spry.md --visualize ascii-tree
```

### List All Defined Tasks in the markdown

You can view a list of all defined tasks within the markdown file:

```bash
spry rb ls [markdownfilename]
```

Example:

```bash
spry rb ls drh-simplera-spry.md
```

### Option A: Execute All Steps Sequentially (Recommended for Development)

Execute the tasks in order. Specifiy the markdown name to explicitly reference the data set specific markdown if it's not the default `Spryfile.md`.

#### Step 1: Set the enviornment variables

```bash
spry rb task prepare-env
```

If you need to explicitly reference the specific dataset based markdown(e.g.drh-simplera-spry.md), refer the following sample:

**command:**

```bash
spry rb task [taskname] [markdownfilename]
```

**Example:**

```bash
spry rb task prepare-env drh-simplera-spry.md
```

#### Step 2: Run ETL (Cleanup, Data validation, Data Preparation and Transformation)

This script performs cleanup, validation, ingestion, and the complete complex ETL sequence.

```bash
spry rb task prepare-db
```

If you need to explicitly reference the specific datset based markdown, refer the following sample:

**command:**

```bash
spry rb task [taskname] [markdownfilename]
```

**Example:**

```bash
spry rb task prepare-db drh-simplera-spry.md
```

#### Step 3: Integrated Build

This is the preferred method for running the application. This command executes the following pipeline: it performs the data build `build-server`, compiling the SQLPage content files, generating the necessary SQL, and pushing the entire application structure into the database `$SPRY_DB`.

**command:**

```bash
spry rb task [taskname] [markdownfilename] 
```

**Example:**

```bash
spry rb task build-server drh-simplera-spry.md
```

Expected Result: The console will display messages for the application build, and finally, the URL where the server is running (e.g., <http://localhost:9227/>).

#### Step 3: Start the Local SQLPage Server manually

You can run the SQLPage server directly using:

```bash
sqlpage
```

### Option B: Execute the Entire Workflow via Runbook

Since the tasks are designed to be executed sequentially, you can run the entire workflow in a single command using `runbook`. This executes Step 1, then Step 2 in sequential order.

**command:**

```bash
spry rb run [markdownfilename] 
```

**Example:**

```bash
# This command runs prepare-db, build-to-db, and run-server in sequence
spry rb run drh-simplera-spry.md
```

Or

```bash
spry rb run drh-simplera-spry.md ls 
```

Execute the following once the runbook execution succeeds..

```bash
sqlpage
```

-----

## Customization and Modification Guide

To modify the pipeline's behavior, you must edit the source files that control the specific logic, as defined in **`drh-simplera-spry.md`**.

### Modifying Pre-Validation Logic

This logic dictates the rules for checking data integrity and dependencies *before* ETL starts.

| Logic | File to Modify |
| :--- | :--- |
| **Pre-Validation Rules** | `drh-pre-etl-validation.ts` |
| **Validation Execution** | The `deno run` command within the **`prepare-db`** task in **`drh-simplera-spry.md`**. |

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
| **Set the Env** | `spry rb task prepare-env study-x-etl.spry.md` |
| **Run Custom ETL** | `spry rb task prepare-db study-x-etl.spry.md` |
| **Build Custom Site** | `spry rb task build-server study-x-etl.spry.md` |

## Security and Hygiene (`.gitignore` Summary)

The following files and directories are typically generated during the workflow and should **NEVER** be committed to Git, as they are large binary outputs, derived code, or contain sensitive configuration.

| Path/File | Reason for Exclusion |
| :--- | :--- |
| **`.envrc`** | Contains local environment variables and potentially secrets. |
| **`drh-edge-core/resource-surveillance.sqlite.db`** | The large, binary database file generated by the pipeline. |
| **`drh-edge-core/*.sql`** | Temporary SQL files generated during the ETL process. |
| **`dev-src.auto`** | The generated directory used by SQLPage to serve content in development mode. |
| **`validation-reports`** | Output reports from the pre-validation gate. |
