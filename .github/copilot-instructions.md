# Copilot Workspace Instructions

These instructions apply to all chats in this workspace.

## MCP and data-query rules
1. Use surveilr MCP for all data queries(no Pylance MCP, no direct `sqlite3` fallback) and drh-orchestrator MCP for all system management tasks (ingestion, reset, configuration) .
2. Use MCP tools such as `mcp_surveilr_query_sql`, `mcp_surveilr_get_table_sample`, `mcp_surveilr_get_table_metadata`, `mcp_surveilr_get_schema` as needed.
3. Run the query and show results directly in chat unless explicitly asked to save files.
4. If no rows match, explicitly state `row_count=0` and suggest a broader query.
5. Keep responses concise and actionable.
6. When creating charts, first fetch category/count data via Surveilr MCP, then render a Mermaid chart.
7. Provide responses directly in the VS Code chat window only; do not require or route through any external client.
8. Pipeline Workflow: If a user asks to "ingest," "setup," or "reset," use drh-orchestrator. If they ask to "analyze," "query," or "show data," use surveilr.

## Diabetes Research Schema

This guide outlines the available tables and views in your SQLite database, structured for researchers using the **Model Context Protocol (MCP)** to query clinical research data.The SQLite database contains many **platform and infrastructure tables**.For research queries, use **only the research-oriented tables and views listed below**.

### 1. Research Metadata & Administration

These tables define the study structure, participants, and researchers.

| Table/View Name | Type | Description |
| --- | --- | --- |
| **`study_meta_data`** | Table |  Core study parameters (NCT, Description, Dates). |
| **`drh_study`** | View | Dynamic view of study details extracted from raw payloads. |
| **`participant`** | Table |  Master list of enrolled research subjects. |
| **`drh_participant`** | Table | Detailed demographics (Age, Gender, BMI, Diabetes Type). |
| **`drh_investigator`** | Table | List of researchers associated with the studies. |
| **`drh_institution`** / **`drh_lab`** | View | Organizational hierarchy and participating laboratories.|
| **`drh_site`** | View | Specific clinical sites where data collection occurs. |
| **`drh_author`** | View |  Profiles of authors for linked publications. |
| **`drh_publication`** | View | Research papers and DOIs linked to the study. |

---

### 2. Time-Series Data (CGM, Fitness, Meal)
The core of the clinical data, from raw ingestion to optimized caching.

* **Glucose (CGM):**
* **`combined_cgm_tracing`**: The logic view joining raw files to participants.
* **`combined_cgm_tracing_cached`**: The high-performance table for glucose analysis.
* **`drh_raw_cgm_tracing`**: The original JSON payload for the audit trail.


* **Activity & Nutrition:**
* **`combined_fitness_data_cached`**: Steps, Heart Rate, and Calories Burned.
* **`combined_meal_data_cached`**: Standardized meal times and calorie counts.
* **`participant_meal_fitness_data`**:  Links meals and activity to specific CGM windows.


* **Ingestion Metadata:**
* **`file_meta_ingest_data`**:  Comprehensive log of every file ingested.
* **`drh_cgm_file_metadata`**: Specific metadata for glucose device files.
* **`drh_device_file_count_view`**: Report on which devices (Dexcom/Libre) provide the most data.

---

### 3. Advanced Clinical Analytics & Dashboards

Pre-calculated metrics used for clinical reporting and participant monitoring.

* **Primary Metrics:**
* **`drh_participant_metrics`**: GMI, Mean Glucose, and Coefficient of Variation.
* **`drh_glycemic_risk_indicator` (GRI)**: Clinical risk scoring for hypo/hyperglycemia.
* **`drh_time_range_stacked_metrics`**: Standardized Time-in-Range (TIR) percentages.
* **`drh_agp_metrics`**: Hourly percentiles for Ambulatory Glucose Profile charts.
* **`drh_advanced_metrics`**: Specialized scores (J-index, LBGI, HBGI).


* **Dashboards & Windowing:**
* **`participant_dashboard_cached`**: Pre-computed participant-level summaries.
* **`study_combined_dashboard_participant_metrics_view`**: Multi-participant comparison view.
* **`participant_cgm_date_range_view / cached`**: Rolling analysis windows (7, 14, 30, 90 days).
* **`drh_study_vanity_metrics_details`**: Study-wide recruitment and demographic stats.

---

### 4. System Integrity & Privacy

Tables used to monitor the platform and handle sensitive data de-identification.

* **Privacy & Logic:**
* **`records_to_anonymize`**:  Tracks records currently being de-identified.
* **`drh_vw_orchestration_deidentify`**:  Audit log of the anonymization process.

* **Health & Logging:**
* **`drh_vv_session_summary`**: Ingestion success/failure "Health Check."
* **`drh_vv_hierarchy`**: Deep-dive trace evidence of the processing pipeline.
* **`drh_otel_spans`** / **`drh_otel_logs`**: OpenTelemetry traces for system troubleshooting.
* **`drh_schema_logs`**: Dynamic catalog of all available data streams and columns.

---

## Workspace context
- Database path: `drh-edge-core/resource-surveillance.sqlite.db`
- MCP server name in config: `surveilr`
