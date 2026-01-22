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
import sys
import json
import csv
import subprocess
import logging
import argparse
from pathlib import Path

# =============================================================================
# DEPENDENCY MANAGEMENT
# =============================================================================

def setup_logging():
    """Setup logging before singer is imported"""
    logging.basicConfig(
        level=logging.INFO,
        format='[tap-simplera-cgm] %(levelname)s: %(message)s',
        stream=sys.stderr
    )
    return logging.getLogger("tap-simplera-cgm")

LOGGER = setup_logging()

def setup_virtual_environment(script_dir: Path) -> Path:
    """Setup or use existing virtual environment for dependencies"""
    # Create venv in workspace root (parent of singer-tap folder)
    venv_path = script_dir.parent / ".tap-venv"
    
    if not venv_path.exists():
        LOGGER.info("Creating virtual environment...")
        try:
            subprocess.run([sys.executable, "-m", "venv", str(venv_path)], check=True, capture_output=True)
            LOGGER.info("Virtual environment created successfully")
        except subprocess.CalledProcessError as e:
            LOGGER.error(f"Failed to create virtual environment: {e}")
            raise
    
    return venv_path

def install_dependencies(venv_path: Path):
    """Install required Singer dependencies if not already installed"""
    # Always use the provided venv_path
    if os.name == 'nt':  # Windows
        pip_cmd = str(venv_path / "Scripts" / "pip")
        python_cmd = str(venv_path / "Scripts" / "python")
    else:  # Unix/Linux/macOS
        pip_cmd = str(venv_path / "bin" / "pip")
        python_cmd = str(venv_path / "bin" / "python")
    LOGGER.info(f"Using virtual environment at {venv_path}")
    
    # Check if singer-python is already installed
    try:
        result = subprocess.run([python_cmd, "-c", "import singer"], 
                              capture_output=True, text=True)
        if result.returncode == 0:
            LOGGER.info("singer-python already installed")
            return python_cmd
    except:
        pass
    
    LOGGER.info("Installing singer-python dependencies...")
    try:
        # Upgrade pip
        subprocess.run([pip_cmd, "install", "--upgrade", "pip"], check=True, capture_output=True)
        # Install singer-python
        subprocess.run([pip_cmd, "install", "singer-python"], check=True, capture_output=True)
        LOGGER.info("Dependencies installed successfully")
    except subprocess.CalledProcessError as e:
        LOGGER.error(f"Failed to install dependencies: {e}")
        raise
    
    return python_cmd

def ensure_dependencies():
    """Ensure all dependencies are installed before running the tap"""
    script_dir = Path(__file__).parent
    
    # Try to import singer, if it fails, setup environment
    try:
        import singer
        return singer
    except ImportError:
        LOGGER.info("singer-python not found, setting up environment...")
        venv_path = setup_virtual_environment(script_dir)
        python_cmd = install_dependencies(venv_path)
        
        # Re-execute this script with the virtual environment's Python
        LOGGER.info("Re-executing script with virtual environment...")
        os.execv(python_cmd, [python_cmd] + sys.argv)

# Ensure dependencies and import singer
singleton_singer = ensure_dependencies()
if singleton_singer:
    singer = singleton_singer
else:
    import singer

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
    try:
        parser = argparse.ArgumentParser()
        parser.add_argument("-c", "--config", help="Config file")
        parser.add_argument("-s", "--state", help="State file")
        parser.add_argument("-d", "--discover", action="store_true", help="Discovery mode")
        args = parser.parse_args()
        
        LOGGER.info("Starting Simplera CGM tap extraction")
        
        if args.discover:
            do_discover()
        else:
            config = load_config(args.config)
            state = load_state(args.state)
            do_sync(config, state)
        
        LOGGER.info("Extraction complete")
        
    except Exception as e:
        LOGGER.error(f"Tap execution failed: {e}")
        sys.exit(1)


if __name__ == "__main__":

    main()


