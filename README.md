# DRH Edge Platform: Researcher & Data Scientist Guide

The **DRH Edge Platform** is an automated ecosystem designed to bridge the gap between raw diabetes research data and actionable clinical insights. It transforms disparate source files (e.g., CSV/Excel) into a validated, relational research database with a built-in visualization layer.

---

## Table of Contents

- [DRH Edge Platform: Researcher \& Data Scientist Guide](#drh-edge-platform-researcher--data-scientist-guide)
  - [Table of Contents](#table-of-contents)
  - [Supported Operating Systems](#supported-operating-systems)
  - [Prerequisites \& Environment Setup](#prerequisites--environment-setup)
    - [Required Tools](#required-tools)
    - [Installation \& Version Verification](#installation--version-verification)
      - [1. Python 3.8+](#1-python-38)
      - [2. Spry](#2-spry)
      - [3. Surveilr (v3.10+)](#3-surveilr-v310)
        - [3.1 Upgrading to a Specific Version](#31-upgrading-to-a-specific-version)
  - [Environment \& State Management](#environment--state-management)
    - [The Reset \& Setup Tools](#the-reset--setup-tools)
    - [⚠️ Mandatory Migration \& Manual Cleanup](#️-mandatory-migration--manual-cleanup)
      - [1. Clear Legacy Shell Variables](#1-clear-legacy-shell-variables)
      - [2. Standard Reset](#2-standard-reset)
      - [3. Manual Fail-safe (If `.venv` persists)](#3-manual-fail-safe-if-venv-persists)
    - [4. Finalized Execution Order](#4-finalized-execution-order)
  - [Core Architecture](#core-architecture)
  - [The 2-Minute Quick Start](#the-2-minute-quick-start)
    - [Step 1: Clone the Repository](#step-1-clone-the-repository)
    - [Step 2: Configure Your Dataset](#step-2-configure-your-dataset)
    - [Step 3: Execute the Pipeline](#step-3-execute-the-pipeline)
    - [Step 4: Launch the Dashboard](#step-4-launch-the-dashboard)
  - [Environment Cleanup \& Tap Preparation](#environment-cleanup--tap-preparation)
    - [💡 Manual Fail-safe](#-manual-fail-safe)
  - [Port \& Database Management](#port--database-management)
    - [Ensure SQLPage is Stopped](#ensure-sqlpage-is-stopped)
    - [Database Connection Safety](#database-connection-safety)
  - [Standard Workflow (Final Order)](#standard-workflow-final-order)
  - [Dataset Preparation Aides](#dataset-preparation-aides)
    - [Workflow Position](#workflow-position)
    - [Study Supporting Files Generator](#study-supporting-files-generator)
    - [CGMacros Content Generator](#cgmacros-content-generator)
    - [End-to-End: PhysioNet CGMacros Preparation → Pipeline](#end-to-end-physionet-cgmacros-preparation--pipeline)
  - [Advanced: Developing Custom Integrations](#advanced-developing-custom-integrations)
    - [Creating a Custom Singer Tap](#creating-a-custom-singer-tap)
  - [Platform Architecture Highlights](#platform-architecture-highlights)
  - [🎨 Platform Visual Showcase](#-platform-visual-showcase)
    - [🏛️ Research Landing Page](#️-research-landing-page)
    - [🔍 Quality Assurance: The Validation Gate](#-quality-assurance-the-validation-gate)
    - [📊 Clinical Insights: Research Dashboards](#-clinical-insights-research-dashboards)
    - [🛠️ Participant \& Device Metrics](#️-participant--device-metrics)
  - [License](#license)

## Supported Operating Systems

The DRH Edge Platform is designed to run on **Linux** and **macOS**. The table below clarifies what is and is not supported:

| Environment | Support Status |
| --- | --- |
| **Native Linux** (Ubuntu, Debian, and most distributions) | ✅ Fully Supported |
| **Linux under WSL on Windows** (Ubuntu, Debian, etc.) | ✅ Fully Supported |
| **macOS** | ✅ Fully Supported |
| **Native Windows** (PowerShell, CMD, without WSL) | ❌ Not Supported |

**Important clarifications:**

* The supported environment is **Linux or macOS**. WSL (Windows Subsystem for Linux) is simply one way for Windows users to get a Linux environment — it is built into Windows and does not require extra licensing. When DRH Edge runs in WSL, it is running on Linux.
* "Not supported on Windows" specifically means native Windows shells such as PowerShell or CMD **without** WSL.  

---

## Prerequisites & Environment Setup

Before starting, ensure your local machine is configured with the necessary core utilities. These tools manage everything from environment variables to data ingestion and observability.

### Required Tools

| Tool | Role | Documentation |
| --- | --- | --- |
| **Python 3.8+** | Primary language for **Singer Taps** and the `drh-target` package. | [Python.org](https://docs.python.org/3/) |
| **Spry** | Orchestrates tasks (bash/SQL) defined in Executable Markdown files. | [Spry Docs](https://docs.opsfolio.com/spry/getting-started/installation) |
| **Surveilr (v3.10+)** | The engine for data ingestion, OTel trace collection, and pipeline orchestration. | [Surveilr Docs](https://docs.opsfolio.com/surveilr/core/installation) |

---

### Installation & Version Verification

Install each tool using the instructions below, then run the corresponding verification command to confirm the correct version is active.

#### 1. Python 3.8+

**Ubuntu / Ubuntu under WSL:**

```bash
sudo apt update && sudo apt install -y python3 python3-pip python3-venv
```

**macOS:**

```bash
brew install python
```

**Verify:**

```bash
python3 --version
# Expected output: Python 3.8.x or higher
```

---

#### 2. Spry

Follow the installation steps at [Spry Docs](https://docs.opsfolio.com/spry/getting-started/installation).

**Verify:**

```bash
spry --version
```

---

#### 3. Surveilr (v3.10+)

Follow the installation steps at [Surveilr Docs](https://docs.opsfolio.com/surveilr/core/installation).

**Verify:**

```bash
surveilr --version
# Expected output: surveilr v3.10.x or higher
```

##### 3.1 Upgrading to a Specific Version

If your current version is outdated or if you need to target a specific release (such as **v3.31.0** for latest stability features), use the built-in upgrade command:

**To upgrade to the latest stable release:**

```bash
sudo surveilr upgrade

```

**To upgrade to a specific version (Recommended):**

```bash
sudo surveilr upgrade -v 3.31.0

```

> [!TIP]
> **Permissions Note:** Using `sudo` is typically required to replace the binary in system-wide directories (like `/usr/local/bin`). If you installed `surveilr` in a user-local directory, `sudo` may not be necessary.

---

## Environment & State Management

To ensure reliability, the platform uses a local `.env` file (generated per study) and a hidden virtual environment (`.venv`).

### The Reset & Setup Tools

| Script | Purpose | When to run |
| --- | --- | --- |
| `reset.sh` | Wipes the database, cache, and deletes the `.venv`. | Whenever switching datasets, runbooks, or after an error. |
| `setup.sh` | Manually creates the `.venv` and installs dependencies. | Before running **Independent Support Scripts** manually. |

### ⚠️ Mandatory Migration & Manual Cleanup

If you change study values in your Runbook or switch between different `.md` files, you **must** ensure the virtual environment (`.venv`) is completely wiped to prevent configuration "poisoning."

#### 1. Clear Legacy Shell Variables

Shell exports (like those previously used in `direnv`) have the highest priority and will override your `.env` file.

* **Action**: Open `~/.bashrc` or `~/.zshrc` and delete any lines exporting `STUDY_DATA_PATH`, `TENANT_ID`, or `PORT`.
* **Action**: Run `direnv deny` and delete any old `.envrc` files.
* **Apply**: Run `source ~/.bashrc` (or `~/.zshrc`).

#### 2. Standard Reset

Run the reset script located in `drh-edge-core/`:

```bash
./reset.sh

```

#### 3. Manual Fail-safe (If `.venv` persists)

If the `.venv` folder still exists after running `./reset.sh`, it is likely locked by a background process (like `surveilr web-ui` or an IDE extension). **You must delete it manually** before proceeding:

* **Kill Locks**: `pkill -9 python3 || true`
* **Force Delete**: `rm -rf .venv || sudo rm -rf .venv`
* **Verify**: `ls -d .venv` (Should return a "No such file" error).

---

### 4. Finalized Execution Order

1. **Initialize Environment**: `spry rb task prepare-env [your-file].md`
2. **Clean State**: Run `./reset.sh` (and verify `.venv` is gone).
3. **Execute Pipeline**: `spry rb task prepare-db-deploy-server [your-file].md`

---

## Core Architecture

The platform is built on three pillars to ensure data is standardized, observable, and automated:

* **Standardization (Singer Protocol)**: Researchers write **Singer Taps** to map unique source data to standardized **DRH Target Schemas** (Study, Participant, CGM Tracing). Detailed schema definitions are available in the [Singer DRH Protocol](https://github.com/diabetes-research/singer-drh-protocol) repository.
* **Observability (OpenTelemetry)**: Every ingestion run is monitored. If data fails validation, OTel logs provide the exact file and row causing the error. The OTel schemas for spans, traces, and metrics are also integrated into the [DRH Target](https://github.com/diabetes-research/singer-drh-protocol) specification.

  > **Important**: Current observability is achieved through structured output. An enhanced OpenTelemetry SDK-based implementation is currently being worked on to provide deeper native instrumentation. OpenTelemetry in DRH Edge is **diagnostic-only** — it never mutates data or controls execution flow directly. All gating decisions (PASS/FAIL) are derived from SQL views built on top of OTel output.

* **Orchestration (Executable Markdown)**: Documentation acts as code. Using **SPRY**, you execute "Runbook" tasks directly from `.md` files to trigger the entire pipeline.
* **Surveilr (The Engine)**: Acts as the core execution layer that runs the Singer Taps and executes SQL queries against the local SQLite database.

---

## The 2-Minute Quick Start

Follow this **Clone → Configure → Execute → Visualize** workflow.

### Step 1: Clone the Repository

```bash
git clone https://github.com/diabetes-research/spry-drh-edge-platform.git
cd spry-drh-edge-platform/drh-edge-core
```

### Step 2: Configure Your Dataset

Before running the pipeline, verify that your dataset structure aligns with the platform's requirements.

**Data Organization Requirements** — your dataset folder must contain the following files:

* **Study Metadata**: General study information.
* **Participant Data**: Subject demographics.
* **CGM File Metadata**: Metadata for individual tracing files.
* **CGM Tracing Files**: The raw glucose data (e.g., `cgm_tracing_*`).

> **Note**: File structures and naming conventions must follow the [DRH Data Organization Standard](https://drh.diabetestechnology.org/organize-cgm-data).

**Configuration Workflow:**

1. **Match Found?** If your data matches the synthetic samples in the `raw-data/` folder, copy your dataset into a new sub-directory within `raw-data/`.
2. **Choose Runbook**: Select the executable Markdown (`.md`) file that corresponds to your data type (e.g., `drh-dexcom-clarity.md` or `drh-simplera-cgm-systems.md`).
3. **Set Variables**: Open the `.md` file and update the `prepare-env` task block with your specific environment values:
   * `STUDY_DATA_PATH="raw-data/your-study/"`
   * `TENANT_ID="YOUR_LAB_ID"`
   * `TENANT_NAME="Your Research Lab Name"`

**Initialize** — run these commands in your terminal to lock in the settings:

```bash
# Initialize the environment variables defined in the Markdown file
spry rb task prepare-env [your-markdown-file].md
```

**Example:**

```bash
spry rb task prepare-env drh-dexcom-clarity.md
```

### Step 3: Execute the Pipeline

Run the full orchestration (Ingestion → Validation → ETL → UI Packaging):

```bash
spry rb task prepare-db-deploy-server [your-markdown-file].md
```

**Example:**

```bash
spry rb task prepare-db-deploy-server drh-dexcom-clarity.md
```

### Step 4: Launch the Dashboard

```bash
surveilr web-ui
```

Open **<http://localhost:9227>** to view demographics, CGM trends, and validation reports.

```bash
# If SQLPage is already running on localhost:9227
sudo kill $(sudo lsof -t -i:9227)
```

---

## Environment Cleanup & Tap Preparation

Before executing your pipeline, always run the reset script from the `drh-edge-core/` directory:

```bash
./reset.sh

```

**What this does:**

* **Terminates Processes**: Stops any active Python processes to release file locks.
* **Database Cleanup**: Removes the `resource-surveillance.sqlite.db` and associated cache files (`.db-shm`, `.db-wal`) to prevent data contamination.
* **Artifact Removal**: Deletes temporary UI source artifacts like `dev-src.auto`.
* **Sets Permissions**: Automatically marks all Python files in the `singer-tap/` directory as executable.
* **Wipes Virtual Environment**: Deletes the `.venv` folder to force a fresh, clean Python bootstrap on the next run.

### 💡 Manual Fail-safe

If the `.venv` folder still exists after running `./reset.sh`, it may be locked by a background process (like an IDE or `surveilr web-ui`). You must delete it manually:

```bash
pkill -9 python3 || true
rm -rf .venv || sudo rm -rf .venv

```

---

## Port & Database Management

### Ensure SQLPage is Stopped

If you have a previous session running on port **9227**, stop it before re-running the pipeline:

```bash
sudo kill $(sudo lsof -t -i:9227)
```

### Database Connection Safety

* **Close External Viewers**: Ensure the `resource-surveillance.sqlite.db` file is not open in an external database browser (like DB Browser for SQLite) while running a `spry` task, as this prevents the ingestion engine from writing to the file.
* **Gated Execution**: If a previous run failed, the pipeline might stop at the **Validation Gate**. Running `./reset.sh` ensures a clean state where `overall_status` can be re-evaluated.

---

## Standard Workflow (Final Order)

1. **Clean**: `./reset.sh`
2. **Configure**: `spry rb task prepare-env [your-markdown-file].md`
3. **Execute**: `spry rb task prepare-db-deploy-server [your-markdown-file].md`

---

## Dataset Preparation Aides

Before the main pipeline can run, raw source datasets often need to be transformed into the DRH-standard CSV files that the platform expects. The `drh-edge-core/support/aides/` directory contains **preparation tools** — Python scripts paired with detailed specification guides — that handle this pre-processing step. These aides operate independently of the main ingestion pipeline and are run manually before executing a Runbook.

### Workflow Position

```
Raw Dataset  →  [Preparation Aides]  →  DRH-Standard CSVs  →  [Runbook / Pipeline]  →  Dashboard
```

The aides produce the files that the pipeline ingests. Run them once per dataset before invoking `spry rb task prepare-db-deploy-server`.

---

### Study Supporting Files Generator

**Location:** `drh-edge-core/support/aides/cgmacros/generate-study-supporting-files.py`  
**Specification:** [`support/aides/cgmacros/Gen-Spec-Support.md`](drh-edge-core/support/aides/cgmacros/Gen-Spec-Support.md)

This tool converts a human-readable study information text file into **seven relational CSVs** structured for database ingestion or public repository submission:

| Output File | Contents |
| --- | --- |
| `study.csv` | High-level study record |
| `institution.csv` | Affiliated institutions with validated IDs |
| `investigator.csv` | Principal and co-investigators |
| `author.csv` | Authors, linked to investigator profiles by name matching |
| `lab.csv` | Research laboratory details |
| `publication.csv` | Associated publications |
| `site.csv` | Study site records |

**Key capabilities:** automated ID generation (`AUTH-01`, `INST-01`, etc.), relational author-investigator linking by name, strict `StudyID` validation (exactly 4 alphanumeric characters), multi-value semicolon parsing, and standards-compliant empty-field handling (`,,`).

**Environment setup:**

```bash
cd drh-edge-core
./setup.sh
source .venv/bin/activate.fish   # fish shell
# OR
source .venv/bin/activate         # bash / zsh
```

**Run (CGMacros example):**

```bash
.venv/bin/python3 support/aides/cgmacros/generate-study-supporting-files.py \
    support/aides/cgmacros/cgmacros-study-info.txt \
    examples/cgm-macros-supporting-data
```

The input file uses a `Key: Value` format with semicolons (`;`) to separate multiple values within a single field (e.g., a list of authors). See [`Gen-Spec-Support.md`](drh-edge-core/support/aides/cgmacros/Gen-Spec-Support.md) for the full input file specification and an embedded AI prompt for regenerating or extending the script logic.

---

### CGMacros Content Generator

**Location:** `drh-edge-core/support/aides/cgmacros/cgm-macros-content-generator.py`  
**Specification:** [`support/aides/cgmacros/Gen-Spec-Content.md`](drh-edge-core/support/aides/cgmacros/Gen-Spec-Content.md)

> ⚠️ **Scope notice:** This tool and its specification are tailored specifically to the [PhysioNet CGMacros dataset](https://physionet.org/content/cgmacros/1.0.0/). It is **not a general-purpose utility**. Researchers working with other datasets should treat this as a reference implementation — the specification's Part 2 contains a detailed AI prompt that is designed to be copied and refined for your own dataset's structure and column names.

This CLI utility transforms raw CGMacros data into the **three mandatory DRH-standard CSVs** required by the ingestion pipeline:

| Output File | Contents |
| --- | --- |
| `study.csv` | Single-row study record (NCT number, funding, dates, description) |
| `participant.csv` | One row per participant — demographics, clinical markers, HbA1c-derived diagnosis |
| `cgm_file_metadata.csv` | Device-to-participant manifest with precise data wear date ranges |

**Medical intelligence built in.** The generator automatically derives `diagnosis_icd` and `diabetes_type` from HbA1c values in `bio.csv` using established clinical thresholds:

| Category | HbA1c | ICD-10 | `diabetes_type` |
| --- | --- | --- | --- |
| Normal | < 5.7% | *(empty)* | *(empty)* |
| Prediabetes | 5.7% – 6.4% | R73.03 | Prediabetes |
| Type 2 Diabetes | ≥ 6.5% | E11.9 | Type 2 |
| Type 1 Diabetes | *N/A* | E10.9 | Type 1 *(explicit override only)* |

**Platform auto-detection.** Device name strings are scanned to assign `source_platform` automatically (Dexcom, Abbott, Medtronic, Senseonics). This can be overridden via `--source-platform`.

**Supported CGM distribution cases:**

| Case | Pattern |
| --- | --- |
| 1 | All participants in one file, single device |
| 2 | One file per participant |
| 3 | Multiple files per participant |
| **4** ✅ | **Multiple devices + participants in a single combined file** *(CGMacros case)* |
| 5 | Multiple device files stored separately |

**Environment setup:**

```bash
cd drh-edge-core
./setup.sh
source .venv/bin/activate.fish   # fish shell
# OR
source .venv/bin/activate         # bash / zsh
```

**Run (CGMacros — Case 4):**

```bash
.venv/bin/python3 support/aides/cgmacros/cgm-macros-content-generator.py \
    --cgm-distribution multiple_device_cgm_multiple_participants_single_file \
    --cgm-file         "examples/raw/CGMacros_dateshifted365/CGMacros" \
    --input-folder     "examples/raw/CGMacros_dateshifted365/CGMacros" \
    --timestamp-column "Timestamp" \
    --participant-id-column "FOLDER_ID" \
    --device1-name       "Abbott FreeStyle Libre" \
    --device1-id         "LIBRE-001" \
    --device1-cgm-column "Libre GL" \
    --device2-name       "Dexcom G6 Pro" \
    --device2-id         "DEXCOM-001" \
    --device2-cgm-column "Dexcom GL" \
    --output-folder      "examples/cgm-macros-output" \
    --study-id           "CGMA" \
    --study-name         "CGMacros: a scientific dataset for personalized nutrition and diet monitoring" \
    --study-start-date   "2021-01-01" \
    --study-end-date     "2024-12-31" \
    --treatment-modalities "Continuous Glucose Monitoring,Food Macronutrient Logging,Physical Activity Tracking,Gut Microbiome Profiling" \
    --funding-source     "National Science Foundation award No. 2014475" \
    --nct-number         "NCT04991142" \
    --study-description  "A dataset containing multimodal information from two CGMs, food macronutrients, food photographs, and physical activity, from 45 participants (15 healthy, 16 pre-diabetes, 14 Type 2 diabetes) over ten consecutive days." \
    --derive-date-range  true
```

See [`Gen-Spec-Content.md`](drh-edge-core/support/aides/cgmacros/Gen-Spec-Content.md) for the complete schema definitions, all CLI argument references, validation rules, metadata population logic, and the full AI developer prompt (Part 2) for regenerating or adapting this script to a different dataset.

---

### End-to-End: PhysioNet CGMacros Preparation → Pipeline

The following is the complete preparation-to-dashboard sequence for the PhysioNet CGMacros dataset using the runbook [`drh-physio-cgmacros.md`](drh-edge-core/drh-physio-cgmacros.md):

```

Step 1 — Generate supporting files (institutions, investigators, authors, labs, sites…)
         → .venv/bin/python3 support/aides/cgmacros/generate-study-supporting-files.py
              support/aides/cgmacros/cgmacros-study-info.txt
              examples/cgm-macros-supporting-data

Step 2 — Generate core DRH CSVs (study.csv, participant.csv, cgm_file_metadata.csv)
         → .venv/bin/python3 support/aides/cgmacros/cgm-macros-content-generator.py
              --cgm-distribution multiple_device_cgm_multiple_participants_single_file
              [... full arguments as shown ...]

Step 3 — Reset environment
         → ./reset.sh

Step 4 — Initialize runbook environment variables
         → spry rb task prepare-env drh-physio-cgmacros.md

Step 5 — Execute pipeline (ingest → validate → ETL → UI packaging)
         → spry rb task prepare-db-deploy-server drh-physio-cgmacros.md

Step 6 — Launch dashboard
         → surveilr web-ui
            open http://localhost:9227
```

---

## Advanced: Developing Custom Integrations

If your dataset structure is unique, follow the "Clone-Map-Automate" workflow.

### Creating a Custom Singer Tap

**Setup Environment:**

```bash
python3 -m venv venv && source venv/bin/activate
pip install git+https://github.com/diabetes-research/singer-drh-protocol.git#subdirectory=drh-target/python-pkg
```

**Develop**: Use `singer-tap/tap-dexcom-clarity.surveilr[singer].py` as a reference.

**Verify**: Test locally and ensure it emits standard Singer messages (SCHEMA, RECORD, STATE):

```bash
python3 singer-tap/tap-mydata.surveilr[singer].py > result_mydata.txt
```

**Ingest:**

```bash
surveilr ingest files -r singer-tap/tap-mydata.surveilr[singer].py
```

---

## Platform Architecture Highlights

* **Standardization**: Uses the Singer Protocol to map source data to DRH Target Schemas.
* **Observability**: Powered by OpenTelemetry (OTel). If validation fails, the ETL is automatically blocked, and the UI displays specific row-level errors.
* **Performance**: Leverages DuckDB for high-performance analytics on massive datasets.

---

## 🎨 Platform Visual Showcase

The DRH Edge Platform provides a specialized interface for both **Data Engineers** (to ensure data integrity) and **Clinical Researchers** (to analyze study outcomes).

### 🏛️ Research Landing Page

The entry point provides a high-level summary of active studies, enrollment progress, and system health.

<p align="center">
<img src="drh-edge-core/assets/landing.png" width="800" alt="Landing Page">
</p>

### 🔍 Quality Assurance: The Validation Gate

The platform acts as a "Gatekeeper." If incoming data violates clinical schemas or structural rules, the ETL is automatically blocked to prevent database corruption.

| **The Validation Gate** | **OTel Diagnostic Logs** |
| --- | --- |
|  |  |
| **Gated Execution**: The UI prevents ETL progression if the `overall_status` is **FAIL**. | **Root Cause Analysis**: Deep-link diagnostics identify the exact CSV row and schema violation. |

<p align="center">
<img src="drh-edge-core/assets/diagnostics.png" width="800" alt="Landing Page">
</p>

### 📊 Clinical Insights: Research Dashboards

Once data passes the gate, it is transformed into optimized relational tables for high-fidelity visualization and metric calculation.

| **Study Metrics & Participant Demographics** | **CGM Time-Series Analysis** |
| --- | --- |
|  |  |
| **Participant Overview**: Track demographics, enrollment status, and metadata. | **Glucose Tracings**: Interactive Time-in-Range (TIR) and GMI metrics. |

<p align="center">
<img src="drh-edge-core/assets/study-dashboard.png" width="800" alt="Landing Page">
</p>

### 🛠️ Participant & Device Metrics

Detailed drill-downs allow researchers to inspect individual participant traces, meal logs, and device performance metrics in a centralized view.

<p align="center">
<img src="drh-edge-core/assets/participant-info.png" width="800" alt="Participant Metrics">

<em>Comprehensive view of individual participant time-series data and clinical markers.</em>
</p>

---

## License

This project is licensed under the GNU General Public License v3.0. See the [LICENSE](/LICENSE) file for details.
