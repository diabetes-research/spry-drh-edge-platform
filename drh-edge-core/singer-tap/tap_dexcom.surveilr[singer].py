#!/usr/bin/env python3
"""
Dexcom Singer Tap (Supporting Clarity, API, Participant, Study, Author, Meal, Fitness)

- Scans a directory for CSV files.
- Identifies file content type based on filename patterns or headers.
- Emits standard DRH Singer messages.
"""

import sys
import os
import csv
import glob
from datetime import datetime, timezone
import logging
import json
import argparse
import subprocess
import venv
import uuid

# Bootstrap Logic to auto-install venv and dependencies
def bootstrap_venv():
    # If we are already in a venv, do nothing
    if sys.prefix != sys.base_prefix:
        return

    # Determine paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
    venv_dir = os.path.join(project_root, ".venv")
    requirements_file = os.path.join(project_root, "requirements.txt")
    
    # Determine python executable in venv
    if sys.platform == "win32":
        venv_python = os.path.join(venv_dir, "Scripts", "python.exe")
    else:
        venv_python = os.path.join(venv_dir, "bin", "python")

    # Create venv if python executable doesn't exist
    if not os.path.exists(venv_python):
        print(f"Bootstrapping: Creating virtual environment at {venv_dir}...", file=sys.stderr)
        # prompt=None, with_pip=True
        builder = venv.EnvBuilder(with_pip=True)
        builder.create(venv_dir)

    # Install dependencies
    if os.path.exists(requirements_file):
        # Always try to install/upgrade dependencies to ensure state is correct
        # print("Bootstrapping: Checking/Installing dependencies...", file=sys.stderr)
        try:
            subprocess.check_call(
                [venv_python, "-m", "pip", "install", "-r", requirements_file],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
        except subprocess.CalledProcessError:
             print("Bootstrapping: Failed to install dependencies.", file=sys.stderr)
             sys.exit(1)
    
    # Re-execute script
    # print("Bootstrapping: Re-executing script within virtual environment...", file=sys.stderr)
    try:
        os.execv(venv_python, [venv_python] + sys.argv)
    except OSError as e:
        print(f"Bootstrapping: Failed to re-execute script: {e}", file=sys.stderr)
        sys.exit(1)

# Run bootstrap before anything else
bootstrap_venv()

# Ensure we can import the SDK
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
# from drh_sdk import DRHSingerEmitter # Removed
import importlib.resources
from drh_target.loader import DRHLoader

def load_schema(stream_name):
    try:
        fname = f"{stream_name}.json"
        with importlib.resources.open_text("drh_target.schemas", fname) as f:
            return json.load(f)
    except Exception as e:
        LOGGER.error(f"Failed to load schema for {stream_name}: {e}")
        return {}

STREAM_KEYS = {
    "cgm_tracing": ["participant_id", "timestamp"],
    "combined_cgm_tracing": ["participant_id", "Date_Time"],
    "cgm_file_metadata": ["file_name"],
    "participant": ["participant_id"],
    "site": ["site_id"],
    "study": ["study_id"],
    "investigator": ["investigator_id"],
    "institution": ["institution_id"],
    "lab": ["lab_id"],
    "author": ["author_id"],
    "publication": ["publication_id"],
    "fitness_data": ["participant_id", "timestamp"],
    "fitness_file_metadata": ["file_name"],
    "meal_data": ["participant_id", "timestamp"],
    "meal_file_metadata": ["file_name"],
    "drh_validation_reports": ["timestamp"],
    "drh_diagnostics": ["record_id"],
    "raw_cgm_tracing": ["raw_id"],
    "raw_meal_data": ["raw_id"],
    "raw_fitness_data": ["raw_id"]
}

logging.basicConfig(stream=sys.stderr, level=logging.INFO)
LOGGER = logging.getLogger(__name__)

# File Configuration from Environment
FILES = {
    "cgm_file_metadata": os.path.basename(os.environ.get("CGM_FILE_METADATA_FILE", "cgm_file_metadata.csv")),
    "participant": os.path.basename(os.environ.get("PARTICIPANT_FILE", "participant.csv")),
    "institution": os.path.basename(os.environ.get("INSTITUTION_FILE", "institution.csv")),
    "lab": os.path.basename(os.environ.get("LAB_FILE", "lab.csv")),
    "study": os.path.basename(os.environ.get("STUDY_FILE", "study.csv")),
    "site": os.path.basename(os.environ.get("SITE_FILE", "site.csv")),
    "investigator": os.path.basename(os.environ.get("INVESTIGATOR_FILE", "investigator.csv")),
    "publication": os.path.basename(os.environ.get("PUBLICATION_FILE", "publication.csv")),
    "author": os.path.basename(os.environ.get("AUTHOR_FILE", "author.csv")),
    "meal_file_metadata": os.path.basename(os.environ.get("MEAL_FILE_METADATA_FILE", "meal_file_metadata.csv")),
    "fitness_file_metadata": os.path.basename(os.environ.get("FITNESS_FILE_METADATA_FILE", "fitness_file_metadata.csv")),
    "meal_data": os.path.basename(os.environ.get("MEAL_DATA_FILE", "meal_data.csv")),
    "fitness_data": os.path.basename(os.environ.get("FITNESS_DATA_FILE", "fitness_data.csv"))
}

MANDATORY_CSVS = [
    FILES["participant"], FILES["institution"], FILES["lab"], FILES["study"], FILES["site"],
    FILES["investigator"], FILES["publication"], FILES["author"], FILES["cgm_file_metadata"]
]

EXPECTED_HEADERS = {
    "institution": ["institution_id", "institution_name", "city", "state", "country"],
    "lab": ["lab_id", "lab_name", "lab_pi", "institution_id", "study_id"],
    "study": ["study_id", "study_name", "start_date", "end_date", "treatment_modalities", "funding_source", "nct_number", "study_description"],
    "participant": ["participant_id", "study_id", "site_id", "diagnosis_icd", "med_rxnorm", "treatment_modality", "gender", "race_ethnicity", "age", "bmi", "baseline_hba1c", "diabetes_type", "study_arm"],
    "site": ["site_id", "study_id", "site_name", "site_type"],
    "investigator": ["investigator_id", "investigator_name", "email", "institution_id", "study_id"],
    "publication": ["publication_id", "publication_title", "digital_object_identifier", "publication_site", "study_id"],
    "author": ["author_id", "name", "email", "investigator_id", "study_id"],
    "cgm_file_metadata": ["metadata_id", "devicename", "device_id", "source_platform", "patient_id", "file_name", "file_format", "file_upload_date", "data_start_date", "data_end_date", "map_field_of_cgm_date", "map_field_of_cgm_value", "study_id"],
    "meal_file_metadata": ["meal_meta_id", "participant_id", "file_name"],
    "fitness_file_metadata": ["fitness_meta_id", "participant_id", "file_name"]
}


def check_file_headers(data_dir):
    """
    Check if existing files have required headers.
    Returns a list of result dicts: {"name": str, "status": str, "details": str}
    """
    results = []
    
    for key, expected_cols in EXPECTED_HEADERS.items():
        fname = FILES.get(key)
        if not fname: 
            continue
        
        fpath = os.path.join(data_dir, fname)
        if os.path.exists(fpath):
            try:
                with open(fpath, 'r', encoding='utf-8-sig') as f:
                    reader = csv.reader(f)
                    try:
                        header = next(reader)
                        # Build column-level status
                        col_status = []
                        missing_cols = []
                        
                        for col in expected_cols:
                            if col in header:
                                col_status.append(f"{col}: OK")
                            else:
                                col_status.append(f"{col}: MISSING")
                                missing_cols.append(col)
                        
                        check_name = f"File Schema Check: {fname}"
                        details = " | ".join(col_status)
                        
                        if missing_cols:
                            results.append({
                                "name": check_name,
                                "status": "FAILED",
                                "details": details
                            })
                        else:
                            results.append({
                                "name": check_name,
                                "status": "PASSED",
                                "details": details
                            })
                    except StopIteration:
                        results.append({
                            "name": f"File Schema Check: {fname}",
                            "status": "FAILED",
                            "details": "Empty file - no headers found"
                        })
            except Exception as e:
                results.append({
                    "name": f"File Schema Check: {fname}",
                    "status": "FAILED",
                    "details": f"Error reading file: {e}"
                })
    
    return results


def check_file_extensions(data_dir):
    """Check if configured files have .csv extension."""
    extension_errors = []
    
    # Only check files defined in the FILES dictionary
    for key, filename in FILES.items():
        # Check extensions only for files that actually exist
        # If a file is missing, check_required_files will handle it (if mandatory)
        if os.path.exists(os.path.join(data_dir, filename)):
            if not filename.lower().endswith('.csv'):
                extension_errors.append(f"{filename}: Invalid extension (Expected .csv)")
                
    return extension_errors

    return extension_errors

def check_cgm_metadata_consistency(data_dir):
    """
    Check if files listed in cgm_file_metadata exists in the folder.
    Returns a list of result dicts: {"name": str, "status": str, "details": str}
    """
    results = []
    
    # Locate cgm_file_metadata
    cgm_meta_filename = FILES.get("cgm_file_metadata")
    if not cgm_meta_filename:
        return []
        
    cgm_meta_path = os.path.join(data_dir, cgm_meta_filename)
    
    if os.path.exists(cgm_meta_path):
        try:
             with open(cgm_meta_path, 'r', encoding='utf-8-sig') as f:
                reader = csv.DictReader(f)
                if "file_name" not in reader.fieldnames:
                     return [{"name": "CGM Metadata Schema Check", "status": "SKIPPED", "details": "file_name column missing in metadata"}]
                
                for row in reader:
                    expected_file = row.get("file_name")
                    if expected_file:
                        expected_file = expected_file.strip()
                        
                        # Normalize filename: add .csv extension if missing
                        if not expected_file.lower().endswith('.csv'):
                            expected_file_with_ext = expected_file + '.csv'
                        else:
                            expected_file_with_ext = expected_file
                        
                        target_path = os.path.join(data_dir, expected_file_with_ext)
                        
                        check_name = f"CGM File Presence: {expected_file}"
                        if os.path.exists(target_path):
                             results.append({
                                 "name": check_name,
                                 "status": "PASSED",
                                 "details": f"File found in {data_dir}"
                             })
                        else:
                             results.append({
                                 "name": check_name,
                                 "status": "FAILED",
                                 "details": f"File listed in {cgm_meta_filename} is missing from disk"
                             })
        except Exception as e:
            results.append({
                "name": "CGM Metadata Read",
                "status": "FAILED",
                "details": f"Error reading {cgm_meta_filename}: {e}"
            })
            
    return results

def check_cgm_data_integrity(data_dir):
    """
    Validate that CGM data files referenced in cgm_file_metadata.csv contain data rows beyond headers.
    Returns a list of result dicts: {"name": str, "status": str, "details": str}
    """
    results = []
    
    # Locate cgm_file_metadata
    cgm_meta_filename = FILES.get("cgm_file_metadata")
    if not cgm_meta_filename:
        return []
        
    cgm_meta_path = os.path.join(data_dir, cgm_meta_filename)
    
    if not os.path.exists(cgm_meta_path):
        return []
    
    try:
        with open(cgm_meta_path, 'r', encoding='utf-8-sig') as f:
            reader = csv.DictReader(f)
            
            # Dynamically locate file_name column
            if "file_name" not in reader.fieldnames:
                return [{
                    "name": "CGM Data Integrity Check",
                    "status": "SKIPPED",
                    "details": "file_name column not found in cgm_file_metadata.csv"
                }]
            
            # Check if metadata file itself has data rows
            rows = list(reader)
            if not rows:
                return [{
                    "name": "CGM Data Integrity Check",
                    "status": "FAILED",
                    "details": "cgm_file_metadata.csv has no data rows beyond header"
                }]
            
            # Process each referenced file
            for row in rows:
                expected_file = row.get("file_name")
                if expected_file:
                    expected_file = expected_file.strip()
                    
                    # Normalize filename: add .csv extension if missing
                    if not expected_file.lower().endswith('.csv'):
                        expected_file_with_ext = expected_file + '.csv'
                    else:
                        expected_file_with_ext = expected_file
                    
                    target_path = os.path.join(data_dir, expected_file_with_ext)
                    
                    # Extract base filename for check name
                    base_name = os.path.splitext(expected_file)[0]
                    check_name = f"CGM Data Integrity: {base_name}"
                    
                    if os.path.exists(target_path):
                        # Check if file has data rows beyond header
                        try:
                            with open(target_path, 'r', encoding='utf-8-sig') as data_file:
                                data_reader = csv.reader(data_file)
                                # Skip header
                                try:
                                    next(data_reader)
                                except StopIteration:
                                    results.append({
                                        "name": check_name,
                                        "status": "FAILED",
                                        "details": f"File {expected_file_with_ext} is empty (no header)"
                                    })
                                    continue
                                
                                # Try to read first data row
                                try:
                                    next(data_reader)
                                    results.append({
                                        "name": check_name,
                                        "status": "PASSED",
                                        "details": f"Data rows detected for {base_name}"
                                    })
                                except StopIteration:
                                    results.append({
                                        "name": check_name,
                                        "status": "FAILED",
                                        "details": f"File {expected_file_with_ext} has no data rows (header only)"
                                    })
                        except Exception as e:
                            results.append({
                                "name": check_name,
                                "status": "FAILED",
                                "details": f"Error reading {expected_file_with_ext}: {e}"
                            })
                    else:
                        # File doesn't exist - this should be caught by check 5, but report anyway
                        results.append({
                            "name": check_name,
                            "status": "FAILED",
                            "details": f"File {expected_file_with_ext} not found"
                        })
    except Exception as e:
        results.append({
            "name": "CGM Data Integrity Check",
            "status": "FAILED",
            "details": f"Error reading cgm_file_metadata.csv: {e}"
        })
    
    return results

def check_meal_data_consistency(data_dir):
    """
    Check if files listed in meal_file_metadata exists in the folder.
    Returns a list of result dicts: {"name": str, "status": str, "details": str}
    """
    results = []
    
    # Locate meal_file_metadata
    meal_meta_filename = FILES.get("meal_file_metadata")
    if not meal_meta_filename:
        return []
        
    meal_meta_path = os.path.join(data_dir, meal_meta_filename)
    
    if os.path.exists(meal_meta_path):
        try:
             with open(meal_meta_path, 'r', encoding='utf-8-sig') as f:
                reader = csv.DictReader(f)
                if "file_name" not in reader.fieldnames:
                     return [{"name": "Meal Metadata Schema Check", "status": "SKIPPED", "details": "file_name column missing in metadata"}]
                
                # Track checked files to avoid duplicates
                checked_files = set()

                for row in reader:
                    expected_file = row.get("file_name")
                    if expected_file:
                        expected_file = expected_file.strip()
                        
                        # Normalize filename: add .csv extension if missing
                        if not expected_file.lower().endswith('.csv'):
                            expected_file_with_ext = expected_file + '.csv'
                        else:
                            expected_file_with_ext = expected_file
                        
                        # Skip if already checked
                        if expected_file_with_ext in checked_files:
                            continue
                        checked_files.add(expected_file_with_ext)
                        

                        target_path = os.path.join(data_dir, expected_file_with_ext)
                        
                        check_name = f"Meal File Presence: {expected_file}"
                        if os.path.exists(target_path):
                             results.append({
                                 "name": check_name,
                                 "status": "PASSED",
                                 "details": f"File found in {data_dir}"
                             })
                        else:
                             results.append({
                                 "name": check_name,
                                 "status": "FAILED",
                                 "details": f"File listed in {meal_meta_filename} is missing from disk"
                             })
        except Exception as e:
            results.append({
                "name": "Meal Metadata Read",
                "status": "FAILED",
                "details": f"Error reading {meal_meta_filename}: {e}"
            })
            
    return results

def check_fitness_data_consistency(data_dir):
    """
    Check if files listed in fitness_file_metadata exists in the folder.
    Returns a list of result dicts: {"name": str, "status": str, "details": str}
    """
    results = []
    
    # Locate fitness_file_metadata
    fitness_meta_filename = FILES.get("fitness_file_metadata")
    if not fitness_meta_filename:
        return []
        
    fitness_meta_path = os.path.join(data_dir, fitness_meta_filename)
    
    if os.path.exists(fitness_meta_path):
        try:
             with open(fitness_meta_path, 'r', encoding='utf-8-sig') as f:
                reader = csv.DictReader(f)
                if "file_name" not in reader.fieldnames:
                     return [{"name": "Fitness Metadata Schema Check", "status": "SKIPPED", "details": "file_name column missing in metadata"}]
                
                # Track checked files to avoid duplicates
                checked_files = set()

                for row in reader:
                    expected_file = row.get("file_name")
                    if expected_file:
                        expected_file = expected_file.strip()
                        
                        # Normalize filename: add .csv extension if missing
                        if not expected_file.lower().endswith('.csv'):
                            expected_file_with_ext = expected_file + '.csv'
                        else:
                            expected_file_with_ext = expected_file
                        
                        # Skip if already checked
                        if expected_file_with_ext in checked_files:
                            continue
                        checked_files.add(expected_file_with_ext)
                        
                        target_path = os.path.join(data_dir, expected_file_with_ext)
                        
                        check_name = f"Fitness File Presence: {expected_file}"
                        if os.path.exists(target_path):
                             results.append({
                                 "name": check_name,
                                 "status": "PASSED",
                                 "details": f"File found in {data_dir}"
                             })
                        else:
                             results.append({
                                 "name": check_name,
                                 "status": "FAILED",
                                 "details": f"File listed in {fitness_meta_filename} is missing from disk"
                             })
        except Exception as e:
            results.append({
                "name": "Fitness Metadata Read",
                "status": "FAILED",
                "details": f"Error reading {fitness_meta_filename}: {e}"
            })
            
    return results

def check_meal_data_integrity(data_dir):
    """
    Validate that Meal data files referenced in meal_file_metadata.csv contain data rows beyond headers.
    Returns a list of result dicts: {"name": str, "status": str, "details": str}
    """
    results = []
    
    # Locate meal_file_metadata
    meal_meta_filename = FILES.get("meal_file_metadata")
    if not meal_meta_filename:
        return []
        
    meal_meta_path = os.path.join(data_dir, meal_meta_filename)
    
    if os.path.exists(meal_meta_path):
        try:
             with open(meal_meta_path, 'r', encoding='utf-8-sig') as f:
                reader = csv.DictReader(f)
                if "file_name" not in reader.fieldnames:
                     return [{"name": "Meal Data Integrity Check", "status": "SKIPPED", "details": "file_name column missing in metadata"}]
                
                # Check if metadata file itself has data rows
                rows = list(reader)
                if not rows:
                    return [{
                        "name": "Meal Data Integrity Check",
                        "status": "FAILED",
                        "details": "meal_file_metadata.csv has no data rows beyond header"
                    }]

                # Track checked files to avoid duplicates
                checked_files = set()

                for row in rows:
                    expected_file = row.get("file_name")
                    if expected_file:
                        expected_file = expected_file.strip()
                        
                        # Normalize filename: add .csv extension if missing
                        if not expected_file.lower().endswith('.csv'):
                             expected_file_with_ext = expected_file + '.csv'
                        else:
                             expected_file_with_ext = expected_file
                        
                        # Skip if already checked
                        if expected_file_with_ext in checked_files:
                            continue
                        checked_files.add(expected_file_with_ext)

                        target_path = os.path.join(data_dir, expected_file_with_ext)
                        
                        # Extract base filename for check name
                        base_name = os.path.splitext(expected_file)[0]
                        check_name = f"Meal Data Integrity: {base_name}"
                        
                        if os.path.exists(target_path):
                             # Check if file has data rows beyond header
                            try:
                                with open(target_path, 'r', encoding='utf-8-sig') as data_file:
                                    data_reader = csv.reader(data_file)
                                    # Skip header
                                    try:
                                        next(data_reader)
                                    except StopIteration:
                                        results.append({
                                            "name": check_name,
                                            "status": "FAILED",
                                            "details": f"File {expected_file_with_ext} is empty (no header)"
                                        })
                                        continue
                                    
                                    # Try to read first data row
                                    try:
                                        next(data_reader)
                                        results.append({
                                            "name": check_name,
                                            "status": "PASSED",
                                            "details": f"Data rows detected for {base_name}"
                                        })
                                    except StopIteration:
                                        results.append({
                                            "name": check_name,
                                            "status": "FAILED",
                                            "details": f"File {expected_file_with_ext} has no data rows (header only)"
                                        })
                            except Exception as e:
                                results.append({
                                    "name": check_name,
                                    "status": "FAILED",
                                    "details": f"Error reading {expected_file_with_ext}: {e}"
                                })
                        else:
                             # File missing handled by previous check, but good to report here too or skip
                             results.append({
                                 "name": check_name,
                                 "status": "FAILED",
                                 "details": f"File {expected_file_with_ext} not found"
                             })
        except Exception as e:
            results.append({
                "name": "Meal Metadata Read",
                "status": "FAILED",
                "details": f"Error reading {meal_meta_filename}: {e}"
            })
            
    return results

def check_fitness_data_integrity(data_dir):
    """
    Validate that Fitness data files referenced in fitness_file_metadata.csv contain data rows beyond headers.
    Returns a list of result dicts: {"name": str, "status": str, "details": str}
    """
    results = []
    
    # Locate fitness_file_metadata
    fitness_meta_filename = FILES.get("fitness_file_metadata")
    if not fitness_meta_filename:
        return []
        
    fitness_meta_path = os.path.join(data_dir, fitness_meta_filename)
    
    if os.path.exists(fitness_meta_path):
        try:
             with open(fitness_meta_path, 'r', encoding='utf-8-sig') as f:
                reader = csv.DictReader(f)
                if "file_name" not in reader.fieldnames:
                     return [{"name": "Fitness Data Integrity Check", "status": "SKIPPED", "details": "file_name column missing in metadata"}]
                
                # Check if metadata file itself has data rows
                rows = list(reader)
                if not rows:
                    return [{
                        "name": "Fitness Data Integrity Check",
                        "status": "FAILED",
                        "details": "fitness_file_metadata.csv has no data rows beyond header"
                    }]

                # Track checked files to avoid duplicates
                checked_files = set()

                for row in rows:
                    expected_file = row.get("file_name")
                    if expected_file:
                        expected_file = expected_file.strip()
                        
                        # Normalize filename: add .csv extension if missing
                        if not expected_file.lower().endswith('.csv'):
                             expected_file_with_ext = expected_file + '.csv'
                        else:
                             expected_file_with_ext = expected_file
                        
                        # Skip if already checked
                        if expected_file_with_ext in checked_files:
                            continue
                        checked_files.add(expected_file_with_ext)

                        target_path = os.path.join(data_dir, expected_file_with_ext)
                        
                        # Extract base filename for check name
                        base_name = os.path.splitext(expected_file)[0]
                        check_name = f"Fitness Data Integrity: {base_name}"
                        
                        if os.path.exists(target_path):
                             # Check if file has data rows beyond header
                            try:
                                with open(target_path, 'r', encoding='utf-8-sig') as data_file:
                                    data_reader = csv.reader(data_file)
                                    # Skip header
                                    try:
                                        next(data_reader)
                                    except StopIteration:
                                        results.append({
                                            "name": check_name,
                                            "status": "FAILED",
                                            "details": f"File {expected_file_with_ext} is empty (no header)"
                                        })
                                        continue
                                    
                                    # Try to read first data row
                                    try:
                                        next(data_reader)
                                        results.append({
                                            "name": check_name,
                                            "status": "PASSED",
                                            "details": f"Data rows detected for {base_name}"
                                        })
                                    except StopIteration:
                                        results.append({
                                            "name": check_name,
                                            "status": "FAILED",
                                            "details": f"File {expected_file_with_ext} has no data rows (header only)"
                                        })
                            except Exception as e:
                                results.append({
                                    "name": check_name,
                                    "status": "FAILED",
                                    "details": f"Error reading {expected_file_with_ext}: {e}"
                                })
                        else:
                             # File missing handled by previous check, but good to report here too or skip
                             results.append({
                                 "name": check_name,
                                 "status": "FAILED",
                                 "details": f"File {expected_file_with_ext} not found"
                             })
        except Exception as e:
            results.append({
                "name": "Fitness Metadata Read",
                "status": "FAILED",
                "details": f"Error reading {fitness_meta_filename}: {e}"
            })
            
    return results



def check_required_files(data_dir):
    """Check if all mandatory files exist."""
    missing_files = []
    
    # Check strict mandatory files
    for fname in MANDATORY_CSVS:
        if not os.path.exists(os.path.join(data_dir, fname)):
            missing_files.append(fname)
    
    # Check conditional mandatory files
    # If meal_data exists, meal_file_metadata is required
    if os.path.exists(os.path.join(data_dir, FILES["meal_data"])):
        if not os.path.exists(os.path.join(data_dir, FILES["meal_file_metadata"])):
            missing_files.append(FILES["meal_file_metadata"])

    # If fitness_data exists, fitness_file_metadata is required
    if os.path.exists(os.path.join(data_dir, FILES["fitness_data"])):
        if not os.path.exists(os.path.join(data_dir, FILES["fitness_file_metadata"])):
            missing_files.append(FILES["fitness_file_metadata"])
    
    return missing_files

def process_cgm_file_metadata(emitter, filepath):
    """Process CGM File Metadata."""
    stream_name = "cgm_file_metadata"
    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                record = {
                    "metadata_id": row.get("metadata_id"),
                    "devicename": row.get("devicename"),
                    "device_id": row.get("device_id"),
                    "source_platform": row.get("source_platform"),
                    "patient_id": row.get("patient_id"),
                    "file_name": row.get("file_name"),
                    "file_format": row.get("file_format"),
                    "file_upload_date": row.get("file_upload_date"),
                    "data_start_date": row.get("data_start_date"),
                    "data_end_date": row.get("data_end_date"),
                    "map_field_of_cgm_date": row.get("map_field_of_cgm_date"),
                    "map_field_of_cgm_value": row.get("map_field_of_cgm_value"),
                    "study_id": row.get("study_id"),
                    "map_field_of_patient_id": row.get("map_field_of_patient_id"),
                    "tenant_id": row.get("tenant_id"),
                    "tenant_name": row.get("tenant_name")
                }

                # Normalize dates if present and likely just Date strings (YYYY-MM-DD)
                for date_field in ["file_upload_date", "data_start_date", "data_end_date"]:
                    val = record.get(date_field)
                    if val and "T" not in val:
                        record[date_field] = val + "T00:00:00Z"
                
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in cgm_file_metadata file {filepath}: {e}")

def process_publication(emitter, filepath):
    """Process Publication Metadata."""
    stream_name = "publication"
    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                record = {
                     "publication_id": row.get("publication_id"),
                     "publication_title": row.get("publication_title"),
                     "digital_object_identifier": row.get("digital_object_identifier"),
                     "publication_site": row.get("publication_site"),
                     "study_id": row.get("study_id"),
                     "tenant_id": row.get("tenant_id"),
                     "tenant_name": row.get("tenant_name")
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in publication file {filepath}: {e}")

def normalize_timestamp(ts_str):
    """Normalize timestamp to ISO 8601."""
    if not ts_str: return None
    try:
        # Check if already close to ISO format (e.g. 2024-07-29T07:00:00Z)
        if 'T' in ts_str:
            return ts_str
        # Try space separated "2025-05-04 00:00:00"
        dt = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S")
        return dt.isoformat() + "Z"
    except ValueError:
        return ts_str # Return as is if parsing fails, let schema validation catch it

def process_raw_cgm_tracing(emitter, filepath):
    """
    Emit a RAW_CGM_TRACING record.
    Reads the full file content as JSON payload.
    """
    try:
        # Read all rows into a list of dictionaries
        with open(filepath, newline='', encoding='utf-8-sig') as f:
            reader = csv.DictReader(f)
            data_rows = list(reader)
            
        record = {
            "raw_id": str(uuid.uuid4()),
            "raw_file_name": os.path.basename(filepath),
            "raw_data_payload": data_rows
        }
        emitter.emit_record("raw_cgm_tracing", record)
        
    except Exception as e:
        LOGGER.error(f"Error processing raw CGM tracing {filepath}: {e}")

def process_cgm_clarity(emitter, filepath):

    """Process Clarity Export Format."""
    stream_name = "cgm_tracing"
    participant_id = os.path.basename(filepath).split('_')[2] # cgm_tracing_P-001_...
    
    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                ts = normalize_timestamp(row.get("Display Time"))
                val = row.get("Sensor Glucose (mg/dL)") or row.get("EGV (mg/dL)")
                if not val or not ts:
                    continue
                
                record = {
                    "participant_id": participant_id,
                    "timestamp": ts,
                    "glucose_value": float(val),
                    "units": "mg/dL",
                    "device_id": "Dexcom_Clarity",
                    "record_type": "CGM"
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in file {filepath}: {e}")

def process_cgm_api(emitter, filepath):
    """Process API Export Format."""
    stream_name = "cgm_tracing"
    participant_id = os.path.basename(filepath).split('_')[2]
    
    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                record = {
                    "participant_id": participant_id,
                    "timestamp": row.get("cgm_datetime_utc"),
                    "glucose_value": float(row.get("cgm_value_mgdl")),
                    "units": "mg/dL",
                    "device_id": row.get("device_model"),
                    "record_type": "CGM"
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in file {filepath}: {e}")

def process_participant(emitter, filepath):
    """Process Participant Metadata."""
    stream_name = "participant"
    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                # Schema expects STRING for age, bmi, hba1c as per user request
                # We also add the new tenant fields which are likely missing from CSV
                record = {
                    "participant_id": row.get("participant_id"),
                    "study_id": row.get("study_id"),
                    "site_id": row.get("site_id"),
                    "diagnosis_icd": row.get("diagnosis_icd"),
                    "med_rxnorm": row.get("med_rxnorm"),
                    "treatment_modality": row.get("treatment_modality"),
                    "gender": row.get("gender"),
                    "race_ethnicity": row.get("race_ethnicity"),
                    "age": row.get("age"), # No int() cast, schema is STRING
                    "bmi": row.get("bmi"), # No float() cast, schema is STRING
                    "baseline_hba1c": row.get("baseline_hba1c"), # No float() cast
                    "diabetes_type": row.get("diabetes_type"),
                    "study_arm": row.get("study_arm"),
                    # New fields requested by user, likely not in this source file
                    "tenant_id": row.get("tenant_id"), 
                    "tenant_name": row.get("tenant_name")
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                 LOGGER.warning(f"Error in participant file {filepath}: {e}")

def process_study(emitter, filepath):
    """Process Study Metadata."""
    stream_name = "study"
    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                record = {
                    "study_id": row.get("study_id"),
                    "study_name": row.get("study_name"),
                    "start_date": row.get("start_date") + "T00:00:00Z" if row.get("start_date") else None,
                    "end_date": row.get("end_date") + "T00:00:00Z" if row.get("end_date") else None,
                    "treatment_modalities": row.get("treatment_modalities"),
                    "funding_source": row.get("funding_source"),
                    "nct_number": row.get("nct_number"),
                    "study_description": row.get("study_description"),
                    # New fields requested by user
                    "tenant_id": row.get("tenant_id"),
                    "tenant_name": row.get("tenant_name")
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in study file {filepath}: {e}")

def process_investigator(emitter, filepath):
    """Process Investigator Metadata."""
    stream_name = "investigator"
    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                record = {
                    "investigator_id": row.get("investigator_id"),
                    "investigator_name": row.get("investigator_name"),
                    "email": row.get("email"),
                    "institution_id": row.get("institution_id"),
                    "study_id": row.get("study_id"),
                    # New fields requested by user
                    "tenant_id": row.get("tenant_id"),
                    "tenant_name": row.get("tenant_name")
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in investigator file {filepath}: {e}")

def process_institution(emitter, filepath):
    """Process Institution Metadata."""
    stream_name = "institution"
    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                record = {
                    "institution_id": row.get("institution_id"),
                    "institution_name": row.get("institution_name"),
                    "city": row.get("city"),
                    "state": row.get("state"),
                    "country": row.get("country"),
                    # New fields requested by user
                    "tenant_id": row.get("tenant_id"),
                    "tenant_name": row.get("tenant_name")
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in institution file {filepath}: {e}")

def process_lab(emitter, filepath):
    """Process Lab Metadata."""
    stream_name = "lab"
    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                record = {
                    "lab_id": row.get("lab_id"),
                    "lab_name": row.get("lab_name"),
                    "lab_pi": row.get("lab_pi"),
                    "institution_id": row.get("institution_id"),
                    "study_id": row.get("study_id"),
                    # New fields requested by user
                    "tenant_id": row.get("tenant_id"),
                    "tenant_name": row.get("tenant_name")
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in lab file {filepath}: {e}")

def process_meal_file_metadata(emitter, filepath):
    """Process Meal File Metadata."""
    stream_name = "meal_file_metadata"
    with open(filepath, newline='', encoding='utf-8-sig') as f:
         reader = csv.DictReader(f)
         for row in reader:
             try:
                 record = {
                     "meal_meta_id": row.get("meal_meta_id"),
                     "participant_id": row.get("participant_id"),
                     "file_name": row.get("file_name"),
                     "source": row.get("source"),
                     "file_format": row.get("file_format")
                 }
                 emitter.emit_record(stream_name, record)
             except Exception as e:
                 LOGGER.warning(f"Error in meal_file_metadata file {filepath}: {e}")

def process_fitness_file_metadata(emitter, filepath):
    """Process Fitness File Metadata."""
    stream_name = "fitness_file_metadata"
    with open(filepath, newline='', encoding='utf-8-sig') as f:
         reader = csv.DictReader(f)
         for row in reader:
             try:
                 record = {
                     "fitness_meta_id": row.get("fitness_meta_id"),
                     "participant_id": row.get("participant_id"),
                     "file_name": row.get("file_name"),
                     "source": row.get("source"),
                     "file_format": row.get("file_format")
                 }
                 emitter.emit_record(stream_name, record)
             except Exception as e:
                 LOGGER.warning(f"Error in fitness_file_metadata file {filepath}: {e}")

def process_author(emitter, filepath):
    """Process Author Metadata."""
    stream_name = "author"
    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                record = {
                    "author_id": row.get("author_id"),
                    "name": row.get("name"),
                    "email": row.get("email"),
                    "investigator_id": row.get("investigator_id"),
                    "study_id": row.get("study_id"),
                    # New fields requested by user
                    "tenant_id": row.get("tenant_id"),
                    "tenant_name": row.get("tenant_name")
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in author file {filepath}: {e}")

def process_meal(emitter, filepath):
    """Process Meal Data."""
    stream_name = "meal_data"
    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                record = {
                    "meal_id": row.get("meal_id"),
                    "participant_id": row.get("participant_id"),
                    "meal_time": row.get("meal_time"),
                    "calories": int(row.get("calories") or 0),
                    "meal_type": row.get("meal_type"),
                    "timestamp": row.get("meal_time"),
                    "description": f"Calories: {row.get('calories')}",
                    "carbohydrates_grams": 0,
                    "proteins_grams": 0,
                    "fats_grams": 0
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in meal file {filepath}: {e}")

def process_fitness(emitter, filepath):
    """Process Fitness Data."""
    stream_name = "fitness_data"
    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                date_str = row.get("date")
                ts = date_str + "T00:00:00Z" if date_str else None
                record = {
                    "fitness_id": row.get("fitness_id"),
                    "participant_id": row.get("participant_id"),
                    "date": date_str,
                    "steps": int(row.get("steps") or 0),
                    "exercise_minutes": float(row.get("exercise_minutes") or 0),
                    "calories_burned": float(row.get("calories_burned") or 0),
                    "distance": float(row.get("distance") or 0),
                    "heart_rate": float(row.get("heart_rate") or 0),
                    "timestamp": ts
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                 LOGGER.warning(f"Error in fitness file {filepath}: {e}")

def process_site(emitter, filepath):
    """Process Site Metadata."""
    stream_name = "site"
    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                record = {
                    "study_id": row.get("study_id"),
                    "site_id": row.get("site_id"),
                    "site_name": row.get("site_name"),
                    "site_type": row.get("site_type"),
                    # New fields requested by user
                    "tenant_id": row.get("tenant_id"), 
                    "tenant_name": row.get("tenant_name")
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                 LOGGER.warning(f"Error in site file {filepath}: {e}")

def process_combined_cgm_tracing(emitter, data_dir):
    """
    Process CGM data files driven by cgm_file_metadata.csv mapping.
    Iterates through each file listed in metadata, maps columns, and emits combined_cgm_tracing records.
    """
    meta_filename = FILES.get("cgm_file_metadata")
    if not meta_filename: return
    
    meta_path = os.path.join(data_dir, meta_filename)
    if not os.path.exists(meta_path): return
    
    try:
        with open(meta_path, 'r', encoding='utf-8-sig') as f:
            reader = csv.DictReader(f)
            for row in reader:
                file_name = row.get("file_name")
                if not file_name: continue
                
                # Normalize filename
                file_name = file_name.strip()
                if not file_name.lower().endswith(".csv"):
                    file_name += ".csv"
                
                # Dynamic mapping
                col_date = row.get("map_field_of_cgm_date")
                col_val = row.get("map_field_of_cgm_value")
                # User instruction: "metadata_id column change to patient_id"
                participant_id = row.get("patient_id") 
                tenant_id = row.get("tenant_id")
                study_id = row.get("study_id")
                
                data_path = os.path.join(data_dir, file_name)
                if not os.path.exists(data_path):
                    # Missing files are handled by validation checks (5 & 6)
                    continue
                    
                try:
                    with open(data_path, 'r', encoding='utf-8-sig') as df:
                        d_reader = csv.DictReader(df)
                        for d_row in d_reader:
                            # Extract using mapped column names
                            val_date = d_row.get(col_date) if col_date else None
                            val_cgm = d_row.get(col_val) if col_val else None
                            
                            if val_date and val_cgm:
                                try:
                                    # User schema:
                                    # tenant_id, study_id, participant_id, Date_Time, CGM_Value
                                    
                                    record = {
                                        "tenant_id": tenant_id,
                                        "study_id": study_id,
                                        "participant_id": participant_id,
                                        "Date_Time": normalize_timestamp(val_date), 
                                        "CGM_Value": float(val_cgm)
                                    }
                                    emitter.emit_record("combined_cgm_tracing", record)
                                except ValueError:
                                    pass # Skip invalid numbers
                except Exception as e:
                     LOGGER.warning(f"Error processing CGM data file {file_name}: {e}")

    except Exception as e:
        LOGGER.error(f"Error processing combined CGM tracing: {e}")

def process_raw_meal_data(emitter, data_dir):
    """
    Process raw Meal data files driven by meal_file_metadata.csv.
    Handles duplicate file references.
    """
    meta_filename = FILES.get("meal_file_metadata")
    if not meta_filename: return
    
    meta_path = os.path.join(data_dir, meta_filename)
    if not os.path.exists(meta_path): return
    
    processed_files = set()
    
    try:
        with open(meta_path, 'r', encoding='utf-8-sig') as f:
            reader = csv.DictReader(f)
            for row in reader:
                file_name = row.get("file_name")
                if not file_name: continue
                
                # Normalize filename
                file_name = file_name.strip()
                if not file_name.lower().endswith(".csv"):
                    file_name += ".csv"
                
                # Duplicate check
                if file_name in processed_files:
                    continue
                processed_files.add(file_name)
                
                data_path = os.path.join(data_dir, file_name)
                if not os.path.exists(data_path):
                     continue 
                
                try:
                    with open(data_path, newline='', encoding='utf-8-sig') as df:
                        d_reader = csv.DictReader(df)
                        data_rows = list(d_reader)
                        
                        record = {
                            "raw_id": str(uuid.uuid4()),
                            "raw_file_name": file_name,
                            "raw_data_payload": data_rows
                        }
                        emitter.emit_record("raw_meal_data", record)
                except Exception as e:
                     LOGGER.warning(f"Error processing raw meal file {file_name}: {e}")

    except Exception as e:
        LOGGER.error(f"Error processing raw meal metadata: {e}")

def process_raw_fitness_data(emitter, data_dir):
    """
    Process raw Fitness data files driven by fitness_file_metadata.csv.
    Handles duplicate file references.
    """
    meta_filename = FILES.get("fitness_file_metadata")
    if not meta_filename: return
    
    meta_path = os.path.join(data_dir, meta_filename)
    if not os.path.exists(meta_path): return
    
    processed_files = set()
    
    try:
        with open(meta_path, 'r', encoding='utf-8-sig') as f:
            reader = csv.DictReader(f)
            for row in reader:
                file_name = row.get("file_name")
                if not file_name: continue
                
                # Normalize filename
                file_name = file_name.strip()
                if not file_name.lower().endswith(".csv"):
                    file_name += ".csv"
                
                # Duplicate check
                if file_name in processed_files:
                    continue
                processed_files.add(file_name)
                
                data_path = os.path.join(data_dir, file_name)
                if not os.path.exists(data_path):
                     continue 
                
                try:
                    with open(data_path, newline='', encoding='utf-8-sig') as df:
                        d_reader = csv.DictReader(df)
                        data_rows = list(d_reader)
                        
                        record = {
                            "raw_id": str(uuid.uuid4()),
                            "raw_file_name": file_name,
                            "raw_data_payload": data_rows
                        }
                        emitter.emit_record("raw_fitness_data", record)
                except Exception as e:
                     LOGGER.warning(f"Error processing raw fitness file {file_name}: {e}")

    except Exception as e:
        LOGGER.error(f"Error processing raw fitness metadata: {e}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-c", "--config", help="Config file")
    parser.add_argument("-s", "--state", help="State file")
    parser.add_argument("--discover", action="store_true", help="Do discovery")
    args = parser.parse_args()

    emitter = DRHLoader()

    if args.discover:
        for s in STREAM_KEYS:
             # Load all schemas for discovery
             schema = load_schema(s)
             keys = STREAM_KEYS.get(s, [])
             emitter.emit_schema(s, schema, keys)
        return

    data_dir = os.environ.get("STUDY_DATA_PATH")
    if args.config:
        try:
             with open(args.config) as f:
                 conf = json.load(f)
                 if "study_data_path" in conf:
                      data_dir = conf["study_data_path"]
        except Exception as e:
             LOGGER.warning(f"Failed to load config file: {e}")

    if not data_dir:
        LOGGER.error("STUDY_DATA_PATH environment variable or config not set.")
        sys.exit(1)
    
    # Emit schemas for all supported streams
    streams = [
        # "combined_cgm_tracing", 
        "participant", "study", "author", "meal_data", "fitness_data", 
        "site", "investigator", "institution", "lab", "publication", 
        "cgm_file_metadata", "meal_file_metadata", "fitness_file_metadata",
        "drh_validation_reports", "drh_diagnostics", "raw_cgm_tracing",
        "raw_meal_data", "raw_fitness_data"
    ]
    for s in streams:
        schema = load_schema(s)
        keys = STREAM_KEYS.get(s, [])
        emitter.emit_schema(s, schema, keys)
    
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    overall_status = "SUCCESS"
    check_counter = 1 # Not used for ID anymore, strictly for internal counting if needed
    diagnostic_logs = []

    def emit_diagnostic(check_id_static, name, status, details):
        nonlocal check_counter
        record = {
            "record_id": str(uuid.uuid4()),
            "check_id": check_id_static,
            "check_name": name,
            "status": status,
            "details": details
        }
        emitter.emit_record("drh_diagnostics", record)
        diagnostic_logs.append({
            "check": name,
            "status": status,
            "details": details
        })
        check_counter += 1

    # 1. Folder & Resource Check (Static ID: 1)
    if not os.path.exists(data_dir):
        msg = f"Data directory does not exist: {data_dir}"
        emit_diagnostic(1, "Folder & Resource Check", "FAILED", msg)
        overall_status = "FAILED"
    elif not os.path.isdir(data_dir):
        msg = f"Path is not a directory: {data_dir}"
        emit_diagnostic(1, "Folder & Resource Check", "FAILED", msg)
        overall_status = "FAILED"
    elif not os.access(data_dir, os.R_OK):
        msg = f"Directory is not readable: {data_dir}"
        emit_diagnostic(1, "Folder & Resource Check", "FAILED", msg)
        overall_status = "FAILED"
    else:
        # Count files in directory
        file_count = sum(1 for _ in glob.glob(os.path.join(data_dir, "**", "*"), recursive=True) if os.path.isfile(_))
        emit_diagnostic(1, "Folder & Resource Check", "PASSED", f"Detected {file_count} files from folder: {data_dir}")

    # If folder check failed, we cannot proceed with other checks
    if overall_status == "FAILED":
         LOGGER.error("Folder check failed. See drh_diagnostics for details.")
         # Emit failure report immediately
         report_record = {
            "timestamp": timestamp,
            "folder_name": os.path.basename(os.path.normpath(data_dir)) if data_dir else "unknown",
            "tenant_id": "T-unknown", 
            "tenant_name": "Unknown",
            "overall_status": overall_status,
            "report_json": json.dumps({
                "timestamp": timestamp,
                "folderName": os.path.basename(os.path.normpath(data_dir)) if data_dir else "unknown",
                "tenantId": "T-unknown",
                "tenantName": "Unknown",
                "overallStatus": overall_status,
                "results": diagnostic_logs
            })
         }
         emitter.emit_record("drh_validation_reports", report_record)
         return

    # 2. MANDATORY FILE EXISTENCE (Static ID: 2)
    missing = check_required_files(data_dir)
    if missing:
        overall_status = "FAILED"
        emit_diagnostic(2, "Mandatory File Presence", "FAILED", f"Missing files: {', '.join(missing)}")
    else:
        emit_diagnostic(2, "Mandatory File Presence", "PASSED", "All mandatory files present")

    # 3. Extension Checks (Static ID: 3)
    extension_errors = check_file_extensions(data_dir)
    if extension_errors:
        overall_status = "FAILED"
        for err in extension_errors:
             emit_diagnostic(3, "File Extension Validation", "FAILED", err)
    else:
         emit_diagnostic(3, "File Extension Validation", "PASSED", "All configured files have .csv extension")
    
    
    # 4. File Schema Check (Static ID: 4)
    schema_results = check_file_headers(data_dir)
    schema_failures = 0
    for res in schema_results:
         emit_diagnostic(4, res["name"], res["status"], res["details"])
         if res["status"] == "FAILED":
             overall_status = "FAILED"
             schema_failures += 1


    # 5. CGM Metadata Consistency Check (Static ID: 5)
    consistency_results = check_cgm_metadata_consistency(data_dir)
    consistency_failures = 0
    for res in consistency_results:
         emit_diagnostic(5, res["name"], res["status"], res["details"])
         if res["status"] == "FAILED":
             overall_status = "FAILED"
             consistency_failures += 1


    # 6. CGM Data Integrity Check (Static ID: 6)
    integrity_results = check_cgm_data_integrity(data_dir)
    integrity_failures = 0
    for res in integrity_results:
         emit_diagnostic(6, res["name"], res["status"], res["details"])
         if res["status"] == "FAILED":
             overall_status = "FAILED"
             integrity_failures += 1
    
    # 7. Meal Data Validation (Static ID: 7)
    # Only run if meal_file_metadata exists
    if os.path.exists(os.path.join(data_dir, FILES["meal_file_metadata"])):
        meal_consistency_results = check_meal_data_consistency(data_dir)
        for res in meal_consistency_results:
             emit_diagnostic(7, res["name"], res["status"], res["details"])
             if res["status"] == "FAILED":
                 overall_status = "FAILED"
                 integrity_failures += 1

    # 8. Meal Data Integrity Check (Static ID: 8)
    if os.path.exists(os.path.join(data_dir, FILES["meal_file_metadata"])):
        meal_integrity_results = check_meal_data_integrity(data_dir)
        for res in meal_integrity_results:
             emit_diagnostic(8, res["name"], res["status"], res["details"])
             if res["status"] == "FAILED":
                 overall_status = "FAILED"
                 integrity_failures += 1

    # 9. Fitness Data Validation (Static ID: 9)
    # Only run if fitness_file_metadata exists
    if os.path.exists(os.path.join(data_dir, FILES["fitness_file_metadata"])):
        fitness_consistency_results = check_fitness_data_consistency(data_dir)
        for res in fitness_consistency_results:
             emit_diagnostic(9, res["name"], res["status"], res["details"])
             if res["status"] == "FAILED":
                 overall_status = "FAILED"
                 integrity_failures += 1

    # 10. Fitness Data Integrity Check (Static ID: 10)
    if os.path.exists(os.path.join(data_dir, FILES["fitness_file_metadata"])):
        fitness_integrity_results = check_fitness_data_integrity(data_dir)
        for res in fitness_integrity_results:
             emit_diagnostic(10, res["name"], res["status"], res["details"])
             if res["status"] == "FAILED":
                 overall_status = "FAILED"
                 integrity_failures += 1

    # Emit Summary Report
    total_failed = len(missing) + len(extension_errors) + schema_failures + consistency_failures + integrity_failures
    
    report_record = {
        "timestamp": timestamp,
        "folder_name": os.path.basename(os.path.normpath(data_dir)),
        "tenant_id": "T-unknown", 
        "tenant_name": "Unknown",
        "overall_status": overall_status,
        "report_json": json.dumps({
            "timestamp": timestamp,
            "folderName": os.path.basename(os.path.normpath(data_dir)),
            "tenantId": "T-unknown",
            "tenantName": "Unknown",
            "overallStatus": overall_status,
            "results": diagnostic_logs
        })
    }
    emitter.emit_record("drh_validation_reports", report_record)

    if overall_status == "FAILED":
         LOGGER.error(f"Validation failed with {total_failed} errors. See drh_diagnostics for details.")
         return
        
    # Process Combined CGM Tracing (Metadata Driven) - DISABLED
    # process_combined_cgm_tracing(emitter, data_dir)
    process_raw_meal_data(emitter, data_dir)
    process_raw_fitness_data(emitter, data_dir)

    # Process files based on patterns
    for filepath in glob.glob(os.path.join(data_dir, "**", "*.csv"), recursive=True):
        filename = os.path.basename(filepath)
        LOGGER.info(f"Processing {filename}...")
        
        if "cgm_tracing" in filename:
            process_raw_cgm_tracing(emitter, filepath)
            continue # specific processing handled by combined_cgm_tracing
        
        if filename == FILES['participant']:
            process_participant(emitter, filepath)
        elif filename == FILES['study']:
            process_study(emitter, filepath)
        elif filename == FILES['author']:
            process_author(emitter, filepath)
        elif filename == FILES['meal_data']:
            process_meal(emitter, filepath)
        elif filename == FILES['fitness_data']:
            process_fitness(emitter, filepath)
        elif filename == FILES['site']:
             process_site(emitter, filepath)
        elif filename == FILES['investigator']:
             process_investigator(emitter, filepath)
        elif filename == FILES['institution']:
             process_institution(emitter, filepath)
        elif filename == FILES['lab']:
             process_lab(emitter, filepath)
        elif filename == FILES['publication']:
             process_publication(emitter, filepath)
        elif filename == FILES['cgm_file_metadata']:
             process_cgm_file_metadata(emitter, filepath)
        elif filename == FILES['meal_file_metadata']:
             process_meal_file_metadata(emitter, filepath)
        elif filename == FILES['fitness_file_metadata']:
             process_fitness_file_metadata(emitter, filepath)
        else:
            LOGGER.info(f"Skipping unknown file type: {filename}")
    
    # Emit final state
    state = {"last_execution": timestamp}
    emitter.emit_state(state)

if __name__ == "__main__":
    main()
