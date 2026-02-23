# CGMacros DRH Content Generator — CGM Data Standardization CLI

## Part 1 — User Guide

### Overview

The **CGMacros Required Files Content Generator** is a CLI utility designed to transform diverse Continuous Glucose Monitoring (CGM) data architectures into standardized files compatible with the Digital Research Hub (DRH) schema. It is specifically optimized for the [PhysioNet CGMacros dataset](https://physionet.org/content/cgmacros/1.0.0/).

---

### Generated Outputs (DRH Standard)

The tool produces three mandatory CSV files in a strict column order:

* **`study.csv`** — High-level metadata (NCT numbers, funding, study dates).
* **`participant.csv`** — Consolidated demographic/clinical data with automated medical logic.
* **`cgm_file_metadata.csv`** — A manifest mapping specific hardware devices to participants, including precise data-wear date ranges.

---

### Core Logic & Medical Intelligence

#### HbA1c Diagnostic Logic (MANDATORY)

The script automatically derives clinical markers from `bio.csv` based on the following thresholds. The `diagnosis_icd` and `diabetes_type` fields are populated accordingly.

| Category | HbA1c Level | ICD-10 Code | `diabetes_type` |
| :--- | :--- | :--- | :--- |
| **Normal** | < 5.7% | *(empty)* | *(empty)* |
| **Prediabetes** | 5.7% – 6.4% | **R73.03** | Prediabetes |
| **Type 2 Diabetes** | ≥ 6.5% | **E11.9** | Type 2 |
| **Type 1 Diabetes** | *N/A — cannot be HbA1c-derived* | **E10.9** | Type 1 *(override only — assign only if explicitly stated in the dataset)* |

**Derivation Rules:**

* HbA1c **< 5.7** → `diabetes_type` = *empty*, `diagnosis_icd` = *empty*
* HbA1c **5.7 – 6.4** → `diabetes_type` = **Prediabetes**, `diagnosis_icd` = **R73.03**
* HbA1c **≥ 6.5** → `diabetes_type` = **Type 2**, `diagnosis_icd` = **E11.9**
* Dataset explicitly states Type 1 → Override to `diabetes_type` = **Type 1**, `diagnosis_icd` = **E10.9**

> **Note:** HbA1c values must be retrieved from `bio.csv`.

---

####  Platform Auto-Detection

The script scans device name strings to assign the `source_platform` field automatically. This can be overridden via `--source-platform` if needed.

| Platform | Detected Keywords |
| :--- | :--- |
| **Dexcom** | G4, G5, G6, G7, Stelo |
| **Abbott** | Libre, FreeStyle |
| **Medtronic** | Carelink, Paradigm |
| **Senseonics** | Eversense |

---

### Supported Distribution Cases (Overview)

| Case | Distribution Name | Description |
| :--- | :--- | :--- |
| 1 | `all_participant_cgm_in_one_file` | All participants, single file, single device |
| 2 | `participant_data_in_separate_cgm_files` | One file per participant |
| 3 | `single_participant_in_multiple_files` | Multiple files per participant |
| 4 | `multiple_device_cgm_multiple_participants_single_file` | Multiple devices + participants, single file *(CGMacros case)* |
| 5 | `multiple_device_cgm_multiple_participants_separate_files` | Multiple device files stored separately |

---

### Execution Guide

**Env setup:**

```bash
cd drh-edge-core
./setup.sh
source venv/bin/activate.fish # if fish shell
```


#### Example Command (CGMacros — Case 4)

Use this for datasets where IDs are folder names (e.g., `CGMacros-001`) and files contain multiple device streams:

```bash
venv/bin/python3 support/aides/cgmacros/cgm-macros-content-generator.py \
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

---

## Part 2 — Developer Specification (AI Prompt Mode)

> **Instructions:** Copy the content below to an AI to generate or modify the script strictly.



**Act as a Senior Python Data Engineer.** Write a CLI utility named `cgm-macros-content-generator.py` using `pandas` and `argparse` to generate standardized research output files (`study.csv`, `participant.csv`, and `cgm_file_metadata.csv`).


###  Distribution Case Definitions & Required Arguments

The script must accept `--cgm-distribution` with the following allowed values and enforce additional required CLI arguments per case.

#### Case 1: `all_participant_cgm_in_one_file`

All CGM data for all participants in a single file, single device.

**Required additional CLI:**

* `--cgm-file`
* `--timestamp-column`
* `--cgm-value-column`
* `--participant-id-column`

---

#### Case 2: `participant_data_in_separate_cgm_files`

One CGM file per participant.

**Required additional CLI:**

* `--cgm-folder`
* `--timestamp-column`
* `--cgm-value-column`
* `--participant-id-column`

---

#### Case 3: `single_participant_in_multiple_files`

Multiple CGM files per participant.

**Required additional CLI:**

* `--cgm-folder`
* `--timestamp-column`
* `--cgm-value-column`
* `--participant-id-column`

---

#### Case 4: `multiple_device_cgm_multiple_participants_single_file` ✅ *(CGMacros Case)*

Multiple devices (e.g., Libre + Dexcom), multiple participants, single combined dataset file.

**Required additional CLI:**

* `--cgm-file`
* `--timestamp-column`
* `--participant-id-column`
* `--device1-name`
* `--device1-id`
* `--device1-cgm-column`
* `--device2-name`
* `--device2-id`
* `--device2-cgm-column`

**The script must:**

* Validate both device CGM columns exist in the file
* Split logical streams by device
* Generate metadata per participant per device
* Compute date ranges per participant per device

---

#### Case 5: `multiple_device_cgm_multiple_participants_separate_files`

Multiple device files stored separately.

**Required additional CLI:**

* `--device1-folder`
* `--device1-name`
* `--device1-id`
* `--device1-timestamp-column`
* `--device1-cgm-column`
* `--device2-folder`
* `--device2-name`
* `--device2-id`
* `--device2-timestamp-column`
* `--device2-cgm-column`
* `--participant-id-column`

---

###  Global Required CLI Arguments (All Cases)

* `--input-folder`
* `--output-folder`
* `--study-id`
* `--study-name`
* `--study-start-date`
* `--study-end-date`
* `--treatment-modalities`
* `--funding-source`
* `--nct-number`
* `--study-description`
* `--source-platform` *(acts as an override; otherwise auto-detected from device name — see §3)*
* `--derive-date-range` *(true/false)*
* `--start-date` *(required if `--derive-date-range=false`)*
* `--end-date` *(required if `--derive-date-range=false`)*

#### ID & Metadata Logic

* **Metadata ID Format:** `META-[integer]` using a global incrementing counter (e.g., `META-1`, `META-2`).
* **Study ID Validation:** `^[A-Z0-9]{4,6}$`
* **Participant ID Validation:** `^[A-Z0-9][A-Z0-9-]{1,12}[A-Z0-9]$`
* **Participant ID Extraction:** If `--participant-id-column` is empty, extract the numeric portion from the folder/filename (e.g., `CGMacros-001` → `1`) and prefix with the `study_id`.

---

###  Output Schema Definitions

#### 1 `study.csv` — Exact Column Order

| # | Column |
| :--- | :--- |
| 1 | `study_id` |
| 2 | `study_name` |
| 3 | `start_date` |
| 4 | `end_date` |
| 5 | `treatment_modalities` |
| 6 | `funding_source` |
| 7 | `nct_number` |
| 8 | `study_description` |

* Populated entirely from CLI arguments.
* Exactly one row.

---

#### 2 `participant.csv` — Exact Column Order

| # | Column |
| :--- | :--- |
| 1 | `participant_id` |
| 2 | `study_id` |
| 3 | `site_id` |
| 4 | `diagnosis_icd` |
| 5 | `med_rxnorm` |
| 6 | `treatment_modality` |
| 7 | `gender` |
| 8 | `race` |
| 9 | `ethnicity` |
| 10 | `age` |
| 11 | `bmi` |
| 12 | `baseline_hba1c` |
| 13 | `diabetes_type` |
| 14 | `study_arm` |

**For CGMacros:**

* Validate existence of `bio.csv` and `gut_health_test.csv` — fail execution if missing.
* Use `bio.csv` as the base table; perform a **left join** with `gut_health_test.csv`.
* Map all available fields to the DRH schema.
* Fill unavailable schema fields with an empty string.
* Inject `study_id` from CLI.
* Ensure exactly **one row per participant**.

---

#### 3 `cgm_file_metadata.csv` — Exact Column Order

| # | Column |
| :--- | :--- |
| 1 | `metadata_id` |
| 2 | `devicename` |
| 3 | `device_id` |
| 4 | `source_platform` |
| 5 | `patient_id` |
| 6 | `file_name` |
| 7 | `file_format` |
| 8 | `file_upload_date` |
| 9 | `data_start_date` |
| 10 | `data_end_date` |
| 11 | `map_field_of_cgm_date` |
| 12 | `map_field_of_cgm_value` |
| 13 | `study_id` |
| 14 | `map_field_of_patient_id` |

---

###  Metadata Population Logic

For each participant + device combination, populate fields as follows:

| Field | Source |
| :--- | :--- |
| `metadata_id` | `META-[incrementing integer]` |
| `devicename` | CLI `--device1-name` / `--device2-name` |
| `device_id` | CLI `--device1-id` / `--device2-id` |
| `source_platform` | Auto-detected from device name (see §3), overridden by `--source-platform` if provided |
| `patient_id` | Validated participant ID |
| `file_name` | `logical_device_stream.csv` (single file cases) or actual filename (separate file cases) |
| `file_format` | Detected file extension (e.g., `.csv`) |
| `file_upload_date` | Current UTC timestamp in ISO format |
| `data_start_date` | Min timestamp per participant per device (if `derive-date-range=true`) or `--start-date` |
| `data_end_date` | Max timestamp per participant per device (if `derive-date-range=true`) or `--end-date` |
| `map_field_of_cgm_date` | CLI `--timestamp-column` |
| `map_field_of_cgm_value` | CLI `--device1-cgm-column` / `--device2-cgm-column` |
| `map_field_of_patient_id` | CLI `--participant-id-column` |
| `study_id` | CLI `--study-id` |

---

###  Validation Requirements

The script must:

* Validate CLI consistency based on the selected distribution case.
* Fail with a clear error if required columns are missing from input files.
* Fail with a clear error if required files or folders are missing.
* Use structured, timestamped console logging for every processing stage.
* Use chunked pandas reading (`chunksize=50000`) for all CGM file reading.
* Validate all IDs against their regex patterns before writing output.

---

###  Architecture & Technical Requirements

* **Language/Libraries:** Python 3, `argparse`, `pandas`, `uuid`, `logging`, `datetime`.
* **No hardcoded column names** — all column references must come from CLI arguments.
* **Production-quality code** with docstrings on all functions.
* **Modular functions (mandatory):**
  * `validate_distribution_args()`
  * `generate_study_file()`
  * `process_participants()`
  * `process_case_1()`
  * `process_case_2()`
  * `process_case_3()`
  * `process_case_4()`
  * `process_case_5()`
  * `generate_metadata()`
* Clean separation of transformation logic and metadata generation logic.
* Include `if __name__ == "__main__":` entrypoint.

> **Return ONLY the complete Python script with detailed code comments.**
