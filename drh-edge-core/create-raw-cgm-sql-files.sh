#!/bin/bash

# --- Configuration ---
DB_FILE="DRH.studydata.sqlite.db"      # Your SQLite database file
TEMP_OUTPUT="temp_extracted_data.txt"  # Temporary file to store the path and content output

# The prefix to add to the path when creating the physical file on disk
OUTPUT_PREFIX="dev-src.auto/"

# The field separator (0x1F) and record separator (0x1E) are used to safely delimit path and content.
FIELD_SEPARATOR=$'\x1F'
RECORD_SEPARATOR=$'\x1E'

# --- 1. Execution and Data Retrieval ---

echo "Executing SQL query against '$DB_FILE' to retrieve internal file data..."

# Use a Here Document (<<EOF) to pass the commands to sqlite3 correctly.
# The dot commands are on their own lines, followed by the standard SQL.
sqlite3 "$DB_FILE" <<EOF > "$TEMP_OUTPUT"
.mode list  
.separator '${FIELD_SEPARATOR}' '${RECORD_SEPARATOR}'
SELECT
    path,
    contents
FROM
    sqlpage_files
WHERE
    path LIKE 'drh/cgm-data/raw-cgm/%';
EOF

# Check the exit status of the sqlite3 command
if [ $? -ne 0 ]; then
    echo "Error: Failed to execute SQL query against $DB_FILE. Check the query syntax or DB file path."
    rm -f "$TEMP_OUTPUT" 2>/dev/null
    exit 1
fi

# --- 2. File Creation on Disk (with Prefixing) ---

echo "Writing extracted .sql files to disk in ${OUTPUT_PREFIX}..."

# Read the temporary file, splitting records by RECORD_SEPARATOR (0x1E) and fields by FIELD_SEPARATOR (0x1F)
while IFS="${FIELD_SEPARATOR}" read -r -d "${RECORD_SEPARATOR}" DB_PATH FILE_CONTENT; do
    
    # Construct the final physical file path by adding the prefix
    PHYSICAL_PATH="${OUTPUT_PREFIX}${DB_PATH}"
    
    # Create the necessary directory structure
    DIR_PATH=$(dirname "$PHYSICAL_PATH")
    mkdir -p "$DIR_PATH"
    
    # Ensure path and content are valid before writing
    # Inside the while loop of your extraction script:

   if [ -n "$DB_PATH" ] && [ -n "$FILE_CONTENT" ]; then
       
       CLEAN_PATH=$(echo "$PHYSICAL_PATH" | tr -d '\r')
       
       # 🌟 FIX: Use 'sed' to strip leading and trailing whitespace/newlines
       # The sed command removes spaces, tabs, carriage returns, and newlines
       TRIMMED_CONTENT=$(echo "$FILE_CONTENT" | sed 's/^[ \t\r\n]*//;s/[ \t\r\n]*$//')
       
       # Write the trimmed content
       echo -e "$TRIMMED_CONTENT" > "$CLEAN_PATH"
       echo "Extracted and Created: $CLEAN_PATH"
   fi

done < "$TEMP_OUTPUT"

# --- 3. Cleanup ---
rm "$TEMP_OUTPUT"
echo "Extraction complete. Files synchronized from sqlpage_files to disk."