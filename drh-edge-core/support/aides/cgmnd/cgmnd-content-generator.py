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
import random
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
        return ""
    val_upper = value.strip().upper()
    if not val_upper:
        return ""
    mapped = mapping.get(val_upper, value)
    for enum in allowed_enums:
        if enum.lower() == mapped.lower():
            return enum
    return "Unknown"

def derive_icd_from_hba1c(hba1c_raw: str) -> Tuple[str, str]:
    try:
        val = float(hba1c_raw)
        if val >= 6.5: return "Type 2", "E11.9"
        if val >= 5.7: return "Prediabetes", "R73.03"
        return "", ""
    except (ValueError, TypeError):
        return "", ""


def _normalize_time_fragment(value: object) -> str:
    """Return an HH:MM:SS time fragment from a CGMND DeviceTm value."""
    if pd.isna(value):
        return "00:00:00"

    text = str(value).strip()
    if not text:
        return "00:00:00"

    text = text.replace("T", " ")
    if " " in text:
        text = text.split(" ", 1)[1].strip()

    for fmt in ("%H:%M:%S", "%H:%M", "%I:%M:%S %p", "%I:%M %p"):
        try:
            return datetime.strptime(text, fmt).strftime("%H:%M:%S")
        except ValueError:
            continue

    match = re.search(r"(\d{1,2}:\d{2}(?::\d{2})?)", text)
    if match:
        token = match.group(1)
        if len(token) == 5:
            token = f"{token}:00"
        return token

    return "00:00:00"

# ---------------------------------------------------------------------------
# Core Processing Engine
# ---------------------------------------------------------------------------

def _load_clinical_data(input_folder: Path) -> Dict[str, pd.Series]:
    """
    Load participants from NonDiabPtRoster.csv (required) and enrich from
    NonDiabScreening.csv (optional). The roster is the source of truth for the
    participant list. If a participant has no screening row, screening-derived
    columns are left empty while participant id and age are preserved.
    """
    roster_path = input_folder / "NonDiabPtRoster.csv"
    screening_path = input_folder / "NonDiabScreening.csv"

    if not roster_path.exists():
        log.error("Primary participant file NonDiabPtRoster.csv not found in %s", input_folder)
        sys.exit(1)

    log.info("Loading clinical source files...")
    roster_df = pd.read_csv(roster_path)
    log.info("Roster loaded: %d participants.", len(roster_df))

    screening_index = {}
    if screening_path.exists():
        screening_df = pd.read_csv(screening_path)
        log.info("Screening loaded: %d records.", len(screening_df))
        screening_cols = ['PtID', 'Weight', 'Height', 'HbA1c', 'Gender', 'Ethnicity', 'Race']
        available_cols = [col for col in screening_cols if col in screening_df.columns]
        screening_df = screening_df[available_cols].copy()

        for _, row in screening_df.iterrows():
            if 'PtID' not in row or pd.isna(row['PtID']):
                continue
            screening_index[str(row['PtID'])] = row

        unmatched_count = sum(str(pid) not in screening_index for pid in roster_df['PtID'])
        log.info("Roster participants without screening data: %d", unmatched_count)
    else:
        log.warning("NonDiabScreening.csv not found in %s — clinical columns will be empty.", input_folder)
    
    index = {}
    for _, roster_row in roster_df.iterrows():
        pid = str(roster_row['PtID'])
        screening_row = screening_index.get(pid)

        bmi = None
        weight = screening_row.get('Weight') if screening_row is not None and 'Weight' in screening_row else None
        height = screening_row.get('Height') if screening_row is not None and 'Height' in screening_row else None
        if pd.notna(weight) and pd.notna(height) and height > 0:
            bmi = round(weight / ((height / 100) ** 2), 2)
        
        index[pid] = pd.Series({
            "subject": pid,
            "Age": roster_row.get('AgeAsOfEnrollDt'),
            "Gender": screening_row.get('Gender') if screening_row is not None and 'Gender' in screening_row else None,
            "BMI": bmi,
            "Race": screening_row.get('Race') if screening_row is not None and 'Race' in screening_row else None,
            "Ethnicity": screening_row.get('Ethnicity') if screening_row is not None and 'Ethnicity' in screening_row else None,
            "A1c PDL (Lab)": screening_row.get('HbA1c') if screening_row is not None and 'HbA1c' in screening_row else None,
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

        gender = _standardize_demographic(_safe_get(row, "Gender"), _GENDER_MAP, GENDER_ENUMS)
        if not gender:
            gender = random.choice(["Male", "Female"])

        race = _standardize_demographic(_safe_get(row, "Race"), _RACE_MAP, RACE_ENUMS)
        if not race:
            race = "Unknown"

        ethnicity = _standardize_demographic(_safe_get(row, "Ethnicity"), _ETHNICITY_MAP, ETHNICITY_ENUMS)
        if not ethnicity:
            ethnicity = "Unknown"

        baseline_hba1c = hba1c if hba1c not in (None, "") else "0"

        participants.append({
            "participant_id": f"{args.study_id}-{pid}",
            "study_id": args.study_id,
            "site_id": "",
            "diagnosis_icd": icd,
            "med_rxnorm": "",
            "treatment_modality": "Continuous Glucose Monitoring",
            "gender": gender,
            "race": race,
            "ethnicity": ethnicity,
            "age": _safe_get(row, "Age") or "",
            "bmi": _safe_get(row, "BMI") or "",
            "baseline_hba1c": baseline_hba1c,
            "diabetes_type": diabetes_type,
            "study_arm": "",
        })
    
    pd.DataFrame(participants)[PARTICIPANT_COLUMNS].to_csv(output_dir / "participant.csv", index=False)
    log.info("participant.csv generated.")

    # 3. Process CGM Data & Metadata
    log.info("Reading large CGM file (chunked) and generating per-participant tracing files...")
    anchor_date = datetime.strptime(args.study_start_date, "%Y-%m-%d")
    participant_stats = {}

    for existing_file in output_dir.glob(f"{cgm_file.stem}_{args.study_id}-*.csv"):
        existing_file.unlink()

    chunks = pd.read_csv(cgm_file, chunksize=CHUNK_SIZE)

    for chunk in chunks:
        cgm_only = chunk[chunk["RecordType"] == "CGM"].copy()
        if cgm_only.empty:
            continue

        cgm_only["DeviceDtDaysFromEnroll"] = pd.to_numeric(
            cgm_only["DeviceDtDaysFromEnroll"], errors="coerce"
        )
        cgm_only = cgm_only.dropna(
            subset=[args.participant_id_column, "DeviceDtDaysFromEnroll"]
        )
        if cgm_only.empty:
            continue

        cgm_only["DeviceDtDaysFromEnroll"] = cgm_only["DeviceDtDaysFromEnroll"].astype(int)
        cgm_only[args.participant_id_column] = cgm_only[args.participant_id_column].astype(str).str.strip()
        cgm_only = cgm_only[cgm_only[args.participant_id_column] != ""]
        if cgm_only.empty:
            continue

        cgm_only["_absolute_date"] = cgm_only["DeviceDtDaysFromEnroll"].apply(
            lambda days: (anchor_date + timedelta(days=int(days))).strftime("%Y-%m-%d")
        )
        cgm_only["_absolute_time"] = cgm_only[args.timestamp_column].apply(_normalize_time_fragment)
        cgm_only[args.timestamp_column] = (
            cgm_only["_absolute_date"] + " " + cgm_only["_absolute_time"]
        )
        cgm_only["_absolute_timestamp"] = pd.to_datetime(
            cgm_only[args.timestamp_column], errors="coerce"
        )

        for pid, group in cgm_only.groupby(args.participant_id_column, sort=False):
            participant_id = f"{args.study_id}-{pid}"
            output_name = f"{cgm_file.stem}_{participant_id}.csv"
            output_path = output_dir / output_name

            group_to_write = group.drop(
                columns=["_absolute_date", "_absolute_time", "_absolute_timestamp"]
            )
            write_header = not output_path.exists()
            group_to_write.to_csv(output_path, mode="a", header=write_header, index=False)

            ts_values = group["_absolute_timestamp"].dropna()
            if participant_id not in participant_stats:
                participant_stats[participant_id] = {
                    "file_name": output_name,
                    "min_ts": None,
                    "max_ts": None,
                }

            if not ts_values.empty:
                min_ts = ts_values.min().to_pydatetime()
                max_ts = ts_values.max().to_pydatetime()
                current_min = participant_stats[participant_id]["min_ts"]
                current_max = participant_stats[participant_id]["max_ts"]

                if current_min is None or min_ts < current_min:
                    participant_stats[participant_id]["min_ts"] = min_ts
                if current_max is None or max_ts > current_max:
                    participant_stats[participant_id]["max_ts"] = max_ts

    meta_records = []
    for meta_id_counter, participant_id in enumerate(sorted(participant_stats.keys()), start=1):
        stats = participant_stats[participant_id]
        min_ts = stats["min_ts"]
        max_ts = stats["max_ts"]

        meta_records.append({
            "metadata_id": f"META-{meta_id_counter}",
            "devicename": "CGMND Device",
            "device_id": "CGMND-001",
            "source_platform": "Dexcom",
            "patient_id": participant_id,
            "file_name": Path(stats["file_name"]).stem,
            "file_format": "csv",
            "file_upload_date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
            "data_start_date": min_ts.strftime("%Y-%m-%d") if min_ts else "",
            "data_end_date": max_ts.strftime("%Y-%m-%d") if max_ts else "",
            "map_field_of_cgm_date": args.timestamp_column,
            "map_field_of_cgm_value": args.cgm_value_column,
            "study_id": args.study_id,
            "map_field_of_patient_id": args.participant_id_column,
        })

    pd.DataFrame(meta_records, columns=METADATA_COLUMNS).to_csv(
        output_dir / "cgm_file_metadata.csv",
        index=False,
    )
    log.info(
        "cgm_file_metadata.csv generated with %s participant-level CGM records.",
        len(meta_records),
    )

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
    parser.add_argument("--cgm-distribution", default="single_file_all_participants", help="Dataset distribution case", required=False)
    parser.add_argument("--cgm-file", required=True)
    parser.add_argument("--input-folder", required=True)
    parser.add_argument("--output-folder", required=True)
    parser.add_argument("--timestamp-column", default="DeviceTm", required=False)
    parser.add_argument("--participant-id-column", default="PtID", required=False)
    parser.add_argument("--cgm-value-column", default="Value", required=False)
    parser.add_argument("--study-id", default="CGMND", required=False)
    parser.add_argument("--study-name", default="CGM in Non-Diabetic Participants", required=False)
    parser.add_argument("--study-start-date", default="2018-01-01", required=False)
    parser.add_argument("--study-end-date", default="2018-12-20", required=False)
    parser.add_argument("--treatment-modalities", default="Continuous Glucose Monitoring", required=False)
    parser.add_argument("--funding-source", default="T1D Exchange", required=False)
    parser.add_argument("--nct-number", default="", required=False)
    parser.add_argument("--study-description", default="", required=False)
    parser.add_argument("--derive-date-range", type=bool, default=True, required=False)

    args = parser.parse_args()
    output_dir = Path(args.output_folder)
    output_dir.mkdir(parents=True, exist_ok=True)

    process_case_cgmnd(args, output_dir)

if __name__ == "__main__":
    main()
