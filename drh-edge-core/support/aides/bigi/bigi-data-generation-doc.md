# 📂 BIGI Data Generation Documentation

This guide provides an overview of the Python scripts used to process the **BIG IDEAs Lab (BIGI)** dataset for the Diabetes Research Hub (DRH) platform.

This project uses two primary scripts to transform raw research data and study information into structured, relational CSV files compatible with the DRH Edge Core platform.

## 1. Study Supporting Files Generator

**Script:** `generate-study-supporting-files.py`

### **Description**

This script acts as the "administrative" processor. It takes a high-level text description of the study (PIs, institutions, publications) and breaks it down into several relational CSV files. It ensures that every entity (like an author or a lab) is assigned a unique ID and properly linked to the Study ID.

### **Key Outputs**

* `study.csv`: Core study details.
* `institution.csv`: Names and locations of involved organizations.
* `investigator.csv` & `author.csv`: Research personnel, automatically linking investigators to authors if names match.
* `lab.csv`, `publication.csv`, `site.csv`: Research environment and citation metadata.

### Execution Guide

**Env setup:**

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
.venv/bin/python3 support/aides/cgmacros/generate-study-supporting-files.py <input_file_path> <output_directory_path>
```

**Example Run (BIG IDEAs Lab (BIGI):**

```bash
.venv/bin/python3 support/aides/bigi/generate-study-supporting-files.py \
       support/aides/bigi/bigi-study-info.txt \
       examples/bigi

```

---

## 2. BIGI Content Generator

**Script:** `bigi-content-generator.py`

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
.venv/bin/python3 support/aides/bigi/bigi-content-generator.py \
          --input-folder "examples/raw/bigi" \
          --output-folder "examples/" \
          --study-id "BIGI" \
          --study-name "BIG IDEAs Lab Glycemic Variability and Wearable Device Data" \
          --study-start-date "" \
          --study-end-date "" \
          --treatment-modalities "Continuous Glucose Monitoring (CGM), Wearable Physiological Monitoring, Digital Biomarker Engineering, Standardized Meal Testing, Oral Glucose Tolerance Test (OGTT)" \
          --funding-source "Duke MEDx" \
          --nct-number "" \
          --study-description "Dataset of 16 participants with elevated but non-diabetic glucose levels monitored for 8-10 days using Dexcom G6 CGM and Empatica E4 wearable devices to generate digital biomarkers for glycemic variability and prediabetes risk detection." \
          --timestamp-column "Timestamp (YYYY-MM-DDThh:mm:ss)"

```

---

### Summary Table

| Script | Input Type | Primary Role |
| --- | --- | --- |
| `generate-study-supporting-files.py` | `.txt` (Human readable) | Creates the organizational/relational backbone (Institutions, Authors, Labs). |
| `bigi-content-generator.py` | `.csv` (Raw data) & CLI | Processes clinical data, normalizes timestamps, and maps hardware/diagnoses. |

## AI Generation Prompt: BIGI Content Generator

**Role:** You are a Python Data Engineer specializing in medical informatics and the Diabetes Research Hub (DRH) data standards.

**Task:** Create a Python script named `bigi-content-generator.py` designed to process raw wearable device data and demographics into a standardized relational format.

### **1. Command Line Interface (CLI)**

The script must use `argparse` to accept the following inputs:

* `--input-folder`: Path to the raw data (participant subdirectories).
* `--output-folder`: Base path for the processed CSVs.
* `--study-id`: A 4-10 character alphanumeric code (e.g., "BIGI").
* `--timestamp-column`: The specific name of the time column in CGM files (e.g., "Timestamp (YYYY-MM-DDThh:mm:ss)").
* Other metadata arguments: `--study-name`, `--study-description`, `--treatment-modalities`, `--funding-source`, and `--nct-number`.

### **2. Directory & Demographic Logic**

* **Participant Discovery:** Iterate through subdirectories in the input folder. Each folder name represents a participant.
* **Demographics Mapping:** Look for a `Demographics.csv` file in the root input folder.
* Map `ID` from the CSV to the folder numeric suffix.
* Extract `Gender` (standardize to capitalized string) and `HbA1c`.
* Assign a random age between 35 and 65 for placeholder data.

### **3. Clinical Derivation Rules**

Implement the following logic to automate clinical classification:

* **Diabetes Type:** * HbA1c < 5.7: "Normal".
* 5.7 ≤ HbA1c < 6.5: "Prediabetes".
* HbA1c ≥ 6.5: "T2D".

* **ICD-10 Mapping:** * "T1D" $\rightarrow$ `E10`.
* "T2D" $\rightarrow$ `E11`.
* "Prediabetes" $\rightarrow$ `R73.03`.
  
### **4. CGM Data & Device Normalization**

For every `.csv` file found within a participant's folder:

* **Timestamping:** Attempt to use the `--timestamp-column`. If not provided, auto-detect columns containing the string "timestamp".
* **Device Identification:** * Search for "Device Info" or "Source Device ID" columns.
* Extract the device name (e.g., "Dexcom G6") and strip strings like "Mobile App".

* **Manufacturer Mapping:** Create a dictionary to map device names to manufacturers:
* `Dexcom` (G4, G5, G6, G7, Clarity).
* `Abbott` (FreeStyle Libre).
* `Medtronic` (Guardian, Guardian Connect).
* `Senseonics` (Eversense).

### **5. Required Outputs**

Save the following CSV files into a subdirectory named after the lower-case Study ID:

1. **`study.csv`**: Contains the study metadata and calculated global start/end dates from the actual CGM data.
2. **`participant.csv`**: Rows for each participant including ID, gender, baseline HbA1c, derived diabetes type, and ICD code.
3. **`cgm_file_metadata.csv`**: A log of every file processed, its date range (start/end), device name, and manufacturer.

---
