#!/usr/bin/env python3
"""
Participant → CGM Singer Tap (Surveilr-compatible)

- Reads participant IDs from participant.csv
- Searches CGM CSV files in a directory for matching IDs (filename or column)
- Emits Singer SCHEMA, RECORD, and STATE messages
- Config priority:
    1. config.json (if passed as CLI arg)
    2. .env file (auto-loaded if present)
    3. Environment variables (already exported in shell)
"""

import os
import json
import csv
import singer
import argparse
from pathlib import Path

LOGGER = singer.get_logger()
SCHEMA = {
    "properties": {
        "participant_id": {"type": ["null", "string"]},
        "date_time": {"type": ["null", "string"], "format": "date-time"},
        "cgm_value": {"type": ["null", "number"]}
    }
}

# ---------------------------------------------------------------------------
# ENV / CONFIG / STATE LOADING
# ---------------------------------------------------------------------------

def load_env_file(env_path="./envrc"):
    """Load environment variables from a .envrc file if present."""
    env_file = Path(env_path)
    if env_file.exists():
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    # Handle both 'export KEY=VALUE' and 'KEY=VALUE' formats
                    if line.startswith("export "):
                        line = line[7:]  # Remove 'export ' prefix
                    key, value = line.split("=", 1)
                    os.environ[key.strip()] = value.strip()

def load_config(config_file=None):
    """Load config from file and environment variables."""
    load_env_file()
    config = {}
    if config_file and os.path.exists(config_file):
        with open(config_file) as f:
            config = json.load(f)
    # Env overrides config
    config["participant_file"] = os.getenv("PARTICIPANT_FILE", config.get("participant_file"))
    config["cgm_dir"] = os.getenv("CGM_DIR", config.get("cgm_dir"))
    config["simplera_cgm_file_pattern"] = os.getenv("SIMPLERA_CGM_FILE_PATTERN", config.get("simplera_cgm_file_pattern", "cgm_tracing"))
    if not config.get("participant_file") or not config.get("cgm_dir"):
        raise RuntimeError("Missing participant_file or cgm_dir. Set in a --config file, a .env file, or as environment variables (PARTICIPANT_FILE, CGM_DIR).")
    return config

def load_state(state_file):
    """Load state from a file."""
    state = {}
    if state_file and os.path.exists(state_file):
        try:
            with open(state_file) as f:
                state = json.load(f)
        except json.JSONDecodeError:
            LOGGER.warning(f"Could not decode state file {state_file}. Starting with empty state.")
    return state



# ---------------------------------------------------------------------------
# TAP LOGIC
# ---------------------------------------------------------------------------

def do_discover():
    """Emit a Singer catalog for the stream."""
    catalog = {
        "streams": [
            {
                "tap_stream_id": "cgm_readings",
                "stream": "cgm_readings",
                "schema": SCHEMA,
                "key_properties": ["participant_id", "date_time"]
            }
        ]
    }
    print(json.dumps(catalog, indent=2))

def find_matching_files(participant_id, search_dir, participant_file, file_pattern="cgm_tracing"):
    """Find CSV files containing file_pattern and participant_id in filename or columns, excluding participant.csv."""
    matches = []
    for fname in os.listdir(search_dir):
        if not fname.endswith(".csv"):
            continue
        # Only process files matching the file_pattern (e.g., 'cgm_tracing' for Simplera)
        if file_pattern not in fname:
            continue
        path = os.path.join(search_dir, fname)
        if os.path.abspath(path) == os.path.abspath(participant_file):
            continue
        if participant_id in fname:
            matches.append(path)
            continue
        try:
            with open(path, newline="") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    if participant_id in row.values():
                        matches.append(path)
                        break

        except Exception as e:
            LOGGER.warning(f"Error scanning {path}: {e}")
    return list(set(matches)) # Return unique paths



def do_sync(config, state):
    """
    This function contains the core logic of the tap.
    """
    singer.write_schema("cgm_readings", SCHEMA, ["participant_id", "date_time"])
    participant_file = config["participant_file"]
    search_dir = config["cgm_dir"]
    file_pattern = config.get("simplera_cgm_file_pattern", "cgm_tracing")
    processed_files = set(state.get("processed_files", []))
    
    with open(participant_file, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            pid = row.get("participant_id")
            if not pid:
                continue
          
            files = find_matching_files(pid, search_dir, participant_file, file_pattern)
           
            for fname in files:
                if fname in processed_files:
                    continue
             
                try:
                    with open(fname, newline="") as cf:
                        creader = csv.DictReader(cf)
                        for crow in creader:
                            record = {
                                "participant_id": pid,
                                "date_time": crow.get("Date_Time"),
                                "cgm_value": crow.get("CGM_Value")
                            }

                            singer.write_record("cgm_readings", record)
                    processed_files.add(fname)
                    state["processed_files"] = list(processed_files)
                    singer.write_state(state)
                
                except Exception as e:
                    LOGGER.warning(f"Error reading {fname}: {e}")

# ---------------------------------------------------------------------------
# MAIN ENTRY
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-c", "--config", help="Config file")
    parser.add_argument("-s", "--state", help="State file")
    parser.add_argument("-d", "--discover", action="store_true", help="Discovery mode")
    args = parser.parse_args()
    if args.discover:
        do_discover()
    else:
        config = load_config(args.config)
        state = load_state(args.state)
        do_sync(config, state)


if __name__ == "__main__":

    main()


