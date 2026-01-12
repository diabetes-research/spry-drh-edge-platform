# SPRY DRH EDGE PLATFORM

**An end-to-end platform for Diabetes Research Hub (DRH) Edge data integration using Spry, Surveilr, and SQLPage.**

---

## Overview

The **Diabetes Research Hub (DRH) SQLPage Application** is an ETL (Extract, Transform, Load) pipeline and web interface designed to process, validate, and visualize raw diabetes research data. The platform automates the conversion of raw study files (e.g., CSV) into a structured SQLite database and uses the SQLPage framework to generate a data-driven web user interface.

The primary goal is to provide a centralized, reproducible, and extensible platform for managing and analyzing Continuous Glucose Monitor (CGM) data from diabetes research studies.

---

## Features

The platform implements a complete workflow for converting raw diabetes research data (CGM, meal, fitness) into a structured SQLite database and presenting it through a rich, interactive web UI.

* **Pre-Validation Gate**
  Validates file structure, metadata completeness, and dependency consistency. Detailed diagnostic reports are available directly in the SQLPage UI.

* **Data Conversion**
  Automates ingestion and conversion of raw study files (e.g., CSV) into a standardized schema using the `surveilr` tool.

* **DuckDB-Based ETL**
  Uses the embedded DuckDB engine within Surveilr for complex transformations, including CGM tracing consolidation and derived meal and fitness metadata generation.

* **SQLPage UI**
  Generates a modern, interactive dashboard using SQLPage, powered by the SQLite database produced via Surveilr and orchestrated by Spry.

* **Comprehensive Dashboards**
  Dedicated views for:

  * Study participant metrics and demographics
  * Combined CGM, meal, and fitness datasets
  * Ingestion, verification, and de-identification logs
  * Associated metadata (researchers, institutions, devices)

---

## Technology Stack

| Technology   | Role                                                                                                          |
| ------------ | ------------------------------------------------------------------------------------------------------------- |
| **Spry**     | Orchestrates project tasks and generates the SQLPage presentation layer.                                      |
| **SQLPage**  | Web application framework that renders dynamic pages directly from SQL queries.                               |
| **Surveilr** | Handles CSV ingestion, orchestration, and transformation into the RSSD (Research Study Data Database) format. |
| **DuckDB**   | Executes complex ETL and analytical transformations.                                                          |
| **SQLite**   | Final structured database consumed by SQLPage.                                                                |

> **Note:** SQLPage, DuckDB, and SQLite are integrated and managed internally by Surveilr.

---

## Prerequisites & Setup

### Prerequisites

Ensure the following tools are installed:

1. **Spry binary** – Core CLI for task orchestration (installed via Homebrew).
2. **Surveilr** – Data ingestion and orchestration utility.
3. **Deno** – Required for pre-validation TypeScript execution (version `2.5.6`).
4. **direnv** – Recommended for environment variable management.

---

### Installation Steps

Refer to the official documentation for full details:
[https://docs.opsfolio.com/spry/getting-started/installation](https://docs.opsfolio.com/spry/getting-started/installation)

#### 1. Install Spry (via Homebrew)

```bash
brew tap programmablemd/packages
brew install spry
```

Verify installation:

```bash
spry --version
```

Update Spry:

```bash
brew update
brew upgrade spry
```

Uninstall:

```bash
brew uninstall spry
brew untap programmablemd/packages
```

---

#### 2. Install Deno

```bash
curl -fsSL https://deno.land/x/install/install.sh | sh
```

Ensure Deno is added to your `PATH` as instructed by the installer.

---

#### 3. Install Surveilr

Surveilr packages are available at:
[https://github.com/surveilr/packages/releases](https://github.com/surveilr/packages/releases)

Surveilr includes built-in DuckDB and SQLite support. DuckDB-based ETL execution is supported from **Surveilr v3.10.0 and above**.

Installation reference:
[https://docs.opsfolio.com/surveilr/core/installation](https://docs.opsfolio.com/surveilr/core/installation)

Example installation:

```bash
wget https://github.com/surveilr/packages/releases/latest/download/surveilr_jammy.deb
sudo dpkg -i surveilr_jammy.deb
```

---

## Execution Directory

After cloning the repository:

```bash
cd drh-edge-core
```

---

## Environment Variables

Configuration is managed using environment variables, ideally via **direnv** and a local `.envrc` file.

Update the following values in the dataset-specific Markdown file:

* `STUDY_DATA_PATH`
* `TENANT_ID`
* `TENANT_NAME`

Generate a starter `.envrc` file using Spry:

```bash
spry rb task prepare-env [markdownfilename]
direnv allow
```

Example:

```bash
spry rb task prepare-env drh-simplera-spry.md
direnv allow
```

### Environment Variable Reference

| Variable          | Description                                       | Example                                             | Required |
| ----------------- | ------------------------------------------------- | --------------------------------------------------- | -------- |
| `SPRY_DB`         | SQLite connection string used by Spry and SQLPage | `sqlite://resource-surveillance.sqlite.db?mode=rwc` | Yes      |
| `PORT`            | SQLPage server port                               | `9227`                                              | Yes      |
| `STUDY_DATA_PATH` | Path to raw study files                           | `raw-data/simplera-synthetic-cgm/`                  | Yes      |
| `TENANT_ID`       | Short tenant or study identifier                  | `FLCG`                                              | Yes      |
| `TENANT_NAME`     | Human-readable tenant name                        | `Florida Clinical Group`                            | Yes      |

Example `.envrc`:

```envrc
export SPRY_DB="sqlite://resource-surveillance.sqlite.db?mode=rwc"
export PORT=9227
export STUDY_DATA_PATH="raw-data/simplera-synthetic-cgm/"
export TENANT_ID="FLCG"
export TENANT_NAME="Florida Clinical Group"
direnv allow
```

> **Security Note:** Do not commit `.envrc` or generated database files to version control.

---

## Core Pipeline Overview

The data preparation workflow is defined in a dataset-specific executable Markdown file and executed through Spry tasks.

| Stage          | Tool                        | Description                                     |
| -------------- | --------------------------- | ----------------------------------------------- |
| Pre-validation | Surveilr shell(DuckDB)      | Validates structure, metadata, and dependencies |
| Ingestion      | Surveilr ingest/orchestrate | Converts raw data into RSSD format              |
| SQL validation | Surveilr shell              | Performs post-ingestion quality checks          |
| Complex ETL    | Surveilr shell(DuckDB)      | CGM tracing, anonymization, metrics             |
| Persistence    | Surveilr shell(DuckDB)      | Exports final tables                            |
| Presentation   | SQLPage                     | Renders dashboards                              |

---

## Prepare Study Data

* Organize raw files according to DRH guidelines:
  [https://drh.diabetestechnology.org/organize-cgm-data](https://drh.diabetestechnology.org/organize-cgm-data)
* Place data under the path specified by `STUDY_DATA_PATH`.
* Create dataset-specific executable Markdown workflows for custom transformations.

  * Example: `drh-simplera-spry.md`
  * Dexcom example: `drh-dexcom-cgm-spry.md`

---

## Standard Workflow Instructions

### Visualize Task Dependencies

```bash
spry rb run [markdownfilename] --visualize ascii-tree
```

Example:

```bash
spry rb run drh-simplera-spry.md --visualize ascii-tree
```

---

### List Defined Tasks

```bash
spry rb ls [markdownfilename]
```

---

### Option A: Step-by-Step Execution (Recommended)

1. **Prepare Environment**

   ```bash
   spry rb task prepare-env drh-simplera-spry.md
   ```

2. **Run ETL and Build UI**

   ```bash
   spry rb task prepare-db-deploy-server drh-simplera-spry.md
   ```

3. **Start SQLPage**

   ```bash
   sqlpage
   ```

---

### Option B: Full Runbook Execution

```bash
spry rb run drh-simplera-spry.md
sqlpage
```

---

## Customization and Modification

### Pre-validation Logic

| Component        | File                           |
| ---------------- | ------------------------------ |
| Validation rules | `drh-preflight-validation.sql` |

### ETL and Data Quality Logic

| Component  | Location                            | Purpose                            |
| ---------- | ----------------------------------- | ---------------------------------- |
| DuckDB ETL | `duckdb-etl-sql/drh-master-etl.sql` | Resource-intensive transformations |
| Common SQL | `common-sql/`                       | Shared checks and utilities        |

To support a new dataset:

1. Create new SQL files as needed.
2. Reference them in a custom Spry Markdown file.

---

## Handling Multiple Datasets

For datasets requiring specialized ETL logic, create a dedicated Spryfile.

### Recommended Approach

1. Copy the base file:

   ```bash
   cp drh-simplera-spry.md study-x-etl.spry.md
   ```

2. Customize tasks and SQL references.
3. Execute using the custom file.

| Action              | Command                                                     |
| ------------------- | ----------------------------------------------------------- |
| Prepare environment | `spry rb task prepare-env study-x-etl.spry.md`              |
| Run ETL and deploy  | `spry rb task prepare-db-deploy-server study-x-etl.spry.md` |

---

## Security and Hygiene (`.gitignore`)

The following files should **never** be committed:

| Path                              | Reason                          |
| --------------------------------- | ------------------------------- |
| `.envrc`                          | Local configuration and secrets |
| `resource-surveillance.sqlite.db` | Large generated database        |
| `*.sql` (generated)               | Temporary ETL artifacts         |
| `dev-src.auto`                    | SQLPage dev output              |
| `validation-reports/`             | Pre-validation outputs          |

---
