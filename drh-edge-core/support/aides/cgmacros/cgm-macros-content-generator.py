#!/usr/bin/env python3
"""
cgm-macros-content-generator.py
============================
CLI utility for generating standardised DRH output files for (CGMacros Dataset):
    - study.csv
    - participant.csv
    - cgm_file_metadata.csv

Supports five CGM distribution architectures selectable via --cgm-distribution.
    - Strict regex ID validation for study_id, participant_id, metadata_id
    - derive_icd_from_hba1c() with full ICD-10 mapping
    - Source-platform auto-detection from device name
    - HbA1c → diabetes_type + diagnosis_icd enrichment of participant.csv
    - gut_health_test.csv left-join into participant rows
    - Participant ID preserved as folder/file name (e.g. CGMacros-001)


Special Note on Participant IDs (CGMacros Dataset):
--------------------------------------------------
In this specific dataset, the raw CGM files do NOT contain a participant ID column 
within the CSV data. Instead, the ID is embedded in the filename/foldername 
(e.g., 'CGMacros-001'). 

To handle this, we pass an empty string "" (or a dummy value) to --participant-id-column. 
The script is programmed to detect this and automatically extract the ID from the 
file path/name to ensure correct matching with bio.csv.

Shell-specific usage examples (CGMacros – Case 4, multi-device single folder)
──────────────────────────────────────────────────────────────────────────────

► Git Bash (MINGW64) / macOS Terminal / Ubuntu / WSL
  Line continuation: single backslash  \

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
        --output-folder      "examples/cgm-macros-output1" \
        --study-id           "CGMA" \
        --study-name         "CGMacros: a scientific dataset for personalized nutrition and diet monitoring" \
        --study-start-date   "2021-01-01" \
        --study-end-date     "2024-12-31" \
        --treatment-modalities "Continuous Glucose Monitoring,Food Macronutrient Logging,Physical Activity Tracking,Gut Microbiome Profiling" \
        --funding-source     "National Science Foundation award No. 2014475" \
        --nct-number         "NCT04991142" \
        --study-description  "A dataset containing multimodal information from two CGMs, food macronutrients, food photographs, and physical activity, from 45 participants (15 healthy, 16 pre-diabetes, 14 Type 2 diabetes) over ten consecutive days." \
        --derive-date-range  true

Note:
  --source-platform is optional and auto-detected from the device name:
    "Abbott FreeStyle Libre" → Abbott
    "Dexcom G6 Pro"         → Dexcom


python3 : 3.8+
Deps   : pandas (all others are stdlib)
"""

import argparse
import logging
import os
import re
import sys
import uuid
from datetime import datetime, timezone
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
# ID validation patterns
# ---------------------------------------------------------------------------
# study_id: 4-6 uppercase alphanumeric characters
_STUDY_ID_RE = re.compile(r"^[A-Z0-9]{4,6}$")
# participant_id & metadata_id: starts/ends with [A-Z0-9], middle allows hyphens, 3-14 chars total
_GENERAL_ID_RE = re.compile(r"^[A-Z0-9][A-Z0-9\-]{1,12}[A-Z0-9]$")

# ---------------------------------------------------------------------------
# Demographic mappings & Enums
# ---------------------------------------------------------------------------
_GENDER_MAP = {
    "M": "Male", "MALE": "Male",
    "F": "Female", "FEMALE": "Female",
}
_RACE_MAP = {
    "B": "Black or African American",
    "BLACK": "Black or African American",
    "W": "White",
    "WHITE": "White",
}
_ETHNICITY_MAP = {
    "HISPANIC/LATINO": "Hispanic or Latino",
    "NOT HISPANIC":    "Not Hispanic or Latino",
}

GENDER_ENUMS    = ["Male", "Female", "Other", "Unknown"]
RACE_ENUMS      = [
    "American Indian or Alaska Native", "American Indian", "Asian", "White",
    "Black or African American", "Black", "Native Hawaiian or Other Pacific Islander",
    "Native Hawaiian", "Unknown",
]
ETHNICITY_ENUMS = ["Hispanic or Latino", "Not Hispanic or Latino", "Asked but unknown", "Unknown"]

CHUNK_SIZE = 50_000

# Values that should be treated as placeholders (not actual CSV columns)
_PLACEHOLDERS = {"", "PLACEHOLDER", "FOLDER_ID", "FILENAME", "FOLDERNAME", "DUMMY", "FOLDER_ID_PLACEHOLDER"}

# ---------------------------------------------------------------------------
# Device name → source platform mapping
# ---------------------------------------------------------------------------
_PLATFORM_MAP: Dict[str, str] = {
    "dexcom":    "Dexcom",
    "g4":        "Dexcom",
    "g5":        "Dexcom",
    "g6":        "Dexcom",
    "g7":        "Dexcom",
    "stelo":     "Dexcom",
    "libre":     "Abbott",
    "freestyle": "Abbott",
    "carelink":  "Medtronic",
    "paradigm":  "Medtronic",
    "eversense": "Senseonics",
}

# ===========================================================================
# 1.  ID Validation & Formatting
# ===========================================================================

def validate_study_id(study_id: str) -> None:
    """
    Validate that *study_id* matches ^[A-Z0-9]{4,6}$.
    """
    if not _STUDY_ID_RE.match(study_id or ""):
        log.error(
            "Invalid --study-id '%s'. Must match ^[A-Z0-9]{4,6}$ "
            "(4-6 uppercase alphanumeric characters, no hyphens).",
            study_id,
        )
        sys.exit(1)


def validate_general_id(value: str, label: str) -> None:
    """
    Validate that *value* matches ^[A-Z0-9][A-Z0-9-]{1,12}[A-Z0-9]$.
    """
    if not _GENERAL_ID_RE.match(value or ""):
        log.error(
            "Invalid %s '%s'. Must match ^[A-Z0-9][A-Z0-9-]{1,12}[A-Z0-9]$.",
            label,
            value,
        )
        sys.exit(1)


def format_and_validate_id(
    study_id: str,
    raw_id: str,
    id_prefix: str = "",
    label: str = "id",
) -> str:
    """
    Format and validate a participant or metadata ID.

    If the raw_id is a simple index (digits only) or does not start with the
    study_id, it is prefixed with 'study_id-id_prefix'.

    Validation: ^[A-Z0-9][A-Z0-9-]{1,12}[A-Z0-9]$
    """
    clean_id = str(raw_id).strip()
    if not clean_id:
        log.error("Empty ID provided for %s. Cannot proceed.", label)
        sys.exit(1)

    # Logic: If it already looks like "STUDY-...", use it but validate.
    # Otherwise, prefix it.
    prefix_str = f"{study_id}-"
    if clean_id.startswith(prefix_str):
        # Already prefixed
        formatted_id = clean_id
    else:
        # Needs prefixing
        formatted_id = f"{study_id}-{id_prefix}{clean_id}"

    validate_general_id(formatted_id, label)
    return formatted_id


# ===========================================================================
# 2.  HbA1c → ICD-10 / diabetes_type derivation
# ===========================================================================

def derive_icd_from_hba1c(hba1c_str: str, explicit_type1: bool = False) -> Tuple[str, str]:
    """
    Derive diabetes_type and diagnosis_icd from a raw HbA1c string value.

    Parameters
    ----------
    hba1c_str : str
        Raw HbA1c value as read from bio.csv (may be empty or non-numeric).
    explicit_type1 : bool
        If True, the dataset explicitly states Type 1 diabetes; overrides
        HbA1c-based classification regardless of the numeric value.

    Returns
    -------
    (diabetes_type, diagnosis_icd) : Tuple[str, str]
        Both are empty strings when HbA1c < 5.7 or is non-parseable.

    Classification Rules
    --------------------
    HbA1c < 5.7      → Normal      → diabetes_type='',            diagnosis_icd=''
    5.7 ≤ HbA1c < 6.5→ Prediabetes → diabetes_type='Prediabetes', diagnosis_icd='R73.03'
    HbA1c ≥ 6.5      → Type 2      → diabetes_type='Type 2',      diagnosis_icd='E11.9'
    explicit_type1   → override    → diabetes_type='Type 1',      diagnosis_icd='E10.9'
    """
    # Override: dataset explicitly marks patient as Type 1
    if explicit_type1:
        return "Type 1", "E10.9"

    # Attempt to parse the HbA1c value
    if not hba1c_str or str(hba1c_str).strip() == "":
        return "", ""

    try:
        hba1c = float(str(hba1c_str).strip().replace("%", ""))
    except ValueError:
        log.debug("Cannot parse HbA1c value '%s' – leaving diabetes fields empty.", hba1c_str)
        return "", ""

    if hba1c < 5.7:
        # Normal range
        return "", ""
    elif hba1c < 6.5:
        # Prediabetes: ICD-10 R73.03
        return "Prediabetes", "R73.03"
    else:
        # Type 2 Diabetes: ICD-10 E11.9
        return "Type 2", "E11.9"


# ===========================================================================
# 3.  Source-platform auto-detection
# ===========================================================================

def detect_source_platform(device_name: str, fallback: str) -> str:
    """
    Infer the source platform from a device name string.

    Checks the device name (case-insensitive) against a known keyword map.
    Returns *fallback* when no keyword matches.

    Mapping
    -------
    Dexcom / G4 / G5 / G6 / G7 / Stelo → "Dexcom"
    Libre / FreeStyle                   → "Abbott"
    Carelink / Paradigm                 → "Medtronic"
    Eversense                           → "Senseonics"
    """
    name_lower = device_name.lower()
    for keyword, platform in _PLATFORM_MAP.items():
        if keyword in name_lower:
            return platform
    return fallback


# ===========================================================================
# 4.  CLI Argument Parser
# ===========================================================================

def build_parser() -> argparse.ArgumentParser:
    """
    Build and return the top-level argument parser.

    All arguments are declared here; per-case required-ness is enforced at
    runtime by validate_distribution_args() so we can emit clean errors.
    """
    DIST_CHOICES = [
        "all_participant_cgm_in_one_file",
        "participant_data_in_separate_cgm_files",
        "single_participant_in_multiple_files",
        "multiple_device_cgm_multiple_participants_single_file",
        "multiple_device_cgm_multiple_participants_separate_files",
    ]

    p = argparse.ArgumentParser(
        prog="cgm-macros-content-generator.py",
        description=(
            "Generate study.csv, participant.csv and cgm_file_metadata.csv "
            "from a CGM research dataset folder."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    # ── Distribution ─────────────────────────────────────────────────────────
    p.add_argument(
        "--cgm-distribution",
        required=True,
        choices=DIST_CHOICES,
        metavar="CASE",
        help="CGM distribution architecture. One of:\n  " + "\n  ".join(DIST_CHOICES),
    )

    # ── Global ───────────────────────────────────────────────────────────────
    g = p.add_argument_group("Global (required for all cases)")
    g.add_argument("--input-folder",         help="Root folder of the extracted dataset.")
    g.add_argument("--output-folder",        help="Destination folder for generated CSVs.")
    g.add_argument("--study-id",             help="Unique study ID (4-6 uppercase alphanumeric).")
    g.add_argument("--study-name",           help="Human-readable study name.")
    g.add_argument("--study-start-date",     help="Study start date (YYYY-MM-DD).")
    g.add_argument("--study-end-date",       help="Study end date   (YYYY-MM-DD).")
    g.add_argument("--treatment-modalities", help="Comma-separated list of treatment modalities.")
    g.add_argument("--funding-source",       help="Funding source description.")
    g.add_argument("--nct-number",           help="ClinicalTrials.gov NCT number.")
    g.add_argument("--study-description",    help="Free-text study description.")
    g.add_argument(
        "--source-platform",
        default="",
        help=(
            "CGM source platform label used as a fallback when it cannot be "
            "inferred from the device name.  Leave empty to auto-detect from "
            "device name (Libre/FreeStyle→Abbott, Dexcom/G4-G7/Stelo→Dexcom, "
            "Carelink/Paradigm→Medtronic, Eversense→Senseonics)."
        ),
    )
    g.add_argument(
        "--derive-date-range",
        choices=["true", "false"],
        default="true",
        help=(
            "If 'true' compute data_start/end from actual timestamps. "
            "If 'false' use --start-date / --end-date."
        ),
    )
    g.add_argument("--start-date", help="Override start date (required when --derive-date-range=false).")
    g.add_argument("--end-date",   help="Override end date   (required when --derive-date-range=false).")

    # ── Case 1-3 ─────────────────────────────────────────────────────────────
    s = p.add_argument_group("Case 1-3 arguments")
    s.add_argument("--cgm-file",             help="(Case 1/4) Path to single CGM CSV file or root folder.")
    s.add_argument("--cgm-folder",           help="(Case 2/3) Folder containing CGM CSV files.")
    s.add_argument("--timestamp-column",     help="Column name holding the CGM timestamp.")
    s.add_argument("--cgm-value-column",     help="Column name holding the CGM glucose value.")
    s.add_argument(
        "--participant-id-column",
        default="",
        help="Column name holding participant ID.  Leave empty to derive from filename.",
    )

    # ── Case 4 ───────────────────────────────────────────────────────────────
    d4 = p.add_argument_group("Case 4 – multi-device, single file/folder")
    d4.add_argument("--device1-name",       help="Display name of device 1.")
    d4.add_argument("--device1-id",         help="Identifier string for device 1.")
    d4.add_argument("--device1-cgm-column", help="CGM column name for device 1.")
    d4.add_argument("--device2-name",       help="Display name of device 2.")
    d4.add_argument("--device2-id",         help="Identifier string for device 2.")
    d4.add_argument("--device2-cgm-column", help="CGM column name for device 2.")

    # ── Case 5 ───────────────────────────────────────────────────────────────
    d5 = p.add_argument_group("Case 5 – multi-device, separate folders")
    d5.add_argument("--device1-folder",           help="Folder for device-1 files.")
    d5.add_argument("--device1-timestamp-column", help="Timestamp column in device-1 files.")
    d5.add_argument("--device2-folder",           help="Folder for device-2 files.")
    d5.add_argument("--device2-timestamp-column", help="Timestamp column in device-2 files.")

    return p


# ===========================================================================
# 5.  Argument Validation
# ===========================================================================

def _require(args: argparse.Namespace, fields: List[str], context: str) -> None:
    """Exit with an error if any field in *fields* is missing on *args*."""
    missing = [f for f in fields if not getattr(args, f.replace("-", "_"), None)]
    if missing:
        log.error(
            "[%s] Missing required argument(s): %s",
            context,
            ", ".join(f"--{f.replace('_', '-')}" for f in missing),
        )
        sys.exit(1)


def validate_distribution_args(args: argparse.Namespace) -> None:
    """
    Enforce per-case required arguments and global constraints.

    Also validates study_id format and folder existence.
    Exits with descriptive errors on any violation.
    """
    dist = args.cgm_distribution

    # ── Global ───────────────────────────────────────────────────────────────
    # source_platform is intentionally excluded here – it is auto-inferred
    # from the device name via detect_source_platform() and may be left blank.
    _require(
        args,
        [
            "input_folder", "output_folder", "study_id", "study_name",
            "study_start_date", "study_end_date", "treatment_modalities",
            "funding_source", "nct_number", "study_description",
        ],
        "global",
    )

    # Validate study_id format
    validate_study_id(args.study_id)

    # derive-date-range=false → start/end dates required
    if args.derive_date_range == "false":
        _require(args, ["start_date", "end_date"], "derive-date-range=false")

    # ── Per-case ─────────────────────────────────────────────────────────────
    if dist == "all_participant_cgm_in_one_file":
        _require(
            args,
            ["cgm_file", "timestamp_column", "cgm_value_column", "participant_id_column"],
            dist,
        )

    elif dist == "participant_data_in_separate_cgm_files":
        _require(args, ["cgm_folder", "timestamp_column", "cgm_value_column"], dist)

    elif dist == "single_participant_in_multiple_files":
        _require(args, ["cgm_folder", "timestamp_column", "cgm_value_column"], dist)

    elif dist == "multiple_device_cgm_multiple_participants_single_file":
        _require(
            args,
            [
                "cgm_file", "timestamp_column", "participant_id_column",
                "device1_name", "device1_id", "device1_cgm_column",
                "device2_name", "device2_id", "device2_cgm_column",
            ],
            dist,
        )

    elif dist == "multiple_device_cgm_multiple_participants_separate_files":
        _require(
            args,
            [
                "device1_folder", "device1_name", "device1_id",
                "device1_timestamp_column", "device1_cgm_column",
                "device2_folder", "device2_name", "device2_id",
                "device2_timestamp_column", "device2_cgm_column",
                "participant_id_column",
            ],
            dist,
        )

    # ── Folder existence ─────────────────────────────────────────────────────
    if not Path(args.input_folder).is_dir():
        log.error("--input-folder not found or not a directory: %s", args.input_folder)
        sys.exit(1)

    log.info("Argument validation passed for distribution case: %s", dist)


# ===========================================================================
# 6.  Study CSV
# ===========================================================================

def generate_study_file(args: argparse.Namespace, output_dir: Path) -> None:
    """
    Write study.csv with exactly one row sourced entirely from CLI arguments.

    Columns (in order):
        study_id, study_name, start_date, end_date, treatment_modalities,
        funding_source, nct_number, study_description
    """
    log.info("Generating study.csv …")
    row = {
        "study_id":             args.study_id,
        "study_name":           args.study_name,
        "start_date":           args.study_start_date,
        "end_date":             args.study_end_date,
        "treatment_modalities": args.treatment_modalities,
        "funding_source":       args.funding_source,
        "nct_number":           args.nct_number,
        "study_description":    args.study_description,
    }
    df = pd.DataFrame([row], columns=STUDY_COLUMNS)
    out_path = output_dir / "study.csv"
    df.to_csv(out_path, index=False)
    log.info("study.csv written → %s", out_path)


# ===========================================================================
# 7.  Bio / Gut-health loaders
# ===========================================================================

# Known column names in bio.csv and their DRH schema mappings
_BIO_COL_MAP = {
    "subject":         "participant_id",
    "Age":             "age",
    "Gender":          "gender",
    "BMI":             "bmi",
    "Self-identify":   "race",       # used as both race and ethnicity
    "A1c PDL (Lab)":   "baseline_hba1c",
    "diabetes_type":   "diabetes_type_explicit",  # explicit Type 1 flag if present
}

_GENDER_NORM = {"M": "M", "F": "F", "MALE": "M", "FEMALE": "F"}


def _load_bio_data(input_folder: Path) -> pd.DataFrame:
    """
    Load bio.csv from *input_folder*.

    Returns a DataFrame with string types.
    Exits if the file is missing or the 'subject' column is absent.
    """
    bio_path = input_folder / "bio.csv"
    if not bio_path.exists():
        log.error("Required file not found: %s", bio_path)
        sys.exit(1)

    log.info("Loading bio.csv from %s", bio_path)
    bio = pd.read_csv(bio_path, dtype=str)
    bio.columns = bio.columns.str.strip()

    if "subject" not in bio.columns:
        log.error("bio.csv is missing the required 'subject' column.")
        sys.exit(1)

    bio["subject"] = bio["subject"].str.strip()
    return bio


def _load_gut_health_data(input_folder: Path) -> Optional[pd.DataFrame]:
    """
    Load gut_health_test.csv from *input_folder* if it exists.

    Returns None (non-fatal) when the file is absent.
    """
    gut_path = input_folder / "gut_health_test.csv"
    if not gut_path.exists():
        log.warning("gut_health_test.csv not found at %s – skipping.", gut_path)
        return None

    log.info("Loading gut_health_test.csv from %s", gut_path)
    gut = pd.read_csv(gut_path, dtype=str)
    gut.columns = gut.columns.str.strip()
    if "subject" in gut.columns:
        gut["subject"] = gut["subject"].str.strip()
    return gut


def _safe_get(series: Optional[pd.Series], col: str) -> Optional[str]:
    """Return stripped string value from *series* for *col*, or None if absent/nan."""
    if series is None:
        return None
    val = series.get(col, None)
    if pd.isna(val):
        return None
    res = str(val).strip()
    return res if res != "" else None


def _standardize_demographic(
    value: Optional[str],
    mapping: Dict[str, str],
    allowed_enums: List[str],
) -> Optional[str]:
    """
    Map shorthand/variations of demographic values to standardized Enums.
    Returns None if value is missing. Returns "Unknown" if no match found.
    """
    if value is None:
        return None

    val_upper = value.upper()
    # 1. Check mapping
    mapped = mapping.get(val_upper, value)

    # 2. Check allowed list (case-insensitive)
    for enum in allowed_enums:
        if enum.lower() == mapped.lower():
            return enum

    return "Unknown"


# ===========================================================================
# 8.  Participant CSV builder
# ===========================================================================

def _build_participant_row(
    raw_pid: str,
    study_id: str,
    bio_row: Optional[pd.Series],
    gut_row: Optional[pd.Series] = None,
) -> Dict:
    """
    Construct a participant row dict with standardized Enums and IDs.
    """
    participant_id = format_and_validate_id(study_id, raw_pid, label="participant_id")

    hba1c_val = _safe_get(bio_row, "A1c PDL (Lab)")
    hba1c_str = hba1c_val or ""

    # Gender mapping
    raw_gender = _safe_get(bio_row, "Gender")
    gender = _standardize_demographic(raw_gender, _GENDER_MAP, GENDER_ENUMS)

    # Race/Ethnicity mapping (often the same column in bio.csv)
    raw_demo = _safe_get(bio_row, "Self-identify")
    race = _standardize_demographic(raw_demo, _RACE_MAP, RACE_ENUMS)
    ethnicity = _standardize_demographic(raw_demo, _ETHNICITY_MAP, ETHNICITY_ENUMS)

    # Check for an explicit diabetes_type column in bio.csv
    explicit_t1 = False
    dt_explicit = (_safe_get(bio_row, "diabetes_type") or "").lower()
    if dt_explicit in ("type 1", "type1", "t1", "e10.9"):
        explicit_t1 = True

    diabetes_type, diagnosis_icd = derive_icd_from_hba1c(hba1c_str, explicit_type1=explicit_t1)

    return {
        "participant_id":     participant_id,
        "study_id":           study_id,
        "site_id":            "",
        "diagnosis_icd":      diagnosis_icd,
        "med_rxnorm":         "",
        "treatment_modality": "",
        "gender":             gender,
        "race":               race,
        "ethnicity":          ethnicity,
        "age":                _safe_get(bio_row, "Age") or "",
        "bmi":                _safe_get(bio_row, "BMI") or "",
        "baseline_hba1c":     hba1c_str,
        "diabetes_type":      diabetes_type,
        "study_arm":          "",
    }


def process_participants(
    participant_ids: List[str],
    study_id: str,
    input_folder: Path,
    output_dir: Path,
    require_bio: bool = True,
) -> List[str]:
    """
    Generate participant.csv by joining participant IDs with bio.csv
    and optionally gut_health_test.csv.

    Each participant receives exactly one row.  HbA1c-based ICD-10 mapping
    is applied automatically.  Participants not found in bio.csv receive
    empty demographic fields and a warning.

    Parameters
    ----------
    participant_ids : list of str
        Discovered participant IDs.
    study_id : str
        Injected into every row.
    input_folder : Path
        Must contain bio.csv when *require_bio* is True.
    output_dir : Path
        Destination directory.
    require_bio : bool
        Fail hard if bio.csv is absent.

    Returns
    -------
    List[str]
        Sorted, deduplicated list of participant IDs written to the file.
    """
    log.info("Processing participants (%d discovered) …", len(participant_ids))

    # ── Load bio.csv ──────────────────────────────────────────────────────
    bio_index: Dict[str, pd.Series] = {}
    bio_path = input_folder / "bio.csv"
    if bio_path.exists():
        bio_df = _load_bio_data(input_folder)
        bio_index = {row["subject"]: row for _, row in bio_df.iterrows()}
        log.info("bio.csv loaded – %d records.", len(bio_df))
    else:
        if require_bio:
            log.error("bio.csv is required but not found at: %s", input_folder)
            sys.exit(1)
        log.warning("bio.csv not found – demographic fields will be empty.")

    # ── Load gut_health_test.csv (optional) ──────────────────────────────
    gut_index: Dict[str, pd.Series] = {}
    gut_df = _load_gut_health_data(input_folder)
    if gut_df is not None and "subject" in gut_df.columns:
        gut_index = {row["subject"]: row for _, row in gut_df.iterrows()}
        log.info("gut_health_test.csv loaded – %d records.", len(gut_df))

    # ── Build participant rows ────────────────────────────────────────────
    rows = []
    for pid in sorted(set(participant_ids)):
        bio_row = bio_index.get(str(pid))
        gut_row = gut_index.get(str(pid))
        if bio_row is None:
            log.warning(
                "Participant '%s' has no matching bio.csv record – using empty demographics.", pid
            )
        rows.append(_build_participant_row(str(pid), study_id, bio_row, gut_row))

    df = pd.DataFrame(rows, columns=PARTICIPANT_COLUMNS)
    out_path = output_dir / "participant.csv"
    df.to_csv(out_path, index=False)
    log.info("participant.csv written → %s  (%d rows)", out_path, len(df))
    return sorted(set(str(p) for p in participant_ids))


# ===========================================================================
# 9.  Metadata helpers
# ===========================================================================

def _now_utc_date() -> str:
    """Return current UTC date as YYYY-MM-DD string."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _detect_format(file_name: str) -> str:
    """Return lower-cased file extension without leading dot, defaulting to 'csv'."""
    ext = Path(file_name).suffix
    return ext.lstrip(".").lower() if ext else "csv"


def _build_metadata_record(
    *,
    device_name: str,
    device_id: str,
    source_platform: str,
    patient_id: str,
    file_name: str,
    timestamp_col: str,
    cgm_value_col: str,
    participant_id_col: str,
    study_id: str,
    data_start: str,
    data_end: str,
    meta_index: int,  # Added meta_index
) -> Dict:
    """
    Construct a single cgm_file_metadata row dict.
    metadata_id is generated as 'META-<integer>'.
    """
    # 1. Standardize the participant/patient ID
    final_patient_id = format_and_validate_id(study_id, patient_id, label="participant_id")

    # 2. Use the unique incrementing integer
    metadata_id = f"META-{meta_index}"

    # 3. Clean up map_field_of_patient_id
    raw_col = str(participant_id_col or "").strip().upper()
    if raw_col in _PLACEHOLDERS or "PLACEHOLDER" in raw_col:
        final_patient_id_col = ""
    else:
        final_patient_id_col = participant_id_col

    auto_platform = detect_source_platform(device_name, fallback=source_platform)
    
    return {
        "metadata_id":             metadata_id,
        "devicename":              device_name,
        "device_id":               device_id,
        "source_platform":         auto_platform,
        "patient_id":              final_patient_id,
        "file_name":               Path(file_name).stem,
        "file_format":             _detect_format(file_name),
        "file_upload_date":        _now_utc_date(),
        "data_start_date":         data_start,
        "data_end_date":           data_end,
        "map_field_of_cgm_date":   timestamp_col,
        "map_field_of_cgm_value":  cgm_value_col,
        "study_id":                study_id,
        "map_field_of_patient_id": final_patient_id_col,
    }

def generate_metadata(records: List[Dict], output_dir: Path) -> None:
    """Write cgm_file_metadata.csv from a list of record dicts."""
    log.info("Writing cgm_file_metadata.csv (%d records) …", len(records))
    df = pd.DataFrame(records, columns=METADATA_COLUMNS)
    out_path = output_dir / "cgm_file_metadata.csv"
    df.to_csv(out_path, index=False)
    log.info("cgm_file_metadata.csv written → %s", out_path)


def _date_range_from_series(
    ts_series: pd.Series,
    args: argparse.Namespace,
) -> Tuple[str, str]:
    """
    Return (data_start_date, data_end_date) as ISO date strings.

    Uses actual min/max of *ts_series* when --derive-date-range=true;
    otherwise returns the CLI --start-date / --end-date values.
    """
    if args.derive_date_range == "true":
        ts = pd.to_datetime(ts_series, errors="coerce").dropna()
        if ts.empty:
            log.warning("No parseable timestamps – using CLI date range.")
            return args.start_date or "", args.end_date or ""
        return str(ts.min().date()), str(ts.max().date())
    return args.start_date or "", args.end_date or ""


# ===========================================================================
# 10.  Low-level CSV I/O helpers
# ===========================================================================

def _read_chunked(file_path: str, usecols: Optional[List[str]] = None) -> pd.DataFrame:
    """
    Read a potentially large CSV in CHUNK_SIZE-row chunks and concatenate.

    Parameters
    ----------
    file_path : str
        Path to the CSV.
    usecols : list of str, optional
        Subset of columns to load (improves memory efficiency on wide files).
    """
    chunks = []
    for chunk in pd.read_csv(
        file_path,
        chunksize=CHUNK_SIZE,
        usecols=usecols,
        dtype=str,
        low_memory=False,
    ):
        chunks.append(chunk)
    if not chunks:
        return pd.DataFrame(columns=usecols or [])
    return pd.concat(chunks, ignore_index=True)


def _assert_columns(actual: List[str], expected: List[str], file_path: str) -> None:
    """
    Verify all *expected* column names exist in *actual*.

    Skips empty-string entries (optional columns).
    Exits with a descriptive error on any missing column.
    """
    missing = [c for c in expected if c and c not in actual]
    if missing:
        log.error(
            "Required column(s) missing in '%s':\n  Missing : %s\n  Found   : %s",
            file_path, missing, actual,
        )
        sys.exit(1)


def _safe_usecols(csv_path: Path, preferred_cols: List[str]) -> Optional[List[str]]:
    """
    Return the intersection of *preferred_cols* with the CSV's actual columns.

    Returns None if the header cannot be read (causes pandas to load all).
    """
    try:
        header = pd.read_csv(csv_path, nrows=0).columns.tolist()
        result = [c for c in preferred_cols if c and c in header]
        return result if result else None
    except Exception:
        return None


def _extract_numeric_id(name: str) -> str:
    """
    Extract a clean participant identifier from a folder or file stem.

    Strips leading zeros so 'CGMacros-001' → '1'.
    Falls back to the raw name when no numeric portion is found.

    Examples
    --------
    >>> _extract_numeric_id("CGMacros-001")
    '1'
    >>> _extract_numeric_id("Subject_042")
    '42'
    >>> _extract_numeric_id("PATIENTX")
    'PATIENTX'
    """
    m = re.search(r"\d+", name)
    if m:
        return str(int(m.group()))
    return name


def _participant_id_from_file(csv_path: Path, participant_id_col: str) -> str:
    """
    Derive participant ID from *csv_path*.

    Priority:
        1. First non-null value in *participant_id_col* (if column is provided)
        2. File stem (e.g. 'CGMacros-001.csv' → '1')
    """
    if participant_id_col:
        try:
            first = pd.read_csv(csv_path, nrows=1, dtype=str)
            if participant_id_col in first.columns:
                val = first[participant_id_col].iloc[0]
                if pd.notna(val):
                    return str(val).strip()
        except Exception:
            pass
    return _extract_numeric_id(csv_path.stem)


def _participant_id_from_path(
    csv_path: Path,
    base_folder: Path,
    participant_id_col: str,
) -> str:
    """
    Derive participant ID considering the folder hierarchy.

    Priority:
        1. participant_id_col column value from the file
        2. Immediate parent directory name (when it differs from base_folder)
        3. File stem
    """
    if participant_id_col:
        try:
            first = pd.read_csv(csv_path, nrows=1, dtype=str)
            if participant_id_col in first.columns:
                val = first[participant_id_col].iloc[0]
                if pd.notna(val):
                    return str(val).strip()
        except Exception:
            pass

    parent = csv_path.parent
    if parent != base_folder and parent.name:
        return _extract_numeric_id(parent.name)
    return _extract_numeric_id(csv_path.stem)


# ===========================================================================
# 11.  Case Processors
# ===========================================================================

# Non-CGM files that must be excluded from CGM scanning
_SKIP_NAMES = frozenset({"bio.csv", "gut_health_test.csv", "microbes.csv"})


# ---------------------------------------------------------------------------
# CASE 1 – all_participant_cgm_in_one_file
# ---------------------------------------------------------------------------

def process_case_1(args: argparse.Namespace, output_dir: Path) -> None:
    """
    Process Case 1: all CGM data for all participants stored in a single file.

    One metadata row is generated per unique participant found in the
    participant-id column.  The same file is referenced for every row.

    Required CLI flags:
        --cgm-file, --timestamp-column, --cgm-value-column,
        --participant-id-column
    """
    log.info("[Case 1] Processing single combined CGM file …")
    cgm_file = args.cgm_file

    if not Path(cgm_file).is_file():
        log.error("--cgm-file not found: %s", cgm_file)
        sys.exit(1)

    # Validate required columns exist before reading the whole file
    header = pd.read_csv(cgm_file, nrows=0)
    _assert_columns(
        header.columns.tolist(),
        [args.timestamp_column, args.cgm_value_column, args.participant_id_column],
        cgm_file,
    )

    log.info("Reading %s (chunked) …", cgm_file)
    df = _read_chunked(
        cgm_file,
        usecols=[args.timestamp_column, args.cgm_value_column, args.participant_id_column],
    )

    participants = df[args.participant_id_column].dropna().unique().tolist()
    log.info("Found %d participants in file.", len(participants))

    process_participants(
        [str(p) for p in participants],
        args.study_id,
        Path(args.input_folder),
        output_dir,
        require_bio=False,
    )

    meta_records = []
    for pid in participants:
        sub = df[df[args.participant_id_column] == pid]
        start, end = _date_range_from_series(sub[args.timestamp_column], args)
        platform = detect_source_platform(args.source_platform, args.source_platform)
        meta_records.append(
            _build_metadata_record(
                device_name=args.source_platform,
                device_id=args.source_platform,
                source_platform=platform,
                patient_id=str(pid),
                file_name=Path(cgm_file).name,
                timestamp_col=args.timestamp_column,
                cgm_value_col=args.cgm_value_column,
                participant_id_col=args.participant_id_column,
                study_id=args.study_id,
                data_start=start,
                data_end=end,
            )
        )
    generate_metadata(meta_records, output_dir)


# ---------------------------------------------------------------------------
# CASE 2 – participant_data_in_separate_cgm_files
# ---------------------------------------------------------------------------

def process_case_2(args: argparse.Namespace, output_dir: Path) -> None:
    """
    Process Case 2: one CGM CSV file per participant.

    Participant ID is derived from the file name stem (or from
    --participant-id-column when provided).  One metadata row per file.

    Required CLI flags:
        --cgm-folder, --timestamp-column, --cgm-value-column
    Optional:
        --participant-id-column
    """
    log.info("[Case 2] Processing separate CGM files (one per participant) …")
    cgm_folder = Path(args.cgm_folder)
    if not cgm_folder.is_dir():
        log.error("--cgm-folder not found: %s", cgm_folder)
        sys.exit(1)

    csv_files = sorted(f for f in cgm_folder.glob("*.csv") if f.name.lower() not in _SKIP_NAMES)
    if not csv_files:
        log.error("No CGM CSV files found in --cgm-folder: %s", cgm_folder)
        sys.exit(1)

    log.info("Found %d CGM file(s) in %s.", len(csv_files), cgm_folder)
    participants: List[str] = []
    meta_records: List[Dict] = []

    for csv_path in csv_files:
        pid = _participant_id_from_file(csv_path, args.participant_id_column)
        participants.append(pid)

        try:
            cols = _safe_usecols(csv_path, [args.timestamp_column])
            df = _read_chunked(str(csv_path), usecols=cols)
        except Exception as exc:
            log.warning("Could not read %s: %s – skipping.", csv_path.name, exc)
            continue

        _assert_columns(df.columns.tolist(), [args.timestamp_column], str(csv_path))
        start, end = _date_range_from_series(df[args.timestamp_column], args)

        meta_records.append(
            _build_metadata_record(
                device_name=args.source_platform,
                device_id=args.source_platform,
                source_platform=detect_source_platform(args.source_platform, args.source_platform),
                patient_id=pid,
                file_name=csv_path.name,
                timestamp_col=args.timestamp_column,
                cgm_value_col=args.cgm_value_column,
                participant_id_col=args.participant_id_column or "filename",
                study_id=args.study_id,
                data_start=start,
                data_end=end,
            )
        )

    process_participants(participants, args.study_id, Path(args.input_folder), output_dir)
    generate_metadata(meta_records, output_dir)


# ---------------------------------------------------------------------------
# CASE 3 – single_participant_in_multiple_files
# ---------------------------------------------------------------------------

def process_case_3(args: argparse.Namespace, output_dir: Path) -> None:
    """
    Process Case 3: multiple CGM files per participant.

    The script walks --cgm-folder recursively.  Subdirectories are treated as
    participant groupings; participant ID is derived from the immediate parent
    folder name or the file stem.  One metadata row per file.

    Also supports the CGMacros folder layout:
        CGMacros/CGMacros-001/CGMacros-001.csv  → participant '1'

    Required CLI flags:
        --cgm-folder, --timestamp-column, --cgm-value-column
    Optional:
        --participant-id-column
    """
    log.info("[Case 3] Walking folder tree for per-participant CGM files …")
    cgm_folder = Path(args.cgm_folder)
    if not cgm_folder.is_dir():
        log.error("--cgm-folder not found: %s", cgm_folder)
        sys.exit(1)

    all_csv = sorted(
        f for f in cgm_folder.rglob("*.csv") if f.name.lower() not in _SKIP_NAMES
    )
    if not all_csv:
        log.error("No CGM CSV files found recursively in: %s", cgm_folder)
        sys.exit(1)

    log.info("Found %d CGM file(s) across folder tree.", len(all_csv))
    participants: List[str] = []
    meta_records: List[Dict] = []

    for csv_path in all_csv:
        pid = _participant_id_from_path(csv_path, cgm_folder, args.participant_id_column)
        participants.append(pid)

        try:
            cols = _safe_usecols(csv_path, [args.timestamp_column])
            df = _read_chunked(str(csv_path), usecols=cols)
        except Exception as exc:
            log.warning("Could not read %s: %s – skipping.", csv_path.name, exc)
            continue

        if args.timestamp_column not in df.columns:
            log.warning(
                "Timestamp column '%s' not found in %s – skipping.",
                args.timestamp_column, csv_path.name,
            )
            start, end = "", ""
        else:
            start, end = _date_range_from_series(df[args.timestamp_column], args)

        meta_records.append(
            _build_metadata_record(
                device_name=args.source_platform,
                device_id=args.source_platform,
                source_platform=detect_source_platform(args.source_platform, args.source_platform),
                patient_id=pid,
                file_name=csv_path.name,
                timestamp_col=args.timestamp_column,
                cgm_value_col=args.cgm_value_column,
                participant_id_col=args.participant_id_column or "foldername",
                study_id=args.study_id,
                data_start=start,
                data_end=end,
            )
        )

    process_participants(participants, args.study_id, Path(args.input_folder), output_dir)
    generate_metadata(meta_records, output_dir)


# ---------------------------------------------------------------------------
# CASE 4 – multiple_device_cgm_multiple_participants_single_file (CGMacros)
# ---------------------------------------------------------------------------

def process_case_4(args: argparse.Namespace, output_dir: Path) -> None:
    """
    Process Case 4 (CGMacros): multiple devices, multiple participants.

    --cgm-file may point to:
        a) A literal CSV file containing both device columns and a
           participant-id column.
        b) A root directory following the CGMacros layout:
               <root>/<PXXX>/<PXXX>.csv
           Participant ID is derived from the sub-folder name.

    For each participant × device combination the script:
        1. Extracts device-specific CGM column.
        2. Computes date range (or uses CLI override).
        3. Emits one metadata row per participant per device.

    Required CLI flags:
        --cgm-file, --timestamp-column, --participant-id-column
        --device1-name, --device1-id, --device1-cgm-column
        --device2-name, --device2-id, --device2-cgm-column
    """
    log.info("[Case 4] Processing multi-device, multi-participant dataset …")
    cgm_path = Path(args.cgm_file)

    if cgm_path.is_file():
        _process_case_4_single_file(cgm_path, args, output_dir)
    elif cgm_path.is_dir():
        _process_case_4_folder(cgm_path, args, output_dir)
    else:
        log.error("--cgm-file must be an existing file or directory: %s", cgm_path)
        sys.exit(1)


def _process_case_4_single_file(
    cgm_path: Path,
    args: argparse.Namespace,
    output_dir: Path,
) -> None:
    """Case 4 sub-handler: all participants + devices in one CSV."""
    log.info("  [Case 4] Reading single combined file: %s", cgm_path)

    required_cols = [
        args.timestamp_column,
        args.participant_id_column,
        args.device1_cgm_column,
        args.device2_cgm_column,
    ]
    header = pd.read_csv(cgm_path, nrows=0)
    _assert_columns(header.columns.tolist(), required_cols, str(cgm_path))

    df = _read_chunked(str(cgm_path), usecols=required_cols)
    participants = df[args.participant_id_column].dropna().unique().tolist()
    log.info("  Found %d participants.", len(participants))

    devices = [
        (args.device1_name, args.device1_id, args.device1_cgm_column),
        (args.device2_name, args.device2_id, args.device2_cgm_column),
    ]
    meta_records: List[Dict] = []

    for pid in participants:
        sub = df[df[args.participant_id_column] == pid]
        for dev_name, dev_id, dev_col in devices:
            dev_sub = sub[sub[dev_col].notna()]
            start, end = _date_range_from_series(dev_sub[args.timestamp_column], args)
            meta_records.append(
                _build_metadata_record(
                    device_name=dev_name,
                    device_id=dev_id,
                    source_platform=detect_source_platform(dev_name, args.source_platform),
                    patient_id=str(pid),
                    file_name=cgm_path.name,
                    timestamp_col=args.timestamp_column,
                    cgm_value_col=dev_col,
                    participant_id_col=args.participant_id_column,
                    study_id=args.study_id,
                    data_start=start,
                    data_end=end,
                )
            )

    process_participants(
        [str(p) for p in participants],
        args.study_id,
        Path(args.input_folder),
        output_dir,
    )
    generate_metadata(meta_records, output_dir)


def _process_case_4_folder(
    cgm_folder: Path,
    args: argparse.Namespace,
    output_dir: Path,
) -> None:
    """
    Case 4 sub-handler: CGMacros layout.

    Expects sub-directories each containing a CSV named after the folder.
    Only device columns actually present in a file are processed (graceful
    degradation when a device column is absent for a particular participant).
    """
    log.info("  [Case 4] Traversing CGMacros layout under: %s", cgm_folder)
    sub_dirs = sorted(d for d in cgm_folder.iterdir() if d.is_dir())
    if not sub_dirs:
        log.error("No sub-directories found in: %s", cgm_folder)
        sys.exit(1)

    devices = [
        (args.device1_name, args.device1_id, args.device1_cgm_column),
        (args.device2_name, args.device2_id, args.device2_cgm_column),
    ]

    participants: List[str] = []
    meta_records: List[Dict] = []
    meta_counter = 1  # Initialize counter

    for sub_dir in sub_dirs:
        pid = _extract_numeric_id(sub_dir.name)
        participants.append(pid)

        csv_files = [f for f in sub_dir.glob("*.csv") if f.name.lower() not in _SKIP_NAMES]
        if not csv_files:
            log.warning("No CSV found in %s – skipping.", sub_dir)
            continue

        csv_path = csv_files[0]
        log.debug("  Participant %s → %s", pid, csv_path.name)

        try:
            available = pd.read_csv(csv_path, nrows=0).columns.tolist()
        except Exception as exc:
            log.warning("Cannot open %s: %s – skipping.", csv_path, exc)
            continue

        # Only load device columns that actually exist in this file
        present_devices = [(dn, di, dc) for dn, di, dc in devices if dc in available]
        if not present_devices:
            log.warning(
                "No device column found in %s – skipping metadata for participant %s.",
                csv_path.name, pid,
            )
            continue

        read_cols = [args.timestamp_column] + [dc for _, _, dc in present_devices]
        try:
            df = _read_chunked(str(csv_path), usecols=read_cols)
        except Exception as exc:
            log.warning("Error reading %s: %s – skipping.", csv_path.name, exc)
            continue

        for dev_name, dev_id, dev_col in present_devices:
            if dev_col not in df.columns:
                continue
            dev_sub = df[df[dev_col].notna()]
            start, end = _date_range_from_series(dev_sub[args.timestamp_column], args)
            meta_records.append(
                _build_metadata_record(
                    meta_index=meta_counter, # Pass the counter
                    device_name=dev_name,
                    device_id=dev_id,
                    source_platform=detect_source_platform(dev_name, args.source_platform),
                    patient_id=pid,
                    file_name=csv_path.name,
                    timestamp_col=args.timestamp_column,
                    cgm_value_col=dev_col,
                    participant_id_col=args.participant_id_column or "",
                    study_id=args.study_id,
                    data_start=start,
                    data_end=end,
                )
            )
            meta_counter += 1

    process_participants(participants, args.study_id, Path(args.input_folder), output_dir)
    generate_metadata(meta_records, output_dir)


# ---------------------------------------------------------------------------
# CASE 5 – multiple_device_cgm_multiple_participants_separate_files
# ---------------------------------------------------------------------------

def process_case_5(args: argparse.Namespace, output_dir: Path) -> None:
    """
    Process Case 5: multiple devices stored in separate folders.

    Both device folders are walked independently.  Participant IDs are
    derived from file names or --participant-id-column.  One metadata row
    per participant per device file.

    Required CLI flags:
        --device1-folder, --device1-name, --device1-id,
        --device1-timestamp-column, --device1-cgm-column
        --device2-folder, --device2-name, --device2-id,
        --device2-timestamp-column, --device2-cgm-column
        --participant-id-column
    """
    log.info("[Case 5] Processing multi-device separate folders …")

    devices = [
        {
            "folder":  Path(args.device1_folder),
            "name":    args.device1_name,
            "id":      args.device1_id,
            "ts_col":  args.device1_timestamp_column,
            "cgm_col": args.device1_cgm_column,
        },
        {
            "folder":  Path(args.device2_folder),
            "name":    args.device2_name,
            "id":      args.device2_id,
            "ts_col":  args.device2_timestamp_column,
            "cgm_col": args.device2_cgm_column,
        },
    ]

    for dev in devices:
        if not dev["folder"].is_dir():
            log.error("Device folder not found: %s", dev["folder"])
            sys.exit(1)

    participants: List[str] = []
    meta_records: List[Dict] = []

    for dev in devices:
        csv_files = sorted(
            f for f in dev["folder"].glob("*.csv") if f.name.lower() not in _SKIP_NAMES
        )
        log.info("Device '%s': %d file(s) found.", dev["name"], len(csv_files))

        for csv_path in csv_files:
            pid = _participant_id_from_file(csv_path, args.participant_id_column)
            participants.append(pid)

            try:
                cols = _safe_usecols(csv_path, [dev["ts_col"]])
                df = _read_chunked(str(csv_path), usecols=cols)
            except Exception as exc:
                log.warning("Cannot read %s: %s – skipping.", csv_path.name, exc)
                continue

            ts_col = dev["ts_col"]
            start, end = _date_range_from_series(
                df[ts_col] if ts_col in df.columns else pd.Series(dtype=str),
                args,
            )
            meta_records.append(
                _build_metadata_record(
                    device_name=dev["name"],
                    device_id=dev["id"],
                    source_platform=detect_source_platform(dev["name"], args.source_platform),
                    patient_id=pid,
                    file_name=csv_path.name,
                    timestamp_col=ts_col,
                    cgm_value_col=dev["cgm_col"],
                    participant_id_col=args.participant_id_column or "filename",
                    study_id=args.study_id,
                    data_start=start,
                    data_end=end,
                )
            )

    process_participants(participants, args.study_id, Path(args.input_folder), output_dir)
    generate_metadata(meta_records, output_dir)


# ===========================================================================
# 12.  Case Dispatcher
# ===========================================================================

_CASE_DISPATCH = {
    "all_participant_cgm_in_one_file":                           process_case_1,
    "participant_data_in_separate_cgm_files":                    process_case_2,
    "single_participant_in_multiple_files":                      process_case_3,
    "multiple_device_cgm_multiple_participants_single_file":     process_case_4,
    "multiple_device_cgm_multiple_participants_separate_files":  process_case_5,
}


# ===========================================================================
# 13.  Entry-point
# ===========================================================================

def main(argv: Optional[List[str]] = None) -> None:
    """
    Main entry point.

    Orchestrates:
        argument parsing → validation → study.csv →
        per-case participant.csv + cgm_file_metadata.csv
    """
    parser = build_parser()
    args = parser.parse_args(argv)

    # 1. Validate all arguments (exits on error)
    validate_distribution_args(args)

    # 2. Create output directory
    output_dir = Path(args.output_folder)
    output_dir.mkdir(parents=True, exist_ok=True)
    log.info("Output directory: %s", output_dir.resolve())

    # 3. Generate study.csv (always one row from CLI)
    generate_study_file(args, output_dir)

    # 4. Dispatch to the appropriate case handler
    handler = _CASE_DISPATCH[args.cgm_distribution]
    handler(args, output_dir)

    log.info("✅  All output files generated successfully in: %s", output_dir.resolve())


if __name__ == "__main__":
    main()
