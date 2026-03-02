#!/usr/bin/env python3
"""
Physionet CGMacros Singer Tap 
- required files -cgm_file_metadata,participant,study,cgm_tracing_* files
- all other files are optional
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
import re
import venv

def bootstrap_venv():
    if sys.prefix != sys.base_prefix:
        return
 
    script_path = os.path.abspath(__file__)
    script_dir = os.path.dirname(script_path)           # singer-tap
    project_root = os.path.dirname(script_dir)          # drh-edge-core
    platform_root = os.path.dirname(project_root)       # spry-drh-edge-platform
    
    venv_dir = os.path.join(project_root, ".venv")
    req_file = os.path.join(platform_root, "requirements.txt")
   
    if sys.platform == "win32":
        venv_python = os.path.join(venv_dir, "Scripts", "python.exe")
    else:
        venv_python = os.path.join(venv_dir, "bin", "python")
 
    if not os.path.exists(venv_python):
        print(f"DEBUG: Creating venv at {venv_dir}", file=sys.stderr)
        venv.EnvBuilder(with_pip=True).create(venv_dir)
 
    # Ensure python-dotenv is installed along with requirements
    check_cmd = [venv_python, "-c", "import drh_target, dotenv"]
    if subprocess.call(check_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
        print(f"DEBUG: Installing from {req_file}...", file=sys.stderr)
        # We explicitly add python-dotenv to ensure it's available for the next step
        subprocess.check_call(
            [venv_python, "-m", "pip", "install", "--upgrade", "-r", req_file, "python-dotenv"],
            stdout=subprocess.DEVNULL, stderr=sys.stderr
        )
 
    os.environ["PYTHONUNBUFFERED"] = "1"
    print(f"DEBUG: Re-executing with {venv_python}", file=sys.stderr)
    os.execv(venv_python, [venv_python, script_path] + sys.argv[1:])

# --- 1. RUN BOOTSTRAP FIRST ---
bootstrap_venv()

# --- 2. LOAD ENV AFTER BOOTSTRAP (Now inside VENV) ---
try:
    from dotenv import load_dotenv # type: ignore
    # Re-calculate platform root to find the .env file  
    _script_dir = os.path.dirname(os.path.abspath(__file__))
    _project_root = os.path.dirname(_script_dir)      
    _env_path = os.path.join(_project_root, ".env")
    
    if os.path.exists(_env_path):
        load_dotenv(_env_path)
    else:
        print(f"DEBUG: .env file not found at {_env_path}", file=sys.stderr)
except ImportError:
    print("DEBUG: python-dotenv not found inside venv", file=sys.stderr)


# Ensure we can import the SDK
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
# from drh_sdk import DRHSingerEmitter # Removed
import importlib.resources
from drh_target.loader import DRHLoader # type: ignore

logging.basicConfig(stream=sys.stderr, level=logging.INFO)
LOGGER = logging.getLogger(__name__)

class OTelNames:
    # Root Span
    ROOT_VV = "V&V Orchestration Session"

    # Category Spans (High-level checks) 
    # Level 2: Categories (Parent Spans - Mapping to Check IDs)
    CAT_FOLDER_SCAN = "1: Folder & Resource Scan"
    CAT_MANDATORY_FILES = "2: Mandatory File Presence"
    CAT_EXTENSION_CHECK = "3: File Extension Validation"
    CAT_SCHEMA_VALIDATION = "4: File Schema Check"
    CAT_CGM_TRACE_METADATA = "5: CGM Tracing Metadata Check"
    CAT_CGM_INTEGRITY = "6: CGM Data Integrity"
    CAT_MEAL_METADATA = "7: Meal Data Metadata Check"
    CAT_MEAL_INTEGRITY = "8: Meal Data Integrity"
    CAT_FITNESS_METADATA = "9: Fitness Metadata Check"
    CAT_FITNESS_INTEGRITY = "10: Fitness Data Integrity"

    # Sub-Spans for Schema Validation (Check 4)
    CHK_FILE_VAL = "4.1: File Validation"
    CHK_COLUMNS = "4.1.a: Required Columns"
    CHK_TYPE = "4.1.b: Type Check"
    CHK_PATTERNS = "4.1.c: Format & Pattern Check"
    CHK_FK_INTEGRITY = "4.1.d: Foreign Key Check" # Currently commented out in code

    # Attributes
    ATTR_VALIDATION_LEVEL = "validation.level"
    ATTR_FILE_NAME = "file.name"
    ATTR_ERROR_COUNT = "error_count"

     
    ATTR_ROW_COUNT = "file.row_count"
    ATTR_STATUS = "check.status"
    ATTR_DETAILS = "details"
   
   # Metric Names
    METRIC_PASS_COUNT = "vv.validation.pass_count"
    METRIC_FAIL_COUNT = "vv.validation.fail_count"
    METRIC_FILE_COUNT = "vv.files.processed_count"
    METRIC_VALIDATION_DURATION = "vv.validation.duration"

class ValidatingDRHLoader(DRHLoader):
    """
    Extension of DRHLoader that validates records against Key Properties and Schema Required fields.
    """
    def __init__(self):
        super().__init__()
        self.schemas = {}
        self.otel_resource_id = None

    def load_schema_if_needed(self, stream_name):
        if stream_name not in self.schemas:
            self.schemas[stream_name] = load_schema(stream_name)
        return self.schemas[stream_name]

    def emit_record(self, stream_name, record):
        # Prevent recursion: Don't validate/log errors for OTel streams themselves
        if stream_name.startswith("otel_"):
             super().emit_record(stream_name, record)
             return

        # Ensure schema is loaded
        schema = self.load_schema_if_needed(stream_name)
        
        # 1. Check Key Properties (Primary Keys)
        # These are critical for unique identification in Singer
        key_props = STREAM_KEYS.get(stream_name, [])
        if key_props:
             missing_keys = [k for k in key_props if k not in record or record.get(k) is None]
             # Filter out tenant fields from validation as per user request
             missing_keys = [k for k in missing_keys if k not in ("tenant_id", "tenant_name")]
             
             if missing_keys:
                 msg = f"Validation Error [Integrity]: Stream '{stream_name}' record missing KEY properties: {missing_keys}. Record skipped."
                 LOGGER.error(msg)
                 if self.otel_resource_id:
                      emit_otel_log(self, self.otel_resource_id, "ERROR", msg, {"stream": stream_name, "error_type": "integrity"})
                 return # Skip emitting

        # 2. Check Required Fields (Mandatory Columns from Schema)
        if schema:
            required_fields = schema.get("required", [])
            if required_fields:
                missing_required = [field for field in required_fields if field not in record]
                # Filter out tenant fields from validation as per user request
                missing_required = [k for k in missing_required if k not in ("tenant_id", "tenant_name")]

                if missing_required:
                    msg = f"Validation Error [Schema]: Stream '{stream_name}' record missing REQUIRED fields: {missing_required}. Record skipped."
                    LOGGER.error(msg)
                    if self.otel_resource_id:
                         emit_otel_log(self, self.otel_resource_id, "ERROR", msg, {"stream": stream_name, "error_type": "schema", "missing_fields": str(missing_required)})
                    return # Skip emitting

        # If validation passes, emit normally
        super().emit_record(stream_name, record)

def load_schema(stream_name):
    try:
        fname = f"{stream_name}.json"
        with importlib.resources.open_text("drh_target.schemas", fname) as f:
            return json.load(f)
    except Exception as e:
        LOGGER.error(f"Failed to load schema for {stream_name}: {e}")
        return {}

ALL_STREAM_NAMES = [
     "cgm_file_metadata",
    "participant", "site", "study", "investigator", "institution",
    "lab", "author", "publication",  "fitness_file_metadata",
     "meal_file_metadata", "drh_validation_reports",
    "drh_diagnostics", "cgm_tracing", "meal", "fitness",
    "otel_resource", "otel_logs", "otel_metrics", "otel_spans"
]

def get_stream_keys():
    keys = {}
    for stream in ALL_STREAM_NAMES:
        schema = load_schema(stream)
        if schema and "key_properties" in schema:
             keys[stream] = schema["key_properties"]
        else:
             keys[stream] = []
    return keys

STREAM_KEYS = get_stream_keys()

# File Configuration from Environment
def get_files_config():
    files = {}
    for stream in ALL_STREAM_NAMES:
        # Construct env var name: e.g. PARTICIPANT_FILE
        env_var = f"{stream.upper()}_FILE"
        default_name = f"{stream}.csv"
        files[stream] = os.path.basename(os.environ.get(env_var, default_name))
    
    # Add legacy/simple keys for validation usage if they are missing
    if "meal_data" not in files:
         files["meal_data"] = os.path.basename(os.environ.get("MEAL_DATA_FILE", "meal_data.csv"))
    if "fitness_data" not in files:
         files["fitness_data"] = os.path.basename(os.environ.get("FITNESS_DATA_FILE", "fitness_data.csv"))
         
    return files

FILES = get_files_config()



MANDATORY_STREAM_NAMES = [
    "participant",
    "institution",
    "lab",
    "study",
    "site",
    "investigator",
    "publication",
    "author",
    "cgm_file_metadata"
]

MANDATORY_FILE_CHECK_STREAMS = [
    "participant",
    "study",
    "cgm_file_metadata"
]

def get_expected_headers():
    headers = {}
    for stream in ALL_STREAM_NAMES:
        schema = load_schema(stream)
        if schema and "required" in schema:
            headers[stream] = schema["required"]
        else:
             # Fallback or warn if schema not found or has no required fields
             # For now, we default to empty list or basic logging
             # LOGGER.warning(f"No required fields found in schema for {stream}") 
             headers[stream] = []
    return headers

EXPECTED_HEADERS = get_expected_headers()

FILE_CACHE = None
def find_file(data_dir, filename):
    global FILE_CACHE
    if FILE_CACHE is None:
        import glob
        FILE_CACHE = {}
        for filepath in glob.glob(os.path.join(data_dir, "**", "*.*"), recursive=True):
            name = os.path.basename(filepath)
            if name not in FILE_CACHE:
                FILE_CACHE[name] = filepath
    return FILE_CACHE.get(filename, os.path.join(data_dir, filename))


def check_file_headers(data_dir, emitter=None, resource_id=None, parent_span_id=None, trace_id=None):
    """
    Check if existing files have required headers AND validate data formats.
    Returns a list of result dicts: {"name": str, "status": str, "details": str}
    """
    results = []
    
    for key, expected_cols in EXPECTED_HEADERS.items():
        fname = FILES.get(key)
        if not fname: 
            continue
        
        fpath = find_file(data_dir, fname)
        if os.path.exists(fpath):
            file_span_id = None
            file_start_time = None 
            if emitter and resource_id:
                # Start File Span
                file_start_time = get_time_nano()
                file_span_id = str(uuid.uuid4()).replace("-", "")[:16]
                # file_span_name = f"File Validation: {fname}" - used in emit call
            
            try:
                with open(fpath, 'r', encoding='utf-8-sig') as f:
                    reader = csv.reader(f)
                    try:
                        # --- 4.1.1 Required Columns Check ---
                        req_cols_start = get_time_nano()
                        req_cols_span_id = str(uuid.uuid4()).replace("-", "")[:16] if (emitter and resource_id) else None
                        
                        header = next(reader)
                        
                        # Build column-level status
                        col_status = []
                        missing_cols = []
                        
                        for col in expected_cols:
                            if col in header:
                                col_status.append(f"{col}: OK")
                            else:
                                if col not in ("tenant_id", "tenant_name"):
                                     col_status.append(f"{col}: MISSING")
                                     missing_cols.append(col)
                                else:
                                     col_status.append(f"{col}: OPTIONAL(ENV)")
                        
                        details = " | ".join(col_status)
                        
                        if missing_cols:
                            # Required Columns FAILED
                            results.append({
                                "name": f"File Schema - Required Columns: {fname}",
                                "status": "FAILED",
                                "details": details
                            })
                            if emitter and resource_id:
                                # Emit Required Columns Span failure
                                emit_otel_span(emitter, resource_id, f"{OTelNames.CHK_COLUMNS}: {fname}", req_cols_start, get_time_nano(), 
                                               parent_span_id=file_span_id, span_id=req_cols_span_id,
                                               attributes={OTelNames.ATTR_VALIDATION_LEVEL: "column_check", OTelNames.ATTR_FILE_NAME: fname, "missing": str(missing_cols)}, 
                                               status_code="ERROR", trace_id=trace_id)
                                
                                # Emit File Span failure
                                emit_otel_span(emitter, resource_id, f"{OTelNames.CHK_FILE_VAL}: {fname}", file_start_time, get_time_nano(), 
                                               parent_span_id=parent_span_id, span_id=file_span_id,
                                               attributes={OTelNames.ATTR_VALIDATION_LEVEL: "schema", OTelNames.ATTR_FILE_NAME: fname, "error": "Missing Columns"}, 
                                               status_code="ERROR", trace_id=trace_id)
                            continue
                        else:
                            # Required Columns PASSED
                            if emitter and resource_id:
                                emit_otel_span(emitter, resource_id, f"{OTelNames.CHK_COLUMNS}: {fname}", req_cols_start, get_time_nano(), 
                                               parent_span_id=file_span_id, span_id=req_cols_span_id,
                                               attributes={OTelNames.ATTR_VALIDATION_LEVEL: "column_check", OTelNames.ATTR_FILE_NAME: fname}, 
                                               status_code="OK", trace_id=trace_id)


                        # --- 4.1.2 Type Check & 4.1.3 Format & Pattern Check ---
                        # These run concurrently in the loop, so they share the start/end time of the loop.
                        data_val_start = get_time_nano()
                        type_span_id = str(uuid.uuid4()).replace("-", "")[:16] if (emitter and resource_id) else None
                        pattern_span_id = str(uuid.uuid4()).replace("-", "")[:16] if (emitter and resource_id) else None
                        
                        schema = load_schema(key)
                        properties = schema.get("properties", {})
                        header_map = {col: i for i, col in enumerate(header)}
                        
                        row_errors = []
                        line_num = 1 # 1-based, starting after header
                        
                        for row in reader:
                            line_num += 1
                            for field_name, field_def in properties.items():
                                if field_name not in header_map: continue
                                idx = header_map[field_name]
                                if idx >= len(row): continue
                                
                                val = row[idx].strip()
                                if not val: continue 

                                # 1. Type Check
                                field_type = field_def.get("type")
                                if isinstance(field_type, list):
                                     field_type = [t for t in field_type if t != "null"][0] if [t for t in field_type if t != "null"] else "string"

                                if field_type == "integer":
                                    if not re.match(r"^-?\d+$", val):
                                         row_errors.append(f"Line {line_num} {field_name}: '{val}' is not an integer")
                                elif field_type == "number":
                                    try:
                                        float(val)
                                    except ValueError:
                                        row_errors.append(f"Line {line_num} {field_name}: '{val}' is not a number")
                                elif field_type == "boolean":
                                    if val.lower() not in ("true", "false", "1", "0"):
                                         row_errors.append(f"Line {line_num} {field_name}: '{val}' is not a boolean")

                                # 2. Format Check (Part of 4.1.3)
                                fmt = field_def.get("format")
                                if fmt == "date-time":
                                    if not re.match(r"^\d{4}-\d{2}-\d{2}", val):
                                         row_errors.append(f"Line {line_num} {field_name}: '{val}' is not a date-time")
                                elif fmt == "date":
                                     if not re.match(r"^\d{4}-\d{2}-\d{2}", val):
                                         row_errors.append(f"Line {line_num} {field_name}: '{val}' is not a date")

                                # 3. Pattern Check (Part of 4.1.3)
                                pattern = field_def.get("pattern")
                                if pattern:
                                    is_excluded_file = any(x in fname for x in ["cgm_tracing", "fitness_data", "meal_data"])
                                    is_date_format = field_def.get("format") in ["date", "date-time"]
                                    
                                    if is_excluded_file and is_date_format:
                                         pass 
                                    else:
                                        try:
                                            if not re.match(pattern, val):
                                                 row_errors.append(f"Line {line_num} {field_name}: '{val}' does not match pattern '{pattern}'")
                                        except re.error:
                                            pass 

                            if len(row_errors) > 10: 
                                row_errors.append("... (too many errors)")
                                break
                        
                        data_val_end = get_time_nano()
                        
                        # Emit Type and Pattern Spans
                        if emitter and resource_id:
                            # We create generic error attributes if failures occurred, though specific attribution to type vs pattern is hard without splitting the error list.
                            # For simplified view: if row_errors exist, we mark both as WARN or ERROR depending on context, or just ERROR.
                            # Since we don't separate type errors from pattern errors in 'row_errors' list easily here without refactoring the list structure,
                            # we will mark both as ERROR if any error exists.
                            
                            sub_status = "ERROR" if row_errors else "OK"
                            err_attr = {"error_count": len(row_errors)} if row_errors else {}
                            
                            emit_otel_span(emitter, resource_id, f"{OTelNames.CHK_TYPE}: {fname}", data_val_start, data_val_end, 
                                           parent_span_id=file_span_id, span_id=type_span_id,
                                           attributes={OTelNames.ATTR_VALIDATION_LEVEL: "type_check", **err_attr}, 
                                           status_code=sub_status, trace_id=trace_id)
                                           
                            emit_otel_span(emitter, resource_id, f"{OTelNames.CHK_PATTERNS}: {fname}", data_val_start, data_val_end, 
                                           parent_span_id=file_span_id, span_id=pattern_span_id,
                                           attributes={OTelNames.ATTR_VALIDATION_LEVEL: "pattern_check", **err_attr}, 
                                           status_code=sub_status, trace_id=trace_id)

                        # --- 4.1.4 Foreign Key Check (Commented) ---
                        # if emitter and resource_id:
                        #    fk_start = get_time_nano()
                        #    fk_span_id = str(uuid.uuid4()).replace("-", "")[:16]
                        #    # ... Logic to check FKs ...
                        #    emit_otel_span(emitter, resource_id, f"{OTelNames.CHK_FK_INTEGRITY}: {fname}", fk_start, get_time_nano(), 
                        #                   parent_span_id=file_span_id, span_id=fk_span_id,
                        #                   attributes={OTelNames.ATTR_VALIDATION_LEVEL: "fk_check"}, status_code="OK", trace_id=trace_id)


                        if row_errors:
                            results.append({
                                "name": f"File Schema Check: {fname}",
                                "status": "FAILED",
                                "details": "; ".join(row_errors[:5])
                            })
                            if emitter and resource_id:
                                emit_otel_span(emitter, resource_id, f"{OTelNames.CHK_FILE_VAL}: {fname}", file_start_time, get_time_nano(), 
                                               parent_span_id=parent_span_id, span_id=file_span_id,
                                               attributes={OTelNames.ATTR_VALIDATION_LEVEL: "schema", OTelNames.ATTR_FILE_NAME: fname, OTelNames.ATTR_ERROR_COUNT: len(row_errors)}, 
                                               status_code="ERROR", trace_id=trace_id)
                        else:
                            results.append({
                                "name": f"File Schema Check: {fname}",
                                "status": "PASSED",
                                "details": "Header & Data Validation OK"
                            })
                            if emitter and resource_id:
                                emit_otel_span(emitter, resource_id, f"{OTelNames.CHK_FILE_VAL}: {fname}", file_start_time, get_time_nano(), 
                                               parent_span_id=parent_span_id, span_id=file_span_id,
                                               attributes={OTelNames.ATTR_VALIDATION_LEVEL: "schema", OTelNames.ATTR_FILE_NAME: fname}, 
                                               status_code="OK", trace_id=trace_id)

                    except StopIteration:
                        # Handle Empty File for Required Columns Check
                        if emitter and resource_id and file_start_time:
                             # Required Columns failed implies it couldn't read header
                             req_cols_span_id = str(uuid.uuid4()).replace("-", "")[:16] # Ensure ID exists
                             req_cols_start = file_start_time # Approx start
                             emit_otel_span(emitter, resource_id, f"{OTelNames.CHK_COLUMNS}: {fname}", req_cols_start, get_time_nano(), 
                                           parent_span_id=file_span_id, span_id=req_cols_span_id,
                                           attributes={OTelNames.ATTR_VALIDATION_LEVEL: "column_check", "error": "Empty File"}, 
                                           status_code="ERROR", trace_id=trace_id)
                        
                        results.append({
                            "name": f"File Schema Check: {fname}",
                            "status": "FAILED",
                            "details": "Empty file - no headers found"
                        })
                        if emitter and resource_id:
                                emit_otel_span(emitter, resource_id, f"{OTelNames.CHK_FILE_VAL}: {fname}", file_start_time, get_time_nano(), 
                                               parent_span_id=parent_span_id, span_id=file_span_id,
                                               attributes={OTelNames.ATTR_VALIDATION_LEVEL: "schema", OTelNames.ATTR_FILE_NAME: fname, "error": "Empty File"}, 
                                               status_code="ERROR", trace_id=trace_id)

            except Exception as e:
                results.append({
                    "name": f"File Schema Check: {fname}",
                    "status": "FAILED",
                    "details": f"Error reading file: {e}"
                })
                # Note: We can't access file_start_time here if it wasn't initialized, but it is inside the 'if exists' block
                if emitter and resource_id and file_start_time is not None: 
                     emit_otel_span(emitter, resource_id, f"{OTelNames.CHK_FILE_VAL}: {fname}", file_start_time, get_time_nano(), 
                                   parent_span_id=parent_span_id, span_id=file_span_id,
                                   attributes={OTelNames.ATTR_VALIDATION_LEVEL: "schema", OTelNames.ATTR_FILE_NAME: fname, "error": str(e)}, 
                                   status_code="ERROR", trace_id=trace_id)

        else:
            # File does not exist, but it might be optional or handled by other checks
            # For now, we don't add a result if the file isn't found here.
            pass
    return results


def check_file_extensions(data_dir):
    """Check if configured files have .csv extension."""
    extension_errors = []
    
    # Only check files defined in the FILES dictionary
    for key, filename in FILES.items():
        # Check extensions only for files that actually exist
        # If a file is missing, check_required_files will handle it (if mandatory)
        if os.path.exists(find_file(data_dir, filename)):
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
        
    cgm_meta_path = find_file(data_dir, cgm_meta_filename)
    
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
                        
                        target_path = find_file(data_dir, expected_file_with_ext)
                        
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
        
    cgm_meta_path = find_file(data_dir, cgm_meta_filename)
    
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
                    
                    target_path = find_file(data_dir, expected_file_with_ext)
                    
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
        
    meal_meta_path = find_file(data_dir, meal_meta_filename)
    
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
                        

                        target_path = find_file(data_dir, expected_file_with_ext)
                        
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
        
    fitness_meta_path = find_file(data_dir, fitness_meta_filename)
    
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
                        
                        target_path = find_file(data_dir, expected_file_with_ext)
                        
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
        
    meal_meta_path = find_file(data_dir, meal_meta_filename)
    
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

                        target_path = find_file(data_dir, expected_file_with_ext)
                        
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
        
    fitness_meta_path = find_file(data_dir, fitness_meta_filename)
    
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

                        target_path = find_file(data_dir, expected_file_with_ext)
                        
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
    for stream in MANDATORY_FILE_CHECK_STREAMS:
        fname = FILES.get(stream)
        if fname and not os.path.exists(find_file(data_dir, fname)):
            missing_files.append(fname)
    
    # Check conditional mandatory files
    # If meal_data exists, meal_file_metadata is required
    if os.path.exists(find_file(data_dir, FILES["meal_data"])):
        if not os.path.exists(find_file(data_dir, FILES["meal_file_metadata"])):
            missing_files.append(FILES["meal_file_metadata"])

    # If fitness_data exists, fitness_file_metadata is required
    if os.path.exists(find_file(data_dir, FILES["fitness_data"])):
        if not os.path.exists(find_file(data_dir, FILES["fitness_file_metadata"])):
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
                    "tenant_id": os.environ.get("TENANT_ID", row.get("tenant_id")),
                    "tenant_name": os.environ.get("TENANT_NAME", row.get("tenant_name"))
                }

                # Normalize dates if present and likely just Date strings (YYYY-MM-DD)
                # for date_field in ["file_upload_date", "data_start_date", "data_end_date"]:
                #     val = record.get(date_field)
                #     if val and "T" not in val:
                #         record[date_field] = val + "T00:00:00Z"
                
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in cgm_file_metadata file {filepath}: {e}")
                if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                     emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in cgm_file_metadata file {filepath}: {e}", {"file": filepath})

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
                     "tenant_id": os.environ.get("TENANT_ID", row.get("tenant_id")),
                     "tenant_name": os.environ.get("TENANT_NAME", row.get("tenant_name"))
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in publication file {filepath}: {e}")
                if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                     emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in publication file {filepath}: {e}", {"file": filepath})

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
        emitter.emit_record("cgm_tracing", record)
        
    except Exception as e:
        LOGGER.error(f"Error processing raw CGM tracing {filepath}: {e}")
        if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
             emit_otel_log(emitter, emitter.otel_resource_id, "ERROR", f"Error processing raw CGM tracing {filepath}: {e}", {"file": filepath})

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
                if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                     emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in file {filepath}: {e}", {"file": filepath})

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
                if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                     emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in file {filepath}: {e}", {"file": filepath})

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
                    "race": row.get("race"),
                    "ethnicity": row.get("ethnicity"),
                    "age": row.get("age"), # No int() cast, schema is STRING
                    "bmi": row.get("bmi"), # No float() cast, schema is STRING
                    "baseline_hba1c": row.get("baseline_hba1c"), # No float() cast
                    "diabetes_type": row.get("diabetes_type"),
                    "study_arm": row.get("study_arm"),
                    # New fields requested by user, likely not in this source file
                    "tenant_id": os.environ.get("TENANT_ID", row.get("tenant_id")), 
                    "tenant_name": os.environ.get("TENANT_NAME", row.get("tenant_name"))
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                 LOGGER.warning(f"Error in participant file {filepath}: {e}")
                 if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                      emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in participant file {filepath}: {e}", {"file": filepath})

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
                    "start_date": row.get("start_date"),
                    "end_date": row.get("end_date"),
                    "treatment_modalities": row.get("treatment_modalities"),
                    "funding_source": row.get("funding_source"),
                    "nct_number": row.get("nct_number"),
                    "study_description": row.get("study_description"),
                    # New fields requested by user
                    "tenant_id": os.environ.get("TENANT_ID", row.get("tenant_id")),
                    "tenant_name": os.environ.get("TENANT_NAME", row.get("tenant_name"))
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in study file {filepath}: {e}")
                if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                     emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in study file {filepath}: {e}", {"file": filepath})

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
                    "tenant_id": os.environ.get("TENANT_ID", row.get("tenant_id")),
                    "tenant_name": os.environ.get("TENANT_NAME", row.get("tenant_name"))
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in investigator file {filepath}: {e}")
                if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                     emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in investigator file {filepath}: {e}", {"file": filepath})

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
                    "tenant_id": os.environ.get("TENANT_ID", row.get("tenant_id")),
                    "tenant_name": os.environ.get("TENANT_NAME", row.get("tenant_name"))
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in institution file {filepath}: {e}")
                if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                     emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in institution file {filepath}: {e}", {"file": filepath})

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
                    "tenant_id": os.environ.get("TENANT_ID", row.get("tenant_id")),
                    "tenant_name": os.environ.get("TENANT_NAME", row.get("tenant_name"))
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in lab file {filepath}: {e}")
                if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                     emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in lab file {filepath}: {e}", {"file": filepath})

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
                 if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                      emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in meal_file_metadata file {filepath}: {e}", {"file": filepath})

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
                 if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                      emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in fitness_file_metadata file {filepath}: {e}", {"file": filepath})

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
                    "tenant_id": os.environ.get("TENANT_ID", row.get("tenant_id")),
                    "tenant_name": os.environ.get("TENANT_NAME", row.get("tenant_name"))
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                LOGGER.warning(f"Error in author file {filepath}: {e}")
                if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                     emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in author file {filepath}: {e}", {"file": filepath})

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
                if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                     emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in meal file {filepath}: {e}", {"file": filepath})

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
                 if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                      emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in fitness file {filepath}: {e}", {"file": filepath})

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
                    "tenant_id": os.environ.get("TENANT_ID", row.get("tenant_id")), 
                    "tenant_name": os.environ.get("TENANT_NAME", row.get("tenant_name"))
                }
                emitter.emit_record(stream_name, record)
            except Exception as e:
                 LOGGER.warning(f"Error in site file {filepath}: {e}")
                 if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                      emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error in site file {filepath}: {e}", {"file": filepath})

def process_combined_cgm_tracing(emitter, data_dir):
    """
    Process CGM data files driven by cgm_file_metadata.csv mapping.
    Iterates through each file listed in metadata, maps columns, and emits combined_cgm_tracing records.
    """
    meta_filename = FILES.get("cgm_file_metadata")
    if not meta_filename: return
    
    meta_path = find_file(data_dir, meta_filename)
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
                tenant_id = os.environ.get("TENANT_ID", row.get("tenant_id"))
                study_id = row.get("study_id")
                
                data_path = find_file(data_dir, file_name)
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
                     if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                          emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error processing CGM data file {file_name}: {e}", {"file": file_name})

    except Exception as e:
        LOGGER.error(f"Error processing combined CGM tracing: {e}")
        if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
             emit_otel_log(emitter, emitter.otel_resource_id, "ERROR", f"Error processing combined CGM tracing: {e}")

def process_raw_meal_data(emitter, data_dir):
    """
    Process raw Meal data files driven by meal_file_metadata.csv.
    Handles duplicate file references.
    """
    meta_filename = FILES.get("meal_file_metadata")
    if not meta_filename: return
    
    meta_path = find_file(data_dir, meta_filename)
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
                
                data_path = find_file(data_dir, file_name)
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
                        emitter.emit_record("meal", record)
                except Exception as e:
                     LOGGER.warning(f"Error processing raw meal file {file_name}: {e}")
                     if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                          emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error processing raw meal file {file_name}: {e}", {"file": file_name})

    except Exception as e:
        LOGGER.error(f"Error processing raw meal metadata: {e}")
        if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
             emit_otel_log(emitter, emitter.otel_resource_id, "ERROR", f"Error processing raw meal metadata: {e}")

def process_raw_fitness_data(emitter, data_dir):
    """
    Process raw Fitness data files driven by fitness_file_metadata.csv.
    Handles duplicate file references.
    """
    meta_filename = FILES.get("fitness_file_metadata")
    if not meta_filename: return
    
    meta_path = find_file(data_dir, meta_filename)
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
                
                data_path = find_file(data_dir, file_name)
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
                        emitter.emit_record("fitness", record)
                except Exception as e:
                     LOGGER.warning(f"Error processing raw fitness file {file_name}: {e}")
                     if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
                          emit_otel_log(emitter, emitter.otel_resource_id, "WARN", f"Error processing raw fitness file {file_name}: {e}", {"file": file_name})

    except Exception as e:
        LOGGER.error(f"Error processing raw fitness metadata: {e}")
        if hasattr(emitter, 'otel_resource_id') and emitter.otel_resource_id:
             emit_otel_log(emitter, emitter.otel_resource_id, "ERROR", f"Error processing raw fitness metadata: {e}")



# OTel Helper Functions

from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SpanExporter, SimpleSpanProcessor, SpanExportResult
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import MetricExporter, MetricExportResult, PeriodicExportingMetricReader
from opentelemetry.sdk._logs import LoggerProvider
from opentelemetry.sdk._logs.export import LogExporter, SimpleLogRecordProcessor, LogExportResult
from opentelemetry._logs import set_logger_provider, LogRecord
from opentelemetry.trace import SpanContext, TraceFlags, NonRecordingSpan
from opentelemetry.trace.status import Status, StatusCode

class SingerSpanExporter(SpanExporter):
    def __init__(self, emitter, resource_id):
        self.emitter = emitter
        self.resource_id = resource_id
    def export(self, spans):
        for span in spans:
            record = {
                "name": span.name,
                "trace_id": format(span.context.trace_id, "032x"),
                "span_id": format(span.context.span_id, "016x"),
                "parent_span_id": format(span.parent.span_id, "016x") if span.parent else "",
                "start_time_unix_nano": span.start_time,
                "end_time_unix_nano": span.end_time,
                "attributes": dict(span.attributes or {}),
                "status_code": {"code": span.status.status_code.name},
                "resource_id": self.resource_id
            }
            self.emitter.emit_record("otel_spans", record)
        return SpanExportResult.SUCCESS

class SingerLogExporter(LogExporter):
    def __init__(self, emitter, resource_id):
        self.emitter = emitter
        self.resource_id = resource_id
    def export(self, log_records):
        for log in log_records:
            record = {
                "time_unix_nano": log.timestamp,
                "trace_id": format(log.trace_id, "032x") if log.trace_id else "",
                "span_id": format(log.span_id, "016x") if log.span_id else "",
                "severity_number": log.severity_number.value if log.severity_number else 9,
                "severity_text": log.severity_text or "INFO",
                "body": str(log.body),
                "attributes": dict(log.attributes or {}),
                "resource_id": self.resource_id
            }
            self.emitter.emit_record("otel_logs", record)
        return LogExportResult.SUCCESS

class SingerMetricExporter(MetricExporter):
    def __init__(self, emitter, resource_id):
        self.emitter = emitter
        self.resource_id = resource_id
    def export(self, metrics_data, timeout_millis=10000, **kwargs):
        for resource_metric in metrics_data.resource_metrics:
            for scope_metric in resource_metric.scope_metrics:
                for metric in scope_metric.metrics:
                    for dp in metric.data.data_points:
                        record = {
                            "name": metric.name,
                            "description": metric.description or f"Metric for {metric.name}",
                            "unit": metric.unit or "1",
                            "time_unix_nano": dp.time_unix_nano,
                            "value": float(dp.value),
                            "attributes": dict(dp.attributes or {}),
                            "resource_id": self.resource_id
                        }
                        self.emitter.emit_record("otel_metrics", record)
        return MetricExportResult.SUCCESS
    def shutdown(self, timeout_millis=30000, **kwargs):
        pass

def get_time_nano():
    """Returns current UTC time in nanoseconds."""
    return int(datetime.now(timezone.utc).timestamp() * 1e9)

def emit_otel_resource(emitter):
    """Emits the OTel Resource definition, initializes global OTel providers, and returns the resource_id."""
    resource_id = str(uuid.uuid4())
    record = {
        "resource_id": resource_id,
        "service.name": os.environ.get("OTEL_SERVICE_NAME", "tap-cgmacros"),
        "service.version": os.environ.get("OTEL_SERVICE_VERSION", "1.0.0"),
        "service.instance.id": resource_id,
        "deployment.environment": os.environ.get("DEPLOY_ENV", "production"),
        "singer.role": "tap",
        "singer.stream": "all"
    }
    emitter.emit_record("otel_resource", record)

    # Initialize Global OTel SDK Providers with Custom Singer Exporters
    tracer_provider = TracerProvider()
    tracer_provider.add_span_processor(SimpleSpanProcessor(SingerSpanExporter(emitter, resource_id)))
    trace.set_tracer_provider(tracer_provider)
    
    logger_provider = LoggerProvider()
    logger_provider.add_log_record_processor(SimpleLogRecordProcessor(SingerLogExporter(emitter, resource_id)))
    opentelemetry._logs.set_logger_provider(logger_provider)

    meter_provider = MeterProvider(metric_readers=[PeriodicExportingMetricReader(SingerMetricExporter(emitter, resource_id), export_interval_millis=100)])
    metrics.set_meter_provider(meter_provider)

    return resource_id

def emit_otel_log(emitter, resource_id, severity, body, attributes=None, span_id="", trace_id=""):
    """Emits an OTel Log record via SDK."""
    if attributes is None: attributes = {}
    severity_map = {"DEBUG": 5, "INFO": 9, "WARN": 13, "ERROR": 17, "FATAL": 21}
    try:
        from opentelemetry.sdk._logs import SeverityNumber
        logger_provider = opentelemetry._logs.get_logger_provider()
        otel_logger = logger_provider.get_logger(__name__)
        tid = int(trace_id, 16) if trace_id else None
        sid = int(span_id, 16) if span_id else None
        sev_num = SeverityNumber(severity_map.get(severity, 9))
        record = LogRecord(
            timestamp=get_time_nano(),
            trace_id=tid,
            span_id=sid,
            trace_flags=TraceFlags(1) if tid else None,
            severity_text=severity,
            severity_number=sev_num,
            body=str(body),
            attributes=attributes
        )
        otel_logger.emit(record)
    except Exception as e:
        LOGGER.error(f"OTel SDK Logging exception: {e}")

def emit_otel_metric(emitter, resource_id, name, value, unit="1", attributes=None):
    """Emits an OTel Metric via SDK."""
    meter = metrics.get_meter(__name__)
    counter = meter.create_counter(name, unit=unit, description=f"Metric for {name}")
    counter.add(value, attributes or {})

def emit_otel_span(emitter, resource_id, name, start_time_nano, end_time_nano, parent_span_id=None, attributes=None, status_code="OK", span_id=None, trace_id=None):
    """Emits an OTel Span via SDK."""
    if attributes is None: attributes = {}
    if not span_id: span_id = str(uuid.uuid4()).replace("-", "")[:16]
    if not trace_id: trace_id = str(uuid.uuid4()).replace("-", "")
    
    tid = int(trace_id, 16)
    sid = int(span_id, 16)
    psid = int(parent_span_id, 16) if parent_span_id else None
    
    status_map = {"OK": StatusCode.OK, "ERROR": StatusCode.ERROR, "UNSET": StatusCode.UNSET}
    
    span_context = SpanContext(trace_id=tid, span_id=sid, is_remote=False, trace_flags=TraceFlags(1))
    parent_context = trace.set_span_in_context(NonRecordingSpan(SpanContext(trace_id=tid, span_id=psid, is_remote=False, trace_flags=TraceFlags(1)))) if psid else None

    tracer = trace.get_tracer(__name__)
    span = tracer.start_span(name, start_time=start_time_nano, context=parent_context)
    
    # Force SDK span internal context to retain manual external IDs provided in original manual tap code.
    span._context = span_context
    span.set_attributes(attributes)
    span.set_status(Status(status_map.get(status_code, StatusCode.OK)))
    span.end(end_time=end_time_nano)
    return span_id, trace_id


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-c", "--config", help="Config file")
    parser.add_argument("-s", "--state", help="State file")
    parser.add_argument("--discover", action="store_true", help="Do discovery")
    args = parser.parse_args()

    execution_span_start = get_time_nano()
    root_span_id = str(uuid.uuid4()).replace("-", "")[:16]
    root_trace_id = str(uuid.uuid4()).replace("-", "")
    emitter = ValidatingDRHLoader()

    if args.discover:
        for s in STREAM_KEYS:
             # Load all schemas for discovery
             schema = load_schema(s)
             keys = STREAM_KEYS.get(s, [])
             emitter.emit_schema(s, schema, keys)
        return

    # Initialize OTel Resource
    try:
        otel_resource_id = emit_otel_resource(emitter)
        emitter.otel_resource_id = otel_resource_id # Provide ID to loader for logging
    except Exception as e:
        LOGGER.warning(f"Failed to emit OTel resource: {e}")
        otel_resource_id = "unknown"

    data_dir = os.environ.get("STUDY_DATA_PATH")
    if args.config:
        try:
             with open(args.config) as f:
                 conf = json.load(f)
                 if "study_data_path" in conf:
                      data_dir = conf["study_data_path"]
        except Exception as e:
             LOGGER.warning(f"Failed to load config file: {e}")
             emit_otel_log(emitter, otel_resource_id, "WARN", f"Failed to load config file: {e}", span_id=root_span_id, trace_id=root_trace_id)

    if not data_dir:
        msg = "STUDY_DATA_PATH environment variable or config not set."
        LOGGER.error(msg)
        emit_otel_log(emitter, otel_resource_id, "FATAL", msg, span_id=root_span_id, trace_id=root_trace_id)
        emit_otel_span(emitter, otel_resource_id, OTelNames.ROOT_VV, execution_span_start, get_time_nano(), status_code="ERROR", span_id=root_span_id, trace_id=root_trace_id)
        sys.exit(1)
    
    # Emit schemas for all supported streams
    for s in ALL_STREAM_NAMES:
        schema = load_schema(s)
        keys = STREAM_KEYS.get(s, [])
        emitter.emit_schema(s, schema, keys)
    
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    overall_status = "SUCCESS"
    check_counter = 1 # Not used for ID anymore, strictly for internal counting if needed
    diagnostic_logs = []
    
    # Simple Metrics Tracking
    files_processed_count = 0
    records_emitted_count_dummy = 0 # DRHLoader doesn't return count, so we'd need to wrap it specifically to count per record. 
    # For now, we'll just track files processed.

    # Context variable for logging
    current_span_id = root_span_id

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

    def fail_and_exit(stage_name, errors_count=1):
         """Helper to emit failure report and exit immediately."""
         LOGGER.error(f"Validation failed at stage: {stage_name}. See drh_diagnostics for details.")
         report_record = {
            "timestamp": timestamp,
            "folder_name": os.path.basename(os.path.normpath(data_dir)) if data_dir else "unknown",
            "tenant_id": os.environ.get("TENANT_ID", "T-unknown"),
            "tenant_name": os.environ.get("TENANT_NAME", "Unknown"),
            "overall_status": "FAILED",
            "report_json": json.dumps({
                "timestamp": timestamp,
                "folderName": os.path.basename(os.path.normpath(data_dir)) if data_dir else "unknown",
                "tenantId": os.environ.get("TENANT_ID", "T-unknown"),
                "tenantName": os.environ.get("TENANT_NAME", "Unknown"),
                "overallStatus": "FAILED",
                "results": diagnostic_logs
            })
         }
         emitter.emit_record("drh_validation_reports", report_record)
         emit_otel_log(emitter, otel_resource_id, "ERROR", f"Validation failed ({stage_name})", {"folder": data_dir, "errors": str(errors_count)}, span_id=current_span_id, trace_id=root_trace_id)
         
         # Emit Failure Span
         emit_otel_span(emitter, otel_resource_id, OTelNames.ROOT_VV, execution_span_start, get_time_nano(), status_code="ERROR", span_id=root_span_id, trace_id=root_trace_id)
         
         sys.exit(0)


    
    # 1. Folder & Resource Check (Static ID: 1)
    folder_val_start = get_time_nano()
    folder_span_id = str(uuid.uuid4()).replace("-", "")[:16]
    current_span_id = folder_span_id # Update context
    folder_msg = ""
    folder_status = "OK"
    
    # Emit Start of Folder Span (optional, usually we emit at end, but for context we might want it visible? No, span is emitted at end)
    
    if not os.path.exists(data_dir):
        msg = f"Data directory does not exist: {data_dir}"
        emit_diagnostic(1, "Folder & Resource Check", "FAILED", msg)
        emit_otel_log(emitter, otel_resource_id, "ERROR", f"Diagnostic FAILED: Folder & Resource Check", attributes={"check_id": 1, "details": msg}, span_id=current_span_id, trace_id=root_trace_id)
        
        emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_FOLDER_SCAN, folder_val_start, get_time_nano(), 
                       parent_span_id=root_span_id, span_id=folder_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "folder", "folder.path": data_dir}, status_code="ERROR")
        fail_and_exit("Folder Check")
    elif not os.path.isdir(data_dir):
        msg = f"Path is not a directory: {data_dir}"
        emit_diagnostic(1, "Folder & Resource Check", "FAILED", msg)
        emit_otel_log(emitter, otel_resource_id, "ERROR", f"Diagnostic FAILED: Folder & Resource Check", attributes={"check_id": 1, "details": msg}, span_id=current_span_id, trace_id=root_trace_id)

        emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_FOLDER_SCAN, folder_val_start, get_time_nano(), 
                       parent_span_id=root_span_id, span_id=folder_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "folder", "folder.path": data_dir}, status_code="ERROR")
        fail_and_exit("Folder Check")
    elif not os.access(data_dir, os.R_OK):
        msg = f"Directory is not readable: {data_dir}"
        emit_diagnostic(1, "Folder & Resource Check", "FAILED", msg)
        emit_otel_log(emitter, otel_resource_id, "ERROR", f"Diagnostic FAILED: Folder & Resource Check", attributes={"check_id": 1, "details": msg}, span_id=current_span_id, trace_id=root_trace_id)

        emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_FOLDER_SCAN, folder_val_start, get_time_nano(), 
                       parent_span_id=root_span_id, span_id=folder_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "folder", "folder.path": data_dir}, status_code="ERROR")
        fail_and_exit("Folder Check")
    else:
        # Count files in directory
        file_count = sum(1 for _ in glob.glob(os.path.join(data_dir, "**", "*"), recursive=True) if os.path.isfile(_))
        msg = f"Detected {file_count} files from folder: {data_dir}"
        emit_diagnostic(1, "Folder & Resource Check", "PASSED", msg)
        emit_otel_log(emitter, otel_resource_id, "INFO", f"Diagnostic PASSED: Folder & Resource Check", attributes={"check_id": 1, "details": msg}, span_id=current_span_id, trace_id=root_trace_id)
        
        emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_FOLDER_SCAN, folder_val_start, get_time_nano(), 
                       parent_span_id=root_span_id, span_id=folder_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "folder", "folder.path": data_dir, "files.found": file_count}, status_code="OK")
        
        # Metrics for Check 1
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_PASS_COUNT, 1, attributes={"check.category": OTelNames.CAT_FOLDER_SCAN})
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_FILE_COUNT, file_count, attributes={"check.category": OTelNames.CAT_FOLDER_SCAN})
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_VALIDATION_DURATION, (get_time_nano() - folder_val_start) / 1e9, unit="s", attributes={"check.category": OTelNames.CAT_FOLDER_SCAN})

    # 2. MANDATORY FILE EXISTENCE (Static ID: 2)
    check2_start = get_time_nano()
    check2_span_id = str(uuid.uuid4()).replace("-", "")[:16]
    current_span_id = check2_span_id # Update context
    missing = check_required_files(data_dir)
    if missing:
        msg = f"Missing files: {', '.join(missing)}"
        emit_diagnostic(2, "Mandatory File Presence", "FAILED", msg)
        emit_otel_log(emitter, otel_resource_id, "ERROR", f"Diagnostic FAILED: Mandatory File Presence", attributes={"check_id": 2, "details": msg}, span_id=current_span_id, trace_id=root_trace_id)

        emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_MANDATORY_FILES, check2_start, get_time_nano(), 
                       parent_span_id=root_span_id, span_id=check2_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "file_presence", "missing": str(missing)}, status_code="ERROR")
        
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_FAIL_COUNT, 1, attributes={"check.category": OTelNames.CAT_MANDATORY_FILES})
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_VALIDATION_DURATION, (get_time_nano() - check2_start) / 1e9, unit="s", attributes={"check.category": OTelNames.CAT_MANDATORY_FILES})
        
        fail_and_exit("Mandatory File Presence", len(missing))
    else:
        emit_diagnostic(2, "Mandatory File Presence", "PASSED", "All mandatory files present")
        emit_otel_log(emitter, otel_resource_id, "INFO", f"Diagnostic PASSED: Mandatory File Presence", attributes={"check_id": 2, "details": "All mandatory files present"}, span_id=current_span_id, trace_id=root_trace_id)

        emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_MANDATORY_FILES, check2_start, get_time_nano(), 
                       parent_span_id=root_span_id, span_id=check2_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "file_presence"}, status_code="OK")
        
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_PASS_COUNT, 1, attributes={"check.category": OTelNames.CAT_MANDATORY_FILES})
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_VALIDATION_DURATION, (get_time_nano() - check2_start) / 1e9, unit="s", attributes={"check.category": OTelNames.CAT_MANDATORY_FILES})
    
    # 3. Extension Checks (Static ID: 3)
    check3_start = get_time_nano()
    check3_span_id = str(uuid.uuid4()).replace("-", "")[:16]
    current_span_id = check3_span_id # Update context
    extension_errors = check_file_extensions(data_dir)
    if extension_errors:
        for err in extension_errors:
             emit_diagnostic(3, "File Extension Validation", "FAILED", err)
             emit_otel_log(emitter, otel_resource_id, "ERROR", f"Diagnostic FAILED: File Extension Validation", attributes={"check_id": 3, "details": err}, span_id=current_span_id, trace_id=root_trace_id)
             
        emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_EXTENSION_CHECK, check3_start, get_time_nano(), 
                       parent_span_id=root_span_id, span_id=check3_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "extensions", OTelNames.ATTR_ERROR_COUNT: len(extension_errors)}, status_code="ERROR")

        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_FAIL_COUNT, len(extension_errors), attributes={"check.category": OTelNames.CAT_EXTENSION_CHECK})
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_VALIDATION_DURATION, (get_time_nano() - check3_start) / 1e9, unit="s", attributes={"check.category": OTelNames.CAT_EXTENSION_CHECK})
        
        fail_and_exit("File Extension Validation", len(extension_errors))
    else:
         msg = "All configured files have .csv extension"
         emit_diagnostic(3, "File Extension Validation", "PASSED", msg)
         emit_otel_log(emitter, otel_resource_id, "INFO", f"Diagnostic PASSED: File Extension Validation", attributes={"check_id": 3, "details": msg}, span_id=current_span_id, trace_id=root_trace_id)

         emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_EXTENSION_CHECK, check3_start, get_time_nano(), 
                       parent_span_id=root_span_id, span_id=check3_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "extensions"}, status_code="OK")
    
    
    # 4. File Schema and Required Columns + Field Format Check (Static ID: 4)
    schema_val_start = get_time_nano()
    # Create the ID for the schema validation span beforehand to pass it down
    schema_span_id = str(uuid.uuid4()).replace("-", "")[:16]
    current_span_id = schema_span_id # Update context
    
    # We call the function passing the parent span ID AND root_trace_id
    schema_results = check_file_headers(data_dir, emitter=emitter, resource_id=otel_resource_id, parent_span_id=schema_span_id, trace_id=root_trace_id)
    
    schema_failures = 0
    for res in schema_results:
         emit_diagnostic(4, res["name"], res["status"], res["details"])
         otel_severity = "INFO" if res["status"] == "PASSED" else "ERROR"
         emit_otel_log(emitter, otel_resource_id, otel_severity, f"Diagnostic {res['status']}: {res['name']}", 
                       attributes={"check_id": 4, "details": res["details"]}, span_id=current_span_id, trace_id=root_trace_id)

         if res["status"] == "FAILED":
             schema_failures += 1
             
    # Now emit completion of the Schema Validation parent span
    # We'll determine status based on results
    schema_status_code = "OK"
    if schema_failures > 0:
        schema_status_code = "ERROR"
        
    emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_SCHEMA_VALIDATION, schema_val_start, get_time_nano(), 
                   parent_span_id=root_span_id, span_id=schema_span_id, trace_id=root_trace_id, 
                   attributes={OTelNames.ATTR_VALIDATION_LEVEL: "schema", "files.checked": len(schema_results), "failures": schema_failures}, 
                   status_code=schema_status_code)

    # Metrics for Check 4
    file_pass_count = len(schema_results) - schema_failures
    emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_PASS_COUNT, file_pass_count, attributes={"check.category": OTelNames.CAT_SCHEMA_VALIDATION})
    emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_FAIL_COUNT, schema_failures, attributes={"check.category": OTelNames.CAT_SCHEMA_VALIDATION})
    emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_FILE_COUNT, len(schema_results), attributes={"check.category": OTelNames.CAT_SCHEMA_VALIDATION})
    emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_VALIDATION_DURATION, (get_time_nano() - schema_val_start) / 1e9, unit="s", attributes={"check.category": OTelNames.CAT_SCHEMA_VALIDATION})
    
    if schema_failures > 0:
        fail_and_exit("File Schema Headers", schema_failures)


    # 5. CGM Metadata Consistency Check (Static ID: 5)
    check5_start = get_time_nano()
    check5_span_id = str(uuid.uuid4()).replace("-", "")[:16]
    current_span_id = check5_span_id # Update context
    consistency_results = check_cgm_metadata_consistency(data_dir)
    consistency_failures = 0
    for res in consistency_results:
         emit_diagnostic(5, res["name"], res["status"], res["details"])
         otel_severity = "INFO" if res["status"] == "PASSED" else "ERROR"
         emit_otel_log(emitter, otel_resource_id, otel_severity, f"Diagnostic {res['status']}: {res['name']}", 
                       attributes={"check_id": 5, "details": res["details"]}, span_id=current_span_id, trace_id=root_trace_id)
         
         if res["status"] == "FAILED":
             consistency_failures += 1
    
    emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_CGM_TRACE_METADATA, check5_start, get_time_nano(), 
                   parent_span_id=root_span_id, span_id=check5_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "cgm_meta", "failures": consistency_failures}, status_code="ERROR" if consistency_failures > 0 else "OK")

    # Metrics for Check 5
    checked_count = len(consistency_results)
    passed_count = checked_count - consistency_failures
    emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_PASS_COUNT, passed_count, attributes={"check.category": OTelNames.CAT_CGM_TRACE_METADATA})
    emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_FAIL_COUNT, consistency_failures, attributes={"check.category": OTelNames.CAT_CGM_TRACE_METADATA})
    emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_VALIDATION_DURATION, (get_time_nano() - check5_start) / 1e9, unit="s", attributes={"check.category": OTelNames.CAT_CGM_TRACE_METADATA})

    if consistency_failures > 0:
        fail_and_exit("CGM Metadata Consistency", consistency_failures)


    # 6. CGM Data Integrity Check (Static ID: 6)
    check6_start = get_time_nano()
    check6_span_id = str(uuid.uuid4()).replace("-", "")[:16]
    current_span_id = check6_span_id # Update context
    integrity_results = check_cgm_data_integrity(data_dir)
    integrity_failures = 0
    for res in integrity_results:
         emit_diagnostic(6, res["name"], res["status"], res["details"])
         otel_severity = "INFO" if res["status"] == "PASSED" else "ERROR"
         emit_otel_log(emitter, otel_resource_id, otel_severity, f"Diagnostic {res['status']}: {res['name']}", 
                       attributes={"check_id": 6, "details": res["details"]}, span_id=current_span_id, trace_id=root_trace_id)

         if res["status"] == "FAILED":
             integrity_failures += 1
    
    emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_CGM_INTEGRITY, check6_start, get_time_nano(), 
                   parent_span_id=root_span_id, span_id=check6_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "cgm_data", "failures": integrity_failures}, status_code="ERROR" if integrity_failures > 0 else "OK")
    
    # Metrics for Check 6
    checked_count = len(integrity_results)
    passed_count = checked_count - integrity_failures
    emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_PASS_COUNT, passed_count, attributes={"check.category": OTelNames.CAT_CGM_INTEGRITY})
    emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_FAIL_COUNT, integrity_failures, attributes={"check.category": OTelNames.CAT_CGM_INTEGRITY})
    emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_VALIDATION_DURATION, (get_time_nano() - check6_start) / 1e9, unit="s", attributes={"check.category": OTelNames.CAT_CGM_INTEGRITY})
    
    if integrity_failures > 0:
        fail_and_exit("CGM Data Integrity", integrity_failures)

    
    # Tracks for conditional execution
    meal_failed = False
    
    # 7. Meal Data Validation (Static ID: 7) & 8. Meal Data Integrity (Static ID: 8)
    # Conditional Execution: Only if meal_file_metadata exists
    if os.path.exists(find_file(data_dir, FILES["meal_file_metadata"])):
        # Check 7
        check7_start = get_time_nano()
        check7_span_id = str(uuid.uuid4()).replace("-", "")[:16]
        current_span_id = check7_span_id # Update context
        
        meal_consistency_results = check_meal_data_consistency(data_dir)
        meal_cons_failures = 0
        for res in meal_consistency_results:
             emit_diagnostic(7, res["name"], res["status"], res["details"])
             otel_severity = "INFO" if res["status"] == "PASSED" else "ERROR"
             emit_otel_log(emitter, otel_resource_id, otel_severity, f"Diagnostic {res['status']}: {res['name']}", 
                       attributes={"check_id": 7, "details": res["details"]}, span_id=current_span_id, trace_id=root_trace_id)

             if res["status"] == "FAILED":
                 overall_status = "FAILED"
                 meal_cons_failures += 1
        
        emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_MEAL_METADATA, check7_start, get_time_nano(), 
                   parent_span_id=root_span_id, span_id=check7_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "meal_meta"}, status_code="ERROR" if meal_cons_failures > 0 else "OK")

        # Metrics for Check 7
        checked_count = len(meal_consistency_results)
        passed_count = checked_count - meal_cons_failures
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_PASS_COUNT, passed_count, attributes={"check.category": OTelNames.CAT_MEAL_METADATA})
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_FAIL_COUNT, meal_cons_failures, attributes={"check.category": OTelNames.CAT_MEAL_METADATA})
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_VALIDATION_DURATION, (get_time_nano() - check7_start) / 1e9, unit="s", attributes={"check.category": OTelNames.CAT_MEAL_METADATA})

        if meal_cons_failures > 0:
             meal_failed = True
             # Do NOT run check 8
        else:
             # Check 8: Only if 7 passed
             check8_start = get_time_nano()
             check8_span_id = str(uuid.uuid4()).replace("-", "")[:16]
             current_span_id = check8_span_id # Update context

             meal_integrity_results = check_meal_data_integrity(data_dir)
             meal_int_failures = 0
             for res in meal_integrity_results:
                  emit_diagnostic(8, res["name"], res["status"], res["details"])
                  otel_severity = "INFO" if res["status"] == "PASSED" else "ERROR"
                  emit_otel_log(emitter, otel_resource_id, otel_severity, f"Diagnostic {res['status']}: {res['name']}", 
                       attributes={"check_id": 8, "details": res["details"]}, span_id=current_span_id, trace_id=root_trace_id)

                  if res["status"] == "FAILED":
                      overall_status = "FAILED"
                      meal_int_failures += 1
             
             emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_MEAL_INTEGRITY, check8_start, get_time_nano(), 
                   parent_span_id=root_span_id, span_id=check8_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "meal_integrity"}, status_code="ERROR" if meal_int_failures > 0 else "OK")

             # Metrics for Check 8
             checked_count = len(meal_integrity_results)
             passed_count = checked_count - meal_int_failures
             emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_PASS_COUNT, passed_count, attributes={"check.category": OTelNames.CAT_MEAL_INTEGRITY})
             emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_FAIL_COUNT, meal_int_failures, attributes={"check.category": OTelNames.CAT_MEAL_INTEGRITY})
             emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_VALIDATION_DURATION, (get_time_nano() - check8_start) / 1e9, unit="s", attributes={"check.category": OTelNames.CAT_MEAL_INTEGRITY})

    # 9. Fitness Data Validation (Static ID: 9) & 10. Fitness Data Integrity (Static ID: 10)
    # Conditional Execution: Only if fitness_file_metadata exists
    if os.path.exists(find_file(data_dir, FILES["fitness_file_metadata"])):
        # Check 9
        check9_start = get_time_nano()
        check9_span_id = str(uuid.uuid4()).replace("-", "")[:16]
        current_span_id = check9_span_id # Update context

        fitness_consistency_results = check_fitness_data_consistency(data_dir)
        fitness_cons_failures = 0
        for res in fitness_consistency_results:
             emit_diagnostic(9, res["name"], res["status"], res["details"])
             otel_severity = "INFO" if res["status"] == "PASSED" else "ERROR"
             emit_otel_log(emitter, otel_resource_id, otel_severity, f"Diagnostic {res['status']}: {res['name']}", 
                       attributes={"check_id": 9, "details": res["details"]}, span_id=current_span_id, trace_id=root_trace_id)

             if res["status"] == "FAILED":
                 overall_status = "FAILED"
                 fitness_cons_failures += 1
        
        emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_FITNESS_METADATA, check9_start, get_time_nano(), 
                   parent_span_id=root_span_id, span_id=check9_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "fitness_meta"}, status_code="ERROR" if fitness_cons_failures > 0 else "OK")

        # Metrics for Check 9
        checked_count = len(fitness_consistency_results)
        passed_count = checked_count - fitness_cons_failures
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_PASS_COUNT, passed_count, attributes={"check.category": OTelNames.CAT_FITNESS_METADATA})
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_FAIL_COUNT, fitness_cons_failures, attributes={"check.category": OTelNames.CAT_FITNESS_METADATA})
        emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_VALIDATION_DURATION, (get_time_nano() - check9_start) / 1e9, unit="s", attributes={"check.category": OTelNames.CAT_FITNESS_METADATA})

        if fitness_cons_failures > 0:
             # Do NOT run check 10
             pass
        else:
             # Check 10: Only if 9 passed
             check10_start = get_time_nano()
             check10_span_id = str(uuid.uuid4()).replace("-", "")[:16]
             current_span_id = check10_span_id # Update context

             fitness_integrity_results = check_fitness_data_integrity(data_dir)
             fitness_int_failures = 0
             for res in fitness_integrity_results:
                  emit_diagnostic(10, res["name"], res["status"], res["details"])
                  otel_severity = "INFO" if res["status"] == "PASSED" else "ERROR"
                  emit_otel_log(emitter, otel_resource_id, otel_severity, f"Diagnostic {res['status']}: {res['name']}", 
                       attributes={"check_id": 10, "details": res["details"]}, span_id=current_span_id, trace_id=root_trace_id)

                  if res["status"] == "FAILED":
                      overall_status = "FAILED"
                      fitness_int_failures += 1
                      
             emit_otel_span(emitter, otel_resource_id, OTelNames.CAT_FITNESS_INTEGRITY, check10_start, get_time_nano(), 
                   parent_span_id=root_span_id, span_id=check10_span_id, trace_id=root_trace_id, attributes={OTelNames.ATTR_VALIDATION_LEVEL: "fitness_integrity"}, status_code="ERROR" if fitness_int_failures > 0 else "OK")

             # Metrics for Check 10
             checked_count = len(fitness_integrity_results)
             passed_count = checked_count - fitness_int_failures
             emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_PASS_COUNT, passed_count, attributes={"check.category": OTelNames.CAT_FITNESS_INTEGRITY})
             emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_FAIL_COUNT, fitness_int_failures, attributes={"check.category": OTelNames.CAT_FITNESS_INTEGRITY})
             emit_otel_metric(emitter, otel_resource_id, OTelNames.METRIC_VALIDATION_DURATION, (get_time_nano() - check10_start) / 1e9, unit="s", attributes={"check.category": OTelNames.CAT_FITNESS_INTEGRITY})
    
    if overall_status == "FAILED":
         # We do not use fail_and_exit here because it exits immediately.
         # This block ensures we ran both Meal/Fitness branches if applicable before final exit.
         LOGGER.error("Validation failed in Meal or Fitness checks. See drh_diagnostics for details.")
         emit_otel_log(emitter, otel_resource_id, "ERROR", "Validation failed (Meal/Fitness Phase)", {"folder": data_dir})
         
         # Emit Report
         report_record = {
            "timestamp": timestamp,
            "folder_name": os.path.basename(os.path.normpath(data_dir)),
            "tenant_id": os.environ.get("TENANT_ID", "T-unknown"),
            "tenant_name": os.environ.get("TENANT_NAME", "Unknown"),
            "overall_status": overall_status,
            "report_json": json.dumps({
                "timestamp": timestamp,
                "folderName": os.path.basename(os.path.normpath(data_dir)),
                "tenantId": os.environ.get("TENANT_ID", "T-unknown"),
                "tenantName": os.environ.get("TENANT_NAME", "Unknown"),
                "overallStatus": overall_status,
                "results": diagnostic_logs
            })
         }
         emitter.emit_record("drh_validation_reports", report_record)
         
         # Emit Failure Span
         emit_otel_span(emitter, otel_resource_id, OTelNames.ROOT_VV, execution_span_start, get_time_nano(), status_code="ERROR", span_id=root_span_id, trace_id=root_trace_id)
         sys.exit(0)

    # Emit Summary Report (Success Path Only)
    # Failures in 7-10 are handled in the block above
    report_record = {
        "timestamp": timestamp,
        "folder_name": os.path.basename(os.path.normpath(data_dir)),
        "tenant_id": os.environ.get("TENANT_ID", "T-unknown"),
        "tenant_name": os.environ.get("TENANT_NAME", "Unknown"),
        "overall_status": overall_status,
        "report_json": json.dumps({
            "timestamp": timestamp,
            "folderName": os.path.basename(os.path.normpath(data_dir)),
            "tenantId": os.environ.get("TENANT_ID", "T-unknown"),
            "tenantName": os.environ.get("TENANT_NAME", "Unknown"),
            "overallStatus": overall_status,
            "results": diagnostic_logs
        })
    }
    emitter.emit_record("drh_validation_reports", report_record)
    # No fail check here needed, handled above
        
    # Process Combined CGM Tracing (Metadata Driven) - DISABLED
    # process_combined_cgm_tracing(emitter, data_dir)
    process_raw_meal_data(emitter, data_dir)
    process_raw_fitness_data(emitter, data_dir)

    # Map streams to their processing functions
    STREAM_PROCESSORS = {
        "participant": process_participant,
        "study": process_study,
        "author": process_author,
        # "meal_data": process_meal,
        # "fitness_data": process_fitness,
        "site": process_site,
        "investigator": process_investigator,
        "institution": process_institution,
        "lab": process_lab,
        "publication": process_publication,
        "cgm_file_metadata": process_cgm_file_metadata,
        "meal_file_metadata": process_meal_file_metadata,
        "fitness_file_metadata": process_fitness_file_metadata
        # combined_cgm_tracing is disabled/custom
        # raw data is handled separately or via metadata
    }

    # Create reverse mapping: filename -> stream_name
    filename_to_stream = {v: k for k, v in FILES.items() if k not in ("meal_data", "fitness_data")}

    # Process files based on patterns
    for filepath in glob.glob(os.path.join(data_dir, "**", "*.csv"), recursive=True):
        files_processed_count += 1
        filename = os.path.basename(filepath)
       
        # Exclude meal_data and fitness_data as requested
        if filename in (FILES.get("meal_data"), FILES.get("fitness_data")):
             continue

        LOGGER.info(f"Processing {filename}...")
       

        # 1. Check for exact match via Configuration (User's request)
        if filename in filename_to_stream:
            stream_name = filename_to_stream[filename]
            processor = STREAM_PROCESSORS.get(stream_name)
            if processor:
                processor(emitter, filepath)
                continue
            else:
                LOGGER.warning(f"No processor defined for stream {stream_name} (file: {filename})")

        # 2. Fallback / Special Pattern Matching
        if "cgm_tracing" in filename or "CGMacros" in filename:
            process_raw_cgm_tracing(emitter, filepath)
            continue 
        
        # If we reached here, it didn't match any configured file or known pattern
        # We only log if it's not one of the raw files we processed simply by metadata check previously
        # (Though actually, process_raw_meal_data iterates the metadata, it doesn't consume the file in this loop.
        # So we might want to skip logging "unknown" if it was handled by raw readers? 
        # The original code processed raw via metadata + this loop for others. 
        # We'll stick to logging unknown.)
        LOGGER.info(f"Skipping unknown file type: {filename}")
        emit_otel_log(emitter, otel_resource_id, "WARN", f"Skipping unknown file type: {filename}")
        
    # Emit Metrics
    emit_otel_metric(emitter, otel_resource_id, "files_processed", files_processed_count, "1")
    # emit_otel_metric(emitter, otel_resource_id, "records_processed", records_emitted_count_dummy, "1")

    # Emit final state
    state = {"last_execution": timestamp}
    emitter.emit_state(state)

    # Emit Final SUCCESS Span
    emit_otel_span(emitter, otel_resource_id, OTelNames.ROOT_VV, execution_span_start, get_time_nano(), status_code="OK", span_id=root_span_id, trace_id=root_trace_id)

if __name__ == "__main__":
    main()
