# CGMND DRH Content Generator — CGM Data Standardization CLI

### Part 1 — User Guide

#### Quick Start Checklist
1. [ ] **Raw Data**: Ensure `NonDiabDeviceCGM.csv`, `NonDiabScreening.csv`, and `NonDiabPtRoster.csv` are in your input folder.
2. [ ] **Environment**: Run `./setup.sh` and activate the virtual environment.
3. [ ] **Generate**: Run the command below.
4. [ ] **Verify**: Check the `--output-folder` for `study.csv`, `participant.csv`, and `cgm_file_metadata.csv`.

---

### Clinical Source Mapping (Automatic)

The generator handles clinical data ingestion automatically from the raw source files:
- **Source Files**: `NonDiabScreening.csv` and `NonDiabPtRoster.csv` must both be present in the `--input-folder`.
- **Internal Logic**: The script joins these files on `PtID`, calculates BMI (`kg / (cm/100)^2`), and maps demographics for use in the DRH output.
- **Anchor Date**: Translates relative "Days From Enrollment" to absolute dates anchored to `2022-01-01`.

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
source .venv/bin/activate
```

#### Example Command (CGMND)

Use this command to process the combined dataset where all participant data resides in a single file (`NonDiabDeviceCGM.csv`):

```bash
.venv/bin/python3 support/aides/cgmnd/cgmnd-content-generator.py \
        --cgm-distribution single_file_all_participants \
        --cgm-file         "raw-data/cgmd-table-data/NonDiabDeviceCGM.csv" \
        --input-folder     "raw-data/cgmd-table-data" \
        --timestamp-column "DeviceTm" \
        --participant-id-column "PtID" \
        --cgm-value-column "Value" \
        --output-folder    "examples/cgmnd-output" \
        --study-id         "CGMND" \
        --study-name       "CGM in Non-Diabetic Participants (T1DX)" \
        --study-start-date "2018-09-21" \
        --study-end-date   "2018-12-20" \
        --treatment-modalities "Continuous Glucose Monitoring" \
        --funding-source   "T1D Exchange" \
        --study-description "CGM data from non-diabetic individuals to establish normal glucose patterns." \
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
