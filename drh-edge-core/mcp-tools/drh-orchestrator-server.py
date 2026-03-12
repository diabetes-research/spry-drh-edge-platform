import sys
import subprocess

import os
import glob
import pandas as pd # type: ignore
from mcp.server.fastmcp import FastMCP # type: ignore
import socket # type: ignore
import psutil # type: ignore

# Initialize the server
mcp = FastMCP("DRH-EDGE-Orchestrator")

# --- PATH LOGIC ---
# This ensures we always find the project root, no matter where the server starts
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
ENV_PATH = os.path.join(PROJECT_ROOT, ".env")

def get_spry_command():
    """Checks if spry is in PATH, otherwise looks for a local binary."""
    if subprocess.run(["which", "spry"], capture_output=True).returncode == 0:
        return "spry"
    
    # Check for a local bin folder common in many setups
    local_spry = os.path.join(PROJECT_ROOT, "bin", "spry")
    if os.path.exists(local_spry):
        return local_spry
    
    return "spry" # Fallback to global and hope for the best

def is_port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(('localhost', port)) == 0

@mcp.tool()
def reset_drh_environment():
    """Runs the reset.sh script to wipe the local database and environment."""
    # 1. Get the directory where THIS python file is located
    # (e.g., /Users/anitha/projects/drh-edge-platform/drh-edge-core/mcp-tools/)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    
    # 2. Find reset.sh relative to the python script
    # Assuming reset.sh is in the same folder as this python file:
    reset_script_path = os.path.join(script_dir, "reset.sh")
    
    # 3. If reset.sh is one level up (in drh-edge-core/), use:
    # reset_script_path = os.path.join(script_dir, "..", "reset.sh")

    if not os.path.exists(reset_script_path):
        return f"Error: Could not find {reset_script_path}"

    try:
        # 4. Run the script. 
        # We use 'cwd=...' to make sure the bash script runs INSIDE its own folder
        result = subprocess.run(
            ["bash", reset_script_path], 
            capture_output=True, 
            text=True, 
            check=True
        )
        return f"Reset Successful:\n{result.stdout}"
    except subprocess.CalledProcessError as e:
        return f"Reset Failed (Exit Code {e.returncode}):\n{e.stderr}"

@mcp.tool()
def configure_study_context(runbook_name: str, study_data_path: str, tenant_name: str, tenant_id: str, otel_name: str = "tap-orchestrator"):
    """
    Writes the .env file and executes the runbook's prepare-env task.
    This ensures the local environment matches the study requirements.
    """
    # 1. Prepare the content using the arguments passed by the AI
    env_content = (
        f'OTEL_SERVICE_NAME="{otel_name}"\n'
        f'OTEL_SERVICE_VERSION="1.0.0"\n'
        f'STUDY_DATA_PATH="{study_data_path}"\n'
        f'TENANT_ID="{tenant_id}"\n'
        f'TENANT_NAME="{tenant_name}"\n'
    )
    
    # 2. Write to the absolute root .env
    try:
        with open(ENV_PATH, "w") as f:
            f.write(env_content)
            
        spry_cmd = get_spry_command()
        
        # 3. Run the spry task to 'lock in' the environment (e.g., generating .envrc)
        result = subprocess.run(
            [spry_cmd, "rb", "task", "prepare-env", runbook_name],
            cwd=PROJECT_ROOT,
            capture_output=True, 
            text=True, 
            check=True
        )
        return f"✅ .env updated at {ENV_PATH}\n✅ Spry prepare-env executed.\n\nOutput:\n{result.stdout}"
        
    except Exception as e:
        return f"❌ Configuration failed: {str(e)}"

@mcp.tool()
def run_ingestion_pipeline(runbook_name: str):
    """Executes ingestion with stage awareness and UI launch."""
    spry_cmd = get_spry_command()
    port = 9227
    
    # 1. Check Port Availability
    if is_port_in_use(port):
        return f"CRITICAL: Port {port} is already in use. Please stop the existing service or use 'fuser -k {port}/tcp' in WSL before starting."

    print(f"STAGE 1: Initializing ingestion for {runbook_name}...")
    
    try:
        # Use Popen to stream logs
        process = subprocess.Popen(
            [spry_cmd, "rb", "task", "prepare-db-deploy-server", runbook_name],
            cwd=PROJECT_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True
        )

        full_output = []
        for line in iter(process.stdout.readline, ""):
            line_str = line.strip()
            full_output.append(line_str)
            
            # Informing each stage based on spry output patterns
            if "Validation" in line_str:
                print(f"STAGE 2: Running Data Validations...")
            if "Executing SQL" in line_str:
                print(f"STAGE 3: Building SQLite Database...")
            
            # Immediate Error Capture
            if "FAILED" in line_str or "ERROR" in line_str:
                process.kill()
                return f"FAILURE detected at runtime:\n{line_str}\n\nFull Log Summary:\n{os.linesep.join(full_output[-10:])}"

        process.wait(timeout=600)
        
        # 2. If Success, Start the UI
        if process.returncode == 0:
            print(f"STAGE 4: Ingestion Success. Launching Web UI...")
            # We run this as a detached process so it doesn't block the MCP server
            subprocess.Popen(["surveilr", "web-ui"], cwd=PROJECT_ROOT)
            return f"COMPLETED: Ingestion successful. UI is now starting at http://localhost:{port}"
        else:
            return f"ERROR: Process exited with code {process.returncode}."

    except Exception as e:
        return f"SYSTEM ERROR: {str(e)}"

@mcp.tool()
def list_available_runbooks():
    """Scans the repository root for available DRH Markdown runbooks."""
    # ✅ Always look in the PROJECT_ROOT regardless of where the script started
    search_pattern = os.path.join(PROJECT_ROOT, "drh-*.md")
    files = glob.glob(search_pattern)
    
    # Return just the filenames for cleaner AI reading
    filenames = [os.path.basename(f) for f in files]
    return {"runbooks": filenames} if filenames else "No runbooks found in project root."

if __name__ == "__main__":
    mcp.run()

