#!/bin/bash

# ==============================================================================
# DATA PROCESSING PIPELINE
# Executes ingestion, transformation, de-identification, and DuckDB for ETL pipeline.
# Requires data path, tenant ID, and tenant name.
# ==============================================================================

# Exit immediately if a command exits with a non-zero status.
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error.
# -o pipefail: Pipeline exit status is that of the last command that failed.
set -euo pipefail

# --- Usage ---
usage() {
    echo "Usage: $0 --data_path <folder_path> --tenant_id <ID> --tenant_name <Name>"
    echo "Example: $0 --data_path raw-data/flexi-cgm-study/ --tenant_id CTR001 --tenant_name \"CTR Study 001\""
    echo "The study name (e.g., 'flexi-cgm-study') will be derived from the folder name."
    exit 1
}

# --- Parse arguments ---
DATA_PATH=""
TENANT_ID=""
TENANT_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --data_path)
            DATA_PATH="$2"
            shift 2
            ;;
        --tenant_id)
            TENANT_ID="$2"
            shift 2
            ;;
        --tenant_name)
            TENANT_NAME="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

# Validate arguments
if [[ -z "$DATA_PATH" || -z "$TENANT_ID" || -z "$TENANT_NAME" ]]; then
    usage
fi

# --- Derive STUDY_NAME from DATA_PATH ---
# 1. Remove trailing slash(es)
CLEAN_PATH="${DATA_PATH%/}"
# 2. Extract the last component (folder name)
STUDY_NAME=$(basename "$CLEAN_PATH")

echo "Derived Study Folder Name: $STUDY_NAME"

# --- Configuration ---
# DUCK_DB_FILE is the final DuckDB database file
# This is the constant name as requested.
DUCK_DB_FILE="DRH.studydata.duckdb"

# SQLITE_DB_FILE is the file name expected/created by the 'surveilr' tool
SQLITE_DB_FILE="resource-surveillance.sqlite.db"

# 1. The name required by the hard-coded Sqlpage configuration (The FINAL file)
FINAL_DB_NAME="DRH.studydata.sqlite.db"
ARCHIVE_DIR="study-db-archive"
ARCHIVE_BASE_NAME="DRH.${STUDY_NAME}"
# Full Pattern will be: DRh.flexi-cgm-study.V001.sqlite.db

# --- Check and create archive directory ---
if [[ ! -d "$ARCHIVE_DIR" ]]; then
    echo "Archive directory '$ARCHIVE_DIR' not found. Creating it."
    mkdir -p "$ARCHIVE_DIR"
fi


# TEMP_DIR for intermediate generated SQL files
TEMP_DIR="temp"
LOG_DIR="logs"


# Path to the dynamic view generator
DYNAMIC_SQL_GENERATOR="duckdb-etl-sql/01-combined-cgm-sql-generator.sql"
# Updated to avoid confusion with the template name
GENERATED_VIEW_SQL_FILE="${TEMP_DIR}/01-generated-view-query.sql" 
EXECUTE_UNION_SQL_FILE="${TEMP_DIR}/01-execute-union-view.sql" 

JSON_GENERATOR_SQL="duckdb-etl-sql/02-create-file-meta-ingest-data.sql"
# Path for the generated INSERT query output
GENERATED_INSERT_SQL_FILE="${TEMP_DIR}/02-generated-insert-query.sql"

# Path for the substituted and executable generator script
EXECUTABLE_GENERATOR_SQL="${TEMP_DIR}/02-generator-substituted.sql"

# Path to your common SQL directory
COMMON_SQL_PATH="common-sql"
# New temporary script for the DuckDB ETL
TEMP_INGEST_SQL="${TEMP_DIR}/temp_duckdb-ingestion-filemetadata.sql"
# Path to the base SQL template.
# Includes the 'duckdb-etl-sql/' folder prefix.
BASE_SQL_TEMPLATE="duckdb-etl-sql/duckdb-ingestion-filemetadata.sql"
LOG_FILE="final_ingestion_log.sql"


# Clean up and setup directories
echo "Setting up environment: Cleaning up temporary folders,Sqlite DB and DuckDB file..."
rm -f "$DUCK_DB_FILE"
rm -f "$SQLITE_DB_FILE"
rm -f "$FINAL_DB_NAME"
rm -rf "$TEMP_DIR" 
mkdir -p "$TEMP_DIR" 








echo "1. Ingesting raw files from $DATA_PATH into $SQLITE_DB_FILE..."
# PASSING TENANT ID/NAME TO SURVEILR INGEST
surveilr ingest files -r "$DATA_PATH" --tenant-id "$TENANT_ID" --tenant-name "$TENANT_NAME" && surveilr orchestrate transform-csv
if [ $? -ne 0 ]; then
    echo "ERROR: Surveilr ingestion and csv transformation failed."
    exit 1
fi
echo "Ingestion and CSV transformation complete."

# --- STEP 2: DE-IDENTIFICATION & V&V (SQLite) ---
echo "2. Applying De-identification and Verification/Validation (V&V)..."
surveilr shell "${COMMON_SQL_PATH}/drh-deidentify-vv.sql"
echo "De-identification and V&V complete."

# --- STEP 3: COMMON DDL ---
echo "3. Executing common study DDL..."
surveilr shell "${COMMON_SQL_PATH}/drh-study-common-ddl.sql"
echo "DDL complete."

# ----------------------------------------------------------------------------------
# --- STEP 4: DUCKDB ANALYTICAL LOAD (Integration Point) ---
# ----------------------------------------------------------------------------------

# FIXED: Generate the DB_FILE_ID here for use in the generator script
DB_FILE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]' || echo "00000000-0000-0000-0000-000000000000")
# echo "Generated DB_FILE_ID: $DB_FILE_ID"

# 4a. Generating dynamic CREATE VIEW query string from metadata...
echo -e "\n4a. Generating dynamic CREATE VIEW query string from metadata..."

# 1. Read the base generator script and perform ALL substitutions
GENERATOR_SQL_CONTENT=$(cat "$DYNAMIC_SQL_GENERATOR")

# Perform substitutions for all required placeholders, including the new file path:
GENERATOR_SQL_CONTENT=$(echo "$GENERATOR_SQL_CONTENT" | sed "s|__SQLITE_DB_PATH__|${SQLITE_DB_FILE}|g")
GENERATOR_SQL_CONTENT=$(echo "$GENERATOR_SQL_CONTENT" | sed "s|__DB_FILE_ID__|${DB_FILE_ID}|g") 
GENERATOR_SQL_CONTENT=$(echo "$GENERATOR_SQL_CONTENT" | sed "s|__TENANT_ID__|${TENANT_ID}|g") 
GENERATOR_SQL_CONTENT=$(echo "$GENERATOR_SQL_CONTENT" | sed "s|__TENANT_NAME__|${TENANT_NAME}|g") 
# NEW SUBSTITUTION: Pass the output file path to the SQL generator script
GENERATOR_SQL_CONTENT=$(echo "$GENERATOR_SQL_CONTENT" | sed "s|__TEMP_VIEW_SQL_PATH__|${GENERATED_VIEW_SQL_FILE}|g")

# 2. Write the fully substituted SQL to a temporary executable file
GENERATED_UNION_SQL_FILE="${TEMP_DIR}/01-combined-cgm-sql-generator-substituted.sql"
echo "$GENERATOR_SQL_CONTENT" > "$GENERATED_UNION_SQL_FILE"

# 3. Execute the GENERATED script. It now WRITES the final query to ${GENERATED_VIEW_SQL_FILE}
echo "Executing generator to write final query to ${GENERATED_VIEW_SQL_FILE}"
duckdb "$SQLITE_DB_FILE" -c ".read $GENERATED_UNION_SQL_FILE" --batch

if [ $? -ne 0 ]; then
    echo "ERROR: DuckDB failed to execute the SQL generator (4b)."
    exit 1
fi

# 4. Read the complete, non-truncated query directly from the file
UNION_ALL_QUERY=$(cat "$GENERATED_VIEW_SQL_FILE")

if [ -z "$UNION_ALL_QUERY" ]; then
    echo "WARNING: Dynamic UNION ALL query generation resulted in an empty string. Setting placeholder view."
    UNION_ALL_QUERY="CREATE OR REPLACE TEMPORARY VIEW combined_cgm_tracing AS (SELECT NULL AS Date_Time, NULL AS CGM_Value, NULL AS tenant_id, NULL AS participant_id, NULL AS file_name WHERE 1=0)"
fi

# echo -e "--- Generated CREATE VIEW Query Preview ---\n${UNION_ALL_QUERY:0:150}...\n-----------------------------------------"


# 4b. Execute the generated CREATE VIEW query against $DUCK_DB_FILE (CORRECTED)
echo "4b. Executing the generated CREATE VIEW query against $DUCK_DB_FILE..."

# 1. Create a script to ATTACH the SQLite DB and then run the VIEW creation SQL.
# This is necessary because the CREATE VIEW statement references tables in the SQLite DB
# using the alias 'sqlite_db_alias'.
echo "
ATTACH '${SQLITE_DB_FILE}' AS sqlite_db_alias;
-- It's often good practice to set the search path in case of unqualified table names
SET search_path = 'main,sqlite_db_alias';
-- Execute the generated 'CREATE VIEW combined_cgm_tracing' statement
.read ${GENERATED_VIEW_SQL_FILE}
" > "$EXECUTE_UNION_SQL_FILE"

# 2. Execute the master script against the DuckDB file
duckdb "$DUCK_DB_FILE" --batch < "$EXECUTE_UNION_SQL_FILE"

if [ $? -ne 0 ]; then
    echo "ERROR: DuckDB failed to execute the generated combined_cgm_tracing view SQL (4c)."
    exit 1
fi
echo "View 'combined_cgm_tracing' created successfully."

echo -e "\n4c. Exporting 'combined_cgm_tracing' data to table in $SQLITE_DB_FILE as 'combined_cgm_tracing_cached'..."

# Execute the ATTACH and CREATE TABLE AS SELECT commands in DuckDB.
duckdb "$DUCK_DB_FILE" -c "
  -- FIX: Use the alias 'sqlite_db_alias' that the view definition expects.
  ATTACH '${SQLITE_DB_FILE}' AS sqlite_db_alias; 
  
  -- 1. DROP the table if it already exists in the ATTACHED SQLite DB
  DROP TABLE IF EXISTS sqlite_db_alias.combined_cgm_tracing_cached;
  
  -- 2. Create a new table in the SQLite database with the same name as the view.
  -- The view successfully executes because the alias 'sqlite_db_alias' is available.
  CREATE TABLE sqlite_db_alias.combined_cgm_tracing_cached AS 
  SELECT * FROM combined_cgm_tracing;
"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to export view data to SQLite database (4d)."
    exit 1
fi

echo "Data successfully exported and materialized into view and a cached table in $SQLITE_DB_FILE."

# --- STEP 4d: Executing the DRH Metrics SQL ---
echo -e "\n4d. Executing the DRH Metrics SQL (${COMMON_SQL_PATH}/drh-metrics.sql) against $SQLITE_DB_FILE..."
# FIX: Use the direct sqlite3 execution method
sqlite3 "$SQLITE_DB_FILE" < "${COMMON_SQL_PATH}/drh-metrics.sql"
if [ $? -ne 0 ]; then
 echo "ERROR: sqlite3 failed during drh-metrics.sql execution."
 exit 1
fi
echo "DRH metrics execution complete."

# --- STEP 4e: Executing the Metrics Explanation SQL ---
echo -e "\n4e. Executing the Metrics Explanation SQL (${COMMON_SQL_PATH}/metrics-explanation-dml.sql) against $SQLITE_DB_FILE..."
# FIX: Use the direct sqlite3 execution method
sqlite3 "$SQLITE_DB_FILE" < "${COMMON_SQL_PATH}/metrics-explanation-dml.sql"
if [ $? -ne 0 ]; then
 echo "ERROR: sqlite3 failed during metrics-explanation-dml.sql execution."
 exit 1
fi
echo "DRH metrics explanation execution complete."


# ----------------------------------------------------------------------------------
# --- STEP 5A: DDL AND QUERY GENERATION ---
# ----------------------------------------------------------------------------------
echo -e "\n5a. Creating 'file_meta_ingest_data' table and generating INSERT query..."

# 1. Substitute placeholders into the generator script
GENERATOR_JSON_SQL_CONTENT=$(cat "$JSON_GENERATOR_SQL")

# Perform substitutions (Ensure ALL are present and correct)
GENERATOR_JSON_SQL_CONTENT=$(echo "$GENERATOR_JSON_SQL_CONTENT" | sed "s|__SQLITE_DB_PATH__|${SQLITE_DB_FILE}|g")
GENERATOR_JSON_SQL_CONTENT=$(echo "$GENERATOR_JSON_SQL_CONTENT" | sed "s|__DB_FILE_ID__|${DB_FILE_ID}|g") 
GENERATOR_JSON_SQL_CONTENT=$(echo "$GENERATOR_JSON_SQL_CONTENT" | sed "s|__TENANT_ID__|${TENANT_ID}|g") 
GENERATOR_JSON_SQL_CONTENT=$(echo "$GENERATOR_JSON_SQL_CONTENT" | sed "s|__TENANT_NAME__|${TENANT_NAME}|g") 
GENERATOR_JSON_SQL_CONTENT=$(echo "$GENERATOR_JSON_SQL_CONTENT" | sed "s|__TEMP_GENERATED_INSERT_SQL_PATH__|${GENERATED_INSERT_SQL_FILE}|g")

# 2. Write the substituted SQL to a temporary executable file
echo "$GENERATOR_JSON_SQL_CONTENT" > "$EXECUTABLE_GENERATOR_SQL"

# 3. Execute the generator. This creates the DDL table and WRITES the final query.
duckdb "$DUCK_DB_FILE" -c ".read $EXECUTABLE_GENERATOR_SQL" --batch

if [ $? -ne 0 ]; then
    echo "ERROR: DuckDB failed during DDL or query emission (5a)."
    exit 1
fi
echo "Table created. INSERT query generated successfully."

# ----------------------------------------------------------------------------------
# --- STEP 5B: EXECUTE DATA INSERTION (with Emptiness Check and JSON fix) ---
# ----------------------------------------------------------------------------------
echo -e "\n5b. Inserting data into 'file_meta_ingest_data'..."

# CRITICAL CHECK: Verify the generated SQL file is not empty before proceeding.
if [ ! -s "${GENERATED_INSERT_SQL_FILE}" ]; then
# ... (Lines 318-333 remain unchanged - the warning and debug check are correct) ...
    exit 1
fi
# File is not empty, proceed with execution.

EXECUTE_INSERT_SQL="${TEMP_DIR}/02-execute-insert.sql"

# Create the execution wrapper script
echo "
-- The INSTALL/LOAD json commands are REMOVED from this script
-- to prevent the intermittent scope error. They are now in the -c flag.

-- Attach SQLite to allow the generated subqueries (for cgm_data) to work
ATTACH '${SQLITE_DB_FILE}' AS sqlite_db_alias; 

-- Execute the generated INSERT INTO statement
.read ${GENERATED_INSERT_SQL_FILE}
" > "$EXECUTE_INSERT_SQL"

# Execute the insertion script against the main DuckDB file
# FIX: Inject the INSTALL/LOAD commands via the -c flag for guaranteed loading scope.
duckdb "$DUCK_DB_FILE" -c "INSTALL json; LOAD json;" --batch < "$EXECUTE_INSERT_SQL"

if [ $? -ne 0 ]; then
 echo "ERROR: DuckDB failed to execute the JSON INSERT SQL (5b). Check generated query syntax."
 exit 1
fi
echo "Data ingestion successful."

# 5c . Export the final table
echo -e "5c. Exporting final table to $SQLITE_DB_FILE..."

# Execute the ATTACH and CREATE TABLE AS SELECT commands in DuckDB.
duckdb "$DUCK_DB_FILE" -c "
  -- Use the alias 'sqlite_db_alias' for consistency
  ATTACH '${SQLITE_DB_FILE}' AS sqlite_db_alias; 
  
  -- Export the file_meta_ingest_data table
  DROP TABLE IF EXISTS sqlite_db_alias.file_meta_ingest_data;
  CREATE TABLE sqlite_db_alias.file_meta_ingest_data AS 
  SELECT * FROM file_meta_ingest_data;
"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to export final table to SQLite database (5c)."
    exit 1
fi
echo "file_meta_ingest_data successfully exported to $SQLITE_DB_FILE."

# ----------------------------------------------------------------------------------
# --- Starting Database Copy/Rename and Cleanup  ---
# ----------------------------------------------------------------------------------

echo -e "\n--- Starting Database Copy/Rename and Cleanup ---"

rm -f "$DUCK_DB_FILE"

# 1. Validation Check: Ensure the generated staging file exists
if [[ ! -f "$SQLITE_DB_FILE" ]]; then
    echo "ERROR: Staging database file '$SQLITE_DB_FILE' not found after ETL. Exiting."
    exit 1 
fi

# 2. Check if the **FINAL** database file already exists and delete it
# This deletes the previous run's database to ensure the new one is used.
if [[ -f "$FINAL_DB_NAME" ]]; then
    echo "Previous run's final database '$FINAL_DB_NAME' found. Deleting it."
    rm -f "$FINAL_DB_NAME"
    echo "Deleted '$FINAL_DB_NAME'."
fi

# 3. Move/Rename the staging file to the final, Sqlpage-required name
echo "Moving/renaming '$SQLITE_DB_FILE' to '$FINAL_DB_NAME' for Sqlpage."
mv "$SQLITE_DB_FILE" "$FINAL_DB_NAME"

# 4. Check if the move/rename was successful
if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to move database to '$FINAL_DB_NAME'."
    exit 1
fi
echo "Success: Sqlpage-required database '$FINAL_DB_NAME' is ready."

# ------------------------------------------------------------------------------
# Archive Versioning Logic
# ------------------------------------------------------------------------------

# 5. Find the latest version number
# Search for files matching the new pattern: DRh.<STUDY_NAME>.V*.sqlite.db
LATEST_VERSION=$(ls -1 "${ARCHIVE_DIR}/${ARCHIVE_BASE_NAME}.v"*.sqlite.db 2>/dev/null | \
                 grep -oE "V[0-9]+" | \
                 sed 's/V//' | \
                 sort -nr | \
                 head -n 1 || echo 0)

# 6. Calculate the new version number
NEW_VERSION=$((LATEST_VERSION + 1))

# 7. Format the new version number with leading zeros (e.g., V001, V010)
VERSION_SUFFIX=$(printf "v%03d" "$NEW_VERSION")
# Construct the new archive filename using the updated base name
NEW_ARCHIVE_FILE="${ARCHIVE_BASE_NAME}.${VERSION_SUFFIX}.sqlite.db"

# 8. Copy the FINAL database to the new unique archive name
echo "Current latest archive version found: v$(printf "%03d" "$LATEST_VERSION")."
echo "Archiving new database as version: $VERSION_SUFFIX."
echo "Copying '$FINAL_DB_NAME' to '${ARCHIVE_DIR}/$NEW_ARCHIVE_FILE'."
cp "$FINAL_DB_NAME" "${ARCHIVE_DIR}/$NEW_ARCHIVE_FILE"

# 9. Check if the copy was successful
if [[ $? -eq 0 ]]; then
    echo "Success: Database copied to archive '$NEW_ARCHIVE_FILE'."
else
    echo "WARNING: Failed to copy database to archive. Sqlpage file is still present."
fi

echo "--- Database operation complete ---"