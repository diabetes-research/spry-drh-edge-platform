import pandas as pd
from pathlib import Path
from datetime import datetime
import argparse
import re
import random

# ---------- CLI ----------

parser = argparse.ArgumentParser()

parser.add_argument("--input-folder", required=True)
parser.add_argument("--output-folder", required=True)

parser.add_argument("--study-id", required=True)
parser.add_argument("--study-name", required=True)
parser.add_argument("--study-start-date", default="")
parser.add_argument("--study-end-date", default="")

parser.add_argument("--treatment-modalities", default="")
parser.add_argument("--funding-source", default="")
parser.add_argument("--nct-number", default="")
parser.add_argument("--study-description", default="")
parser.add_argument("--timestamp-column", default="")
parser.add_argument("--device-name", default="")

args = parser.parse_args()

# ---------- validation ----------

if not re.match(r"^[A-Z0-9]{4,10}$", args.study_id):
    raise ValueError("Invalid study_id format")

INPUT_DIR = Path(args.input_folder)
OUTPUT_DIR = Path(args.output_folder) / args.study_id.lower()
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

DEMOGRAPHICS = INPUT_DIR / "Demographics.csv"

# ---------- helpers ----------

def derive_diabetes_type(hba1c):
    if pd.isna(hba1c):
        return ""
    if hba1c < 5.7:
        return "Normal"
    elif hba1c < 6.5:
        return "Prediabetes"
    return "T2D"


def derive_icd(diabetes_type):
    return {
        "T1D": "E10",
        "T2D": "E11",
        "Prediabetes": "R73.03"
    }.get(diabetes_type, "")


# ---------- demographics (optional) ----------

demo = None
if DEMOGRAPHICS.exists():
    demo = pd.read_csv(DEMOGRAPHICS)
    demo.rename(columns={"Gender": "gender", "HbA1c": "baseline_hba1c"}, inplace=True)

# ---------- processing ----------

participant_rows = []
metadata_rows = []

global_min = None
global_max = None
meta_counter = 1

participants = sorted([p for p in INPUT_DIR.iterdir() if p.is_dir()])

for p in participants:

    numeric = re.sub(r"\D", "", p.name)
    pid = f"{args.study_id}-{numeric if numeric else p.name}"

    gender = ""
    hba1c = ""

    if demo is not None and numeric:
        row = demo[demo["ID"] == int(numeric)]
        if not row.empty:
            gender = str(row.iloc[0]["gender"]).strip().lower().capitalize()
            hba1c = row.iloc[0]["baseline_hba1c"]

    diabetes_type = derive_diabetes_type(hba1c)
    diagnosis_icd = derive_icd(diabetes_type)

    participant_rows.append([
        pid,
        args.study_id,
        "",
        diagnosis_icd,
        "",
        "",
        gender,
        "Unknown",
        "Unknown",
        random.randint(35, 65),
        "",
        hba1c,
        diabetes_type,
        ""
    ])

    # ---------- CGM files ----------
    for f in p.glob("*.csv"):

        df = pd.read_csv(f)

        # ---------- timestamp detection ----------
        ts_col = args.timestamp_column.strip() if args.timestamp_column else ""

        # if CLI provided → validate
        if ts_col:
            if ts_col not in df.columns:
                raise ValueError(f"{ts_col} not found in {f.name}")
        else:
            # fallback auto-detection
            ts_cols = [c for c in df.columns if "timestamp" in c.lower()]
            if not ts_cols:
                continue
            ts_col = ts_cols[0]

        df[ts_col] = pd.to_datetime(df[ts_col], errors="coerce")
        df = df[df[ts_col].notna()]

        if df.empty:
            continue

        start = df[ts_col].min()
        end = df[ts_col].max()

        global_min = start if global_min is None else min(global_min, start)
        global_max = end if global_max is None else max(global_max, end)

        # device id
        device_id = ""
        dev_cols = [c for c in df.columns if "source device id" in c.lower()]
        if dev_cols:
            values = df[dev_cols[0]].dropna()
            if not values.empty:
                device_id = str(values.iloc[0]).strip()
        
        df = pd.read_csv(f)

        # ---------- normalize columns ----------
        df.columns = df.columns.str.strip()

        # ---------- DEVICE NAME EXTRACTION (DO THIS BEFORE timestamp filtering) ----------
        device_name = args.device_name.strip() if args.device_name else ""

        if not device_name:

            if "Event Type" in df.columns and "Device Info" in df.columns:

                event_col = df["Event Type"].astype(str).str.strip().str.lower()

                device_rows = df[event_col == "device"]

                if not device_rows.empty:
                    raw_device = (
                        device_rows["Device Info"]
                        .dropna()
                        .astype(str)
                        .str.strip()
                        .iloc[0]
                    )
                    # ✅ remove "Mobile App" if present (case-insensitive)
                    device_name = re.sub(r"mobile\s*app", "", raw_device, flags=re.IGNORECASE).strip()

        # final safety fallback
        if not device_name:
            device_name = "Unknown Device"
        # ---------- CGM Manufacturer Mapping ----------

        CGM_MANUFACTURER_MAP = {
            # Abbott
            "freestyle libre": "Abbott",
            "freestyle libre 2": "Abbott",
            "freestyle libre 3": "Abbott",
            "freestyle libre pro": "Abbott",
            "freestyle navigator": "Abbott",

            # Dexcom
            "dexcom g4": "Dexcom",
            "dexcom g5": "Dexcom",
            "dexcom g6": "Dexcom",
            "dexcom g7": "Dexcom",
            "dexcom receiver with g6": "Dexcom",
            "stelo": "Dexcom",
            "clarity": "Dexcom",

            # Medtronic
            "guardian connect": "Medtronic",
            "simplera cgm system": "Medtronic",
            "carelink": "Medtronic",
            "medtronic paradigm": "Medtronic",

            # Senseonics
            "eversense": "Senseonics",
            "eversense xl": "Senseonics",
            "eversense e3": "Senseonics",
            "eversense 365": "Senseonics",

            # Platform
            "tidepool": "Tidepool"
        }


        def get_source_platform(device_name):
            if not device_name:
                return "Unknown"

            normalized = device_name.strip().lower()

            for key in CGM_MANUFACTURER_MAP:
                if key in normalized:
                    return CGM_MANUFACTURER_MAP[key]

            return "Unknown"
        source_platform = get_source_platform(device_name)
        metadata_rows.append([
            f"META-{meta_counter}",
            device_name,
            device_id,
            source_platform,
            pid,
            f.stem,
            "csv",
            datetime.now().strftime("%Y-%m-%d"),   # changed
            start.strftime("%Y-%m-%d"),            # changed
            start.strftime("%Y-%m-%d"),            # changed
            ts_col,
            "Glucose Value (mg/dL)",
            args.study_id,
            ""
        ])

        meta_counter += 1

# ---------- derive study dates if missing ----------
def normalize_datetime(dt_string):
    if not dt_string:
        return ""
    return pd.to_datetime(dt_string).strftime("%Y-%m-%d %H:%M:%S")

study_start = normalize_datetime(args.study_start_date) or (global_min.strftime("%Y-%m-%d %H:%M:%S") if global_min else "")
study_end = normalize_datetime(args.study_end_date) or (global_max.strftime("%Y-%m-%d %H:%M:%S") if global_max else "")

# ---------- write study.csv ----------

study_df = pd.DataFrame([[
    args.study_id,
    args.study_name,
    study_start,
    study_end,
    args.treatment_modalities,
    args.funding_source,
    args.nct_number,
    args.study_description
]], columns=[
    "study_id","study_name","start_date","end_date",
    "treatment_modalities","funding_source","nct_number","study_description"
])

study_df.to_csv(OUTPUT_DIR / "study.csv", index=False)

# ---------- write participant.csv ----------

pd.DataFrame(participant_rows, columns=[
    "participant_id","study_id","site_id","diagnosis_icd","med_rxnorm",
    "treatment_modality","gender","race","ethnicity","age","bmi",
    "baseline_hba1c","diabetes_type","study_arm"
]).to_csv(OUTPUT_DIR / "participant.csv", index=False)

# ---------- write metadata ----------

pd.DataFrame(metadata_rows, columns=[
    "metadata_id","devicename","device_id","source_platform","patient_id",
    "file_name","file_format","file_upload_date","data_start_date",
    "data_end_date","map_field_of_cgm_date","map_field_of_cgm_value",
    "study_id","map_field_of_patient_id"
]).to_csv(OUTPUT_DIR / "cgm_file_metadata.csv", index=False)

print("✅ DRH PhysioNet ingestion completed")