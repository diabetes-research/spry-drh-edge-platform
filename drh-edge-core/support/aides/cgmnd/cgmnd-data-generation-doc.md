# CGMND Data Generation Documentation


This guide provides an overview of the Python scripts used to process the **CGMND** dataset for the Diabetes Research Hub (DRH) platform

This project uses two primary scripts to transform raw research data and study information into structured, relational CSV files compatible with the DRH Edge Core platform.


## 1. Study Supporting Files Generator

This script is responsible for generating the study supporting files (CSVs) for the CGMND dataset.

**Script:** `support/aides/cgmnd/generate-study-supporting-files.py`

### **Description**

This script acts as the "administrative" processor. It takes a high-level text description of the study (PIs, institutions, publications) and breaks it down into several relational CSV files. It ensures that every entity (like an author or a lab) is assigned a unique ID and properly linked to the Study ID.

### **Key Outputs**

- `study.csv`: Contains metadata about the study, including its ID, name, start date, end date, and funding source.
- `institution.csv`: Lists all institutions associated with the study.
- `investigator.csv`: Details of all investigators involved in the study.
- `author.csv`: Authors of the study, linked to investigators.
- `lab.csv`: Labs associated with the study.
- `publication.csv`: Publications related to the study.
- `site.csv`: Sites where the study was conducted.

#### Quick Start Checklist

```markdown
1. [ ] **Raw Data**: Ensure `NonDiabDeviceCGM.csv`, `NonDiabScreening.csv`, and `NonDiabPtRoster.csv` are in your input folder (e.g., `raw-data/cgmnd-table-data/`).
2. [ ] **Environment**: Run `./setup.sh` and activate the virtual environment.
3. [ ] **Generate**: Run the command below.
4. [ ] **Verify**: Check the `--cgmnd-output` folder for `study.csv`, `participant.csv`, and `cgm_file_metadata.csv`.
5. [ ] **Verify**: Check the `--cgmnd-supporting-data` folder for `study.csv`, `institution.csv`, `investigator.csv`, `author.csv`, `lab.csv`, `publication.csv`, and `site.csv`.
```

---

### Clinical Source Mapping (Automatic)

The generator handles clinical data ingestion automatically from the raw source files:
- **Source Files**: `NonDiabScreening.csv` and `NonDiabPtRoster.csv` must both be present in the `raw-data/cgmnd-table-data/` folder.
- **Internal Logic**: The script joins these files on `PtID`, calculates BMI (`kg / (cm/100)^2`), and maps demographics for use in the DRH output.
- **Anchor Date**: Translates relative "Days From Enrollment" to absolute dates anchored to `2018-09-21`.

#### HbA1c Diagnostic Logic

The script applies standard DRH diagnostic logic based on HbA1c thresholds from the screening file:

| Category | HbA1c Level | ICD-10 Code | `diabetes_type` |
| :--- | :--- | :--- | :--- |
| **Normal** | < 5.7% | *(empty)* | *(empty)* |
| **Prediabetes** | 5.7% – 6.4% | **R73.03** | Prediabetes |
| **Type 2 Diabetes** | ≥ 6.5% | **E11.9** | Type 2 |

---

### Execution Guide

**Environment Setup:**

```bash
cd drh-edge-core
./setup.sh
# Note: Use .venv (hidden) to match the platform reset logic
source .venv/bin/activate.fish # if fish shell
# OR
source .venv/bin/activate      # if bash/zsh
```

**Command Syntax:**
```bash
.venv/bin/python3 support/aides/cgmnd/cgmnd-content-generator.py <input_file_path> <output_directory_path>
```

#### Example Command (CGMND)

Use this command to process the combined dataset where all participant data resides in a single file (`NonDiabDeviceCGM.csv`):

## 2. CGMND Content Generator

**Script:** `support/aides/cgmnd/cgmnd-content-generator.py`

### **Script Description**

This script is the "data" processor. It iterates through raw participant folders containing CGM (Continuous Glucose Monitoring) data. It performs heavy lifting such as:

* **Demographics Mapping:** Pulling gender and HbA1c from a `Demographics.csv` file if available.
* **Clinical Derivation:** Automatically calculating diabetes types (Normal, Prediabetes, T2D) based on HbA1c levels and assigning corresponding ICD-10 codes.
* **Device Identification:** Parsing CGM files to detect the hardware used (e.g., Dexcom G6) and mapping it to the correct manufacturer.
* **Temporal Normalization:** Detecting and formatting timestamps to ensure consistency across the dataset.

### **Outputs**

* `participant.csv`: Demographic and clinical status for every subject.
* `cgm_file_metadata.csv`: A detailed log of every data file found, including date ranges and device info.
* `study.csv`: An updated version of study info including calculated start/end dates from the actual data.

#### **The Execution Command**
```bash
.venv/bin/python3 support/aides/cgmnd/cgmnd-content-generator.py \
        --cgm-distribution single_file_all_participants \
        --cgm-file         "raw-data/cgmd-table-data/NonDiabDeviceCGM.csv" \
        --input-folder     "raw-data/cgmd-table-data" \
        --timestamp-column "Timestamp (YYYY-MM-DDThh:mm:ss)" \
        --participant-id-column "PtID" \
        --cgm-value-column "Glucose Value (mg/dL)" \
        --output-folder    "examples/cgmnd-output" \
        --study-id         "CGMND" \
        --study-name       "CGM in Non-Diabetic Participants (T1DX)" \
        --study-start-date "2018-12-10" \
        --study-end-date   "2018-12-20" \
        --treatment-modalities "Continuous Glucose Monitoring" \
        --funding-source   "Leona M. and Harry B. Helmsley Charitable Trust" \
        --study-description "This multicenter prospective study examined CGM glucose patterns in healthy, nondiabetic individuals aged 6–80. Participants wore a blinded Dexcom G6 for up to 10 days to establish normal glucose ranges, showing that healthy people spent most of their time within 70–140 mg/dL, with very little hyper‑ or hypoglycemia" \
        --derive-date-range true
```

---

## Part 2 — Developer Specification (AI Prompt Mode)

> **Instructions:** Copy the content below to an AI assistant to maintain or recreate this script strictly.

**Task:** Act as a Senior Python Data Engineer. Maintain a CLI utility named `cgmnd-content-generator.py` that processes a single large CGM CSV file and joins it with clinical source tables to generate standardized DRH outputs.

### Technical Architecture
- **Input Architecture**: Single CSV file for all participants (`NonDiabDeviceCGM.csv`).
- **Clinical Sources**: `NonDiabScreening.csv` and `NonDiabPtRoster.csv` (Inner join on `PtID`).
- **Timestamp Logic**: Convert relative `DeviceDtDaysFromEnroll` (integers) to absolute ISO dates using a configurable `EnrollmentDt` anchor (default: `2022-01-01`).
- **Medical Logic**: 
    - Calculate BMI: `weight_kg / (height_cm / 100)^2`.
    - Map Gender: M/F to Male/Female.
    - Derive ICD-10 from HbA1c: Prediabetes (R73.03), Type 2 (E11.9).
- **Processing**: Use `pandas` for table operations and chunked reading for the large CGM file (10MB+).

### CLI Requirements
- `--cgm-file`: Path to the large combined CGM file.
- `--input-folder`: Directory containing the Screening and Roster CSVs.
- `--output-folder`: Destination for the 3 DRH CSVs.
- `--study-id`: 4-6 character study identifier.
- `--timestamp-column`: Name of the date/time field in the CGM file.
- `--participant-id-column`: Column mapping to participant IDs across all files.

### Output Schema Standards
1. **`study.csv`**: Single row containing study metadata (Start/End dates, Funding, NCT).
2. **`participant.csv`**: One row per participant found in the clinical join.
3. **`cgm_file_metadata.csv`**: One row per participant found in the CGM file, containing absolute `data_start_date` and `data_end_date`.

> **Return ONLY the complete Python script with detailed code comments.**
