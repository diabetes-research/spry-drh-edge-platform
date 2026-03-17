#!/usr/bin/env python3
"""
cgmnd-content-generator.py
===========================
CLI utility for generating standardised DRH output files for (CGMND Dataset):
    - study.csv
    - participant.csv
    - cgm_file_metadata.csv

Supports the CGMND dataset architecture:
    - single large CSV for all participants
    - relative timestamps (days from enrollment)
    - medical logic for ICD-10 and diabetes type derivation
"""

import argparse
import logging
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import pandas as pd

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Output schema column order (MUST NOT be changed)
# ---------------------------------------------------------------------------
STUDY_COLUMNS = [
    "study_id",
    "study_name",
    "start_date",
    "end_date",
    "treatment_modalities",
    "funding_source",
    "nct_number",
    "study_description",
]

PARTICIPANT_COLUMNS = [
    "participant_id",
    "study_id",
    "site_id",
    "diagnosis_icd",
    "med_rxnorm",
    "treatment_modality",
    "gender",
    "race",
    "ethnicity",
    "age",
    "bmi",
    "baseline_hba1c",
    "diabetes_type",
    "study_arm",
]

METADATA_COLUMNS = [
    "metadata_id",
    "devicename",
    "device_id",
    "source_platform",
    "patient_id",
    "file_name",
    "file_format",
    "file_upload_date",
    "data_start_date",
    "data_end_date",
    "map_field_of_cgm_date",
    "map_field_of_cgm_value",
    "study_id",
    "map_field_of_patient_id",
]

# ---------------------------------------------------------------------------
# Medical Mapping Logic
# ---------------------------------------------------------------------------
_GENDER_MAP = {
    "M": "Male", "MALE": "Male",
    "F": "Female", "FEMALE": "Female",
}
_RACE_MAP = {
    "WHITE": "White",
    "BLACK": "Black or African American",
    "ASIAN": "Asian",
}
_ETHNICITY_MAP = {
    "HISPANIC/LATINO": "Hispanic or Latino",
    "NOT HISPANIC":    "Not Hispanic or Latino",
}

GENDER_ENUMS    = ["Male", "Female", "Other", "Unknown"]
RACE_ENUMS      = [
    "American Indian or Alaska Native", "Asian", "Black or African American", 
    "Native Hawaiian or Other Pacific Islander", "White", "Unknown"
]
ETHNICITY_ENUMS = ["Hispanic or Latino", "Not Hispanic or Latino", "Unknown"]

CHUNK_SIZE = 50_000

# ---------------------------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------------------------

def _safe_get(row: Optional[pd.Series], col_name: str) -> Optional[str]:
    if row is None or col_name not in row:
        return None
    val = row[col_name]
    return str(val) if pd.notna(val) else None

def _standardize_demographic(value: Optional[str], mapping: Dict[str, str], allowed_enums: List[str]) -> str:
    if value is None:
        return "Unknown"
    val_upper = value.strip().upper()
    mapped = mapping.get(val_upper, value)
    for enum in allowed_enums:
        if enum.lower() == mapped.lower():
            return enum
    return "Unknown"

def derive_icd_from_hba1c(hba1c_raw: str) -> Tuple[str, str]:
    try:
        val = float(hba1c_raw)
        if val >= 6.5: return "T2D", "E11"
        if val >= 5.7: return "PREDIABETES", "R73.03"  # implicitly val < 6.5
        return "", ""
    except (ValueError, TypeError):
        return "", ""

# ---------------------------------------------------------------------------
# Core Processing Engine
# ---------------------------------------------------------------------------

def _load_clinical_data(input_folder: Path) -> Dict[str, pd.Series]:
    """
    Load and join NonDiabPtRoster.csv and NonDiabScreening.csv directly.
    """
    roster_path = input_folder / "NonDiabPtRoster.csv"
    screening_path = input_folder / "NonDiabScreening.csv"

    if not roster_path.exists() or not screening_path.exists():
        log.error("Clinical source files (Roster/Screening) not found in %s", input_folder)
        sys.exit(1)

    log.info("Loading clinical source files...")
    roster_df = pd.read_csv(roster_path)
    screening_df = pd.read_csv(screening_path)

    # Join on PtID
    merged_df = pd.merge(screening_df, roster_df[['PtID', 'AgeAsOfEnrollDt']], on='PtID', how='inner')
    
    # Internalize the bio data mapping
    index = {}
    for _, row in merged_df.iterrows():
        pid = str(row['PtID'])
        # Calculate BMI (kg and cm)
        bmi = None
        if pd.notna(row['Weight']) and pd.notna(row['Height']) and row['Height'] > 0:
            bmi = round(row['Weight'] / ((row['Height'] / 100) ** 2), 2)
        
        index[pid] = pd.Series({
            "subject": pid,
            "Age": row.get('AgeAsOfEnrollDt'),
            "Gender": row.get('Gender'),
            "BMI": bmi,
            "Race": row.get('Race'),
            "Ethnicity": row.get('Ethnicity'),
            "A1c PDL (Lab)": row.get('HbA1c'),
        })
    
    return index

def process_case_cgmnd(args: argparse.Namespace, output_dir: Path) -> None:
    log.info("Processing CGMND consolidated architecture...")
    cgm_file = Path(args.cgm_file)
    if not cgm_file.is_file():
        log.error("CGM file not found: %s", cgm_file)
        sys.exit(1)

    # 1. Load clinical data directly from sources
    input_folder = Path(args.input_folder)
    bio_index = _load_clinical_data(input_folder)
    log.info("Loaded %d participant clinical records.", len(bio_index))
    
    # 2. Process Participants
    participants = []
    log.info("Generating participant records...")
    for pid, row in bio_index.items():
        hba1c = _safe_get(row, "A1c PDL (Lab)")
        diabetes_type, icd = derive_icd_from_hba1c(hba1c)
        participants.append({
            "participant_id": f"{args.study_id}-{pid}",
            "study_id": args.study_id,
            "site_id": "",
            "diagnosis_icd": icd,
            "med_rxnorm": "",
            "treatment_modality": "Continuous Glucose Monitoring",
            "gender": _standardize_demographic(_safe_get(row, "Gender"), _GENDER_MAP, GENDER_ENUMS),
            "race": _standardize_demographic(_safe_get(row, "Race"), _RACE_MAP, RACE_ENUMS),
            "ethnicity": _standardize_demographic(_safe_get(row, "Ethnicity"), _ETHNICITY_MAP, ETHNICITY_ENUMS),
            "age": _safe_get(row, "Age") or "",
            "bmi": _safe_get(row, "BMI") or "",
            "baseline_hba1c": hba1c or "",
            "diabetes_type": diabetes_type,
            "study_arm": "",
        })
    
    pd.DataFrame(participants)[PARTICIPANT_COLUMNS].to_csv(output_dir / "participant.csv", index=False)
    log.info("participant.csv generated.")

    # 3. Process CGM Data & Metadata
    log.info("Reading large CGM file (chunked)...")

    meta_file = output_dir / "cgm_file_metadata.csv"
    meta_id_counter = 1

    # Use --study-start-date as the anchor for all relative day offsets.
    # The CGMND dataset stores relative 'DeviceDtDaysFromEnroll' integers,
    # so we translate each row's relative day into an absolute date.
    anchor_date = datetime.strptime(args.study_start_date, "%Y-%m-%d")

    # Chunked read of the large CGM file
    chunks = pd.read_csv(cgm_file, 
                         usecols=[args.participant_id_column, "DeviceDtDaysFromEnroll", "DeviceTm", "RecordType"],
                         chunksize=CHUNK_SIZE)

    first_write = True

    for chunk in chunks:
        cgm_only = chunk[chunk['RecordType'] == 'CGM']

        meta_records = []
        for _, row in cgm_only.iterrows():
            try:
                day_offset = int(row["DeviceDtDaysFromEnroll"])
            except (TypeError, ValueError):
                # Skip rows with invalid day offsets
                continue

            date_str = (anchor_date + timedelta(days=day_offset)).strftime("%Y-%m-%d")

            meta_records.append({
                "metadata_id": f"META-{meta_id_counter}",
                "devicename": "CGMND Device",
                "device_id": "CGMND-001",
                "source_platform": "Dexcom", # Non-diabetic dataset often uses Dexcom in G6 era
                "patient_id": f"{args.study_id}-{row[args.participant_id_column]}",
                "file_name": cgm_file.stem,
                "file_format": "csv",
                "file_upload_date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                "data_start_date": date_str,
                "data_end_date": date_str,
                "map_field_of_cgm_date": args.timestamp_column,
                "map_field_of_cgm_value": args.cgm_value_column,
                "study_id": args.study_id,
                "map_field_of_patient_id": args.participant_id_column,
            })
            meta_id_counter += 1

        if meta_records:
            pd.DataFrame(meta_records)[METADATA_COLUMNS].to_csv(
                meta_file,
                index=False,
                mode="w" if first_write else "a",
                header=first_write,
            )
            first_write = False

    log.info("cgm_file_metadata.csv generated.")

    # 4. Generate study.csv
    study_info = {
        "study_id": args.study_id,
        "study_name": args.study_name,
        "start_date": args.study_start_date,
        "end_date": args.study_end_date,
        "treatment_modalities": args.treatment_modalities,
        "funding_source": args.funding_source,
        "nct_number": args.nct_number,
        "study_description": args.study_description,
    }
    pd.DataFrame([study_info])[STUDY_COLUMNS].to_csv(output_dir / "study.csv", index=False)
    log.info("study.csv generated.")

def main():
    parser = argparse.ArgumentParser(description="CGMND Content Generator")
    parser.add_argument("--cgm-distribution", default="single_file_all_participants", help="Dataset distribution case")
    parser.add_argument("--cgm-file", required=True)
    parser.add_argument("--input-folder", required=True)
    parser.add_argument("--output-folder", required=True)
    parser.add_argument("--timestamp-column", default="DeviceTm")
    parser.add_argument("--participant-id-column", default="PtID")
    parser.add_argument("--cgm-value-column", default="Value")
    parser.add_argument("--study-id", default="CGMND")
    parser.add_argument("--study-name", default="CGM in Non-Diabetic Participants")
    parser.add_argument("--study-start-date", default="2018-01-01")
    parser.add_argument("--study-end-date", default="2018-12-20")
    parser.add_argument("--treatment-modalities", default="Continuous Glucose Monitoring")
    parser.add_argument("--funding-source", default="T1D Exchange")
    parser.add_argument("--nct-number", default="")
    parser.add_argument("--study-description", default="")
    parser.add_argument("--derive-date-range", type=bool, default=True)

    args = parser.parse_args()
    output_dir = Path(args.output_folder)
    output_dir.mkdir(parents=True, exist_ok=True)

    process_case_cgmnd(args, output_dir)

if __name__ == "__main__":
    main()
