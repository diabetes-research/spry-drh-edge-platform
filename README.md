
# DRH Edge Platform: Researcher & Data Scientist Guide

The **DRH Edge Platform** is an automated ecosystem designed to bridge the gap between raw diabetes research data and actionable clinical insights. It transforms disparate source files (e.g., CSV/Excel) into a validated, relational research database with a built-in visualization layer.

---

## 1. Core Architecture

The platform is built on three pillars to ensure data is standardized, observable, and automated:

* **Standardization (Singer Protocol)**: Researchers write **Singer Taps** to map unique source data to standardized **DRH Target Schemas** (Study, Participant, CGM Tracing). Detailed schema definitions are available in the [Singer DRH Protocol](https://github.com/diabetes-research/singer-drh-protocol) repository.
* **Observability (OpenTelemetry)**: Every ingestion run is monitored. If data fails validation, OTel logs provide the exact file and row causing the error. The OTEL schemas for spans, traces, and metrics are also integrated into the [DRH Target](https://github.com/diabetes-research/singer-drh-protocol) specification.
  > **Important**: Current observability is achieved through structured output.
  > An enhanced OpenTelemetry SDK-based implementation is currently being worked upon to provide deeper native instrumentation.
  > OpenTelemetry in DRH Edge is **diagnostic-only**.  
  > It never mutates data or controls execution flow directly.  
  > All gating decisions (PASS/FAIL) are derived from SQL views built on top of OTel output.

* **Orchestration (Executable Markdown)**: Documentation acts as code. Using **SPRY**, you execute "Runbook" tasks directly from `.md` files to trigger the entire pipeline.
* **Surveilr (The Engine)**: Acts as the core execution layer that runs the Singer Taps and executes SQL queries against the local SQLite database.

---

## 2. Prerequisites & Environment Setup

Before starting, ensure your local machine is configured with the necessary core utilities. These tools manage everything from environment variables to data ingestion and observability.

| Tool | Role | Documentation |
| --- | --- | --- |
| **Python 3.8+** | Primary language for **Singer Taps** and the `drh-target` package. | [Python.org](https://docs.python.org/3/) |
| **Spry** | Orchestrates tasks (bash/SQL) defined in Executable Markdown files. | [Spry Docs](https://docs.opsfolio.com/spry/getting-started/installation) |
| **Surveilr (v3.10+)** | The engine for data ingestion, OTel trace collection, and pipeline orchestration. | [Surveilr Docs](https://docs.opsfolio.com/surveilr/core/installation) |
| **direnv** | Loads environment variables from the `.envrc` block in your Markdown. | [direnv.net](https://direnv.net/) |

---

## 3. The 2-Minute Quick Start

Follow this **Clone → Configure → Execute → Visualize** workflow.

### Step 1: Clone the Repository

```bash
git clone https://github.com/diabetes-research/spry-drh-edge-platform.git
cd spry-drh-edge-platform/drh-edge-core

```

### Step 2: Configure Your Dataset

Verify if your data matches the samples in the `raw-data/` folder.

1. **Match Found?** Copy your data into a new folder within `raw-data/`.
2. **Choose Runbook**: Pick the `.md` file matching your data (e.g., `drh-dexcom-clarity.md`).
3. **Set Variables**: Update the `prepare-env` block with your `STUDY_DATA_PATH` and `TENANT_ID`.
4. **Initialize**:

```bash
spry rb task prepare-env [your-markdown-file].md
direnv allow

```

**Example**:

```bash
spry rb task prepare-env drh-dexcom-clarity.md
direnv allow

```

### Step 3: Execute the Pipeline

Run the full orchestration (Ingestion → Validation → ETL → UI Packaging):

```bash
spry rb task prepare-db-deploy-server [your-markdown-file].md

```

**Example**:

```bash
spry rb task prepare-db-deploy-server  drh-dexcom-clarity.md

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

## 4. Advanced: Developing Custom Integrations

If your dataset structure is unique, follow the "Clone-Map-Automate" workflow.

### Creating a Custom Singer Tap

 **Setup Environment**:

```bash
python3 -m venv venv && source venv/bin/activate
pip install git+https://github.com/diabetes-research/singer-drh-protocol.git#subdirectory=drh-target/python-pkg

```

**Develop**: Use `singer-tap/tap-dexcom-clarity.surveilr[singer].py` as a reference.
**Verify**: Test locally and ensure it emits standard Singer messages (SCHEMA, RECORD, STATE).

```bash
python3 singer-tap/tap-mydata.surveilr[singer].py > result_mydata.txt

```

**Ingest**:

```bash
surveilr ingest files -r singer-tap/tap-mydata.surveilr[singer].py

```

---

## 5. Platform Architecture Highlights

* **Standardization**: Uses the Singer Protocol to map source data to DRH Target Schemas.
* **Observability**: Powered by OpenTelemetry (OTel). If validation fails, the ETL is automatically blocked, and the UI displays specific row-level errors.
* **Performance**: Leverages DuckDB for high-performance analytics on massive datasets.
  
---

## 6. 🎨 Platform Visual Showcase

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
