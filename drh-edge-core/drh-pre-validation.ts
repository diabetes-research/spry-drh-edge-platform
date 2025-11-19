#!/usr/bin/env -S deno run --allow-read --allow-write --allow-env --allow-run --allow-net --allow-ffi

import { $ } from "https://deno.land/x/dax@0.33.0/mod.ts";
import { existsSync } from "https://deno.land/std/fs/mod.ts";
import * as colors from "https://deno.land/std@0.224.0/fmt/colors.ts";
import { ensureDir } from "https://deno.land/std@0.201.0/fs/mod.ts";
import { parse } from "https://deno.land/std/csv/mod.ts"; // CORRECTED: Using Deno's CSV parser for metadata validation

// Constants
const requiredExtension = ".csv";
const cgmMetadataFileName = "cgm_file_metadata.csv";

// --- Schema Definitions for Validation ---

type ColumnSchema = {
  name: string;
  required: boolean;
};

type FileSchema = {
  fileName: string; // Base name for single files, or pattern for multiple
  required: boolean;
  multiple: boolean;
  columns: ColumnSchema[];
};

const schemas: Record<string, FileSchema> = {
  // Required Files
  "cgm_file_metadata": {
    fileName: "cgm_file_metadata.csv",
    required: true,
    multiple: false,
    columns: [
      { name: "metadata_id", required: true },
      { name: "devicename", required: false },
      { name: "device_id", required: false },
      { name: "source_platform", required: false },
      { name: "patient_id", required: true },
      { name: "file_name", required: true }, // Required and checked for emptiness
      { name: "file_format", required: false },
      { name: "file_upload_date", required: false },
      { name: "data_start_date", required: false },
      { name: "data_end_date", required: false },
      { name: "map_field_of_cgm_date", required: true }, // Required and checked for emptiness
      { name: "map_field_of_cgm_value", required: true }, // Required and checked for emptiness
      { name: "study_id", required: true },
    ],
  },
  "participant": {
    fileName: "participant.csv",
    required: true,
    multiple: false,
    columns: [
      { name: "participant_id", required: true },
      { name: "study_id", required: true },
      { name: "site_id", required: false },
      { name: "diagnosis_icd", required: false },
      { name: "med_rxnorm", required: false },
      { name: "treatment_modality", required: false },
      { name: "gender", required: false },
      { name: "race_ethnicity", required: false },
      { name: "age", required: false },
      { name: "bmi", required: false },
      { name: "baseline_hba1c", required: false },
      { name: "diabetes_type", required: false },
      { name: "study_arm", required: false },
    ],
  },
  // Recommended Files
  "site": {
    fileName: "site.csv",
    required: false,
    multiple: false,
    columns: [
      { name: "study_id", required: true },
      { name: "site_id", required: true },
      { name: "site_name", required: false },
      { name: "site_type", required: false },
    ],
  },
  "study": {
    fileName: "study.csv",
    required: false,
    multiple: false,
    columns: [
      { name: "study_id", required: true },
      { name: "study_name", required: false },
      { name: "start_date", required: false },
      { name: "end_date", required: false },
      { name: "treatment_modalities", required: false },
      { name: "funding_source", required: false },
      { name: "nct_number", required: false },
      { name: "study_description", required: false },
    ],
  },
  "investigator": {
    fileName: "investigator.csv",
    required: false,
    multiple: false,
    columns: [
      { name: "investigator_id", required: true },
      { name: "investigator_name", required: false },
      { name: "email", required: false },
      { name: "institution_id", required: false },
      { name: "study_id", required: true },
    ],
  },
  // Optional Metadata Files
  "meal_file_metadata": {
    fileName: "meal_file_metadata.csv",
    required: false,
    multiple: false,
    columns: [
      { name: "meal_meta_id", required: true },
      { name: "participant_id", required: true },
      { name: "file_name", required: true },
      { name: "source", required: false },
      { name: "file_format", required: false },
    ],
  },
  "fitness_file_metadata": {
    fileName: "fitness_file_metadata.csv",
    required: false,
    multiple: false,
    columns: [
      { name: "fitness_meta_id", required: true },
      { name: "participant_id", required: true },
      { name: "file_name", required: true },
      { name: "source", required: false },
      { name: "file_format", required: false },
    ],
  },
  // Other Optional Files (Only existence and schema validation)
  "institution": {
    fileName: "institution.csv",
    required: false,
    multiple: false,
    columns: [
      { name: "institution_id", required: true },
      { name: "institution_name", required: false },
      { name: "city", required: false },
      { name: "state", required: false },
      { name: "country", required: false },
    ],
  },
  "lab": {
    fileName: "lab.csv",
    required: false,
    multiple: false,
    columns: [
      { name: "lab_id", required: true },
      { name: "lab_name", required: false },
      { name: "lab_pi", required: false },
      { name: "institution_id", required: false },
      { name: "study_id", required: false },
    ],
  },
  "author": {
    fileName: "author.csv",
    required: false,
    multiple: false,
    columns: [
      { name: "author_id", required: true },
      { name: "name", required: false },
      { name: "email", required: false },
      { name: "investigator_id", required: false },
      { name: "study_id", required: false },
    ],
  },
  "publication": {
    fileName: "publication.csv",
    required: false,
    multiple: false,
    columns: [
      { name: "publication_id", required: true },
      { name: "publication_title", required: false },
      { name: "digital_object_identifier", required: false },
      { name: "publication_site", required: false },
      { name: "study_id", required: false },
    ],
  },
};

// --- Helper Functions ---

/** Reads the first line of a CSV file to get headers. */
async function getFileHeaders(filePath: string): Promise<string[]> {
  try {
    const content = await Deno.readTextFile(filePath);
    const firstLine = content.split("\n")[0];
    if (!firstLine) return [];
    // Assuming comma delimiter and trimming quotes/whitespace
    return firstLine.split(",").map((h) =>
      h.trim().replace(/^['"]|['"]$/g, "")
    );
  } catch (e) {
    throw new Error(`Failed to read headers from ${filePath}: ${e.message}`);
  }
}

/** Reads the content of a CSV file. */
async function getFileContent(filePath: string): Promise<string[]> {
  try {
    const content = await Deno.readTextFile(filePath);
    // Split by line, remove header (first line), and trim to get data lines
    const lines = content.trim().split("\n").slice(1).map((line) => line.trim())
      .filter((line) => line.length > 0);
    return lines;
  } catch (e) {
    throw new Error(`Failed to read content from ${filePath}: ${e.message}`);
  }
}

class Validator {
  /**
   * 1. Check folder name for spaces.
   */
  static checkFolderName(dirPath: string): void {
    dirPath = dirPath.trim();
    console.log(colors.cyan(`Checking folder name: ${dirPath}`));
    if (/\s/.test(dirPath)) {
      console.error(
        colors.red(
          `Error : The specified path "${dirPath}" should not contain spaces.`,
        ),
      );
      Deno.exit(1);
    }
    console.log(colors.green("✅ Folder name check passed."));
  }

  /**
   * 2. Check for subfolders or files other than .csv.
   * 3. List all files and check against required structure (Part 1/3).
   * 4. Check if all required files are present (Part 1/2).
   * @param dirPath - Path to the directory.
   * @returns A list of only valid CSV file names.
   */
  static async validateFolderContentsAndList(
    dirPath: string,
  ): Promise<string[]> {
    console.log(colors.cyan("Checking for subfolders/invalid files ."));
    console.log(colors.cyan("Checking file presence and listing valid files."));

    if (!existsSync(dirPath)) {
      console.error(
        colors.red(`Error: The specified folder "${dirPath}" does not exist.`),
      );
      Deno.exit(1);
    }

    const fileNames: string[] = [];

    for await (const entry of Deno.readDir(dirPath)) {
      if (entry.isDirectory) {
        // Req 2: Subfolders
        console.error(
          colors.red(
            `Error: Subfolder found: ${entry.name}. Only csv files are allowed.`,
          ),
        );
        Deno.exit(1);
      }

      if (entry.isFile) {
        const fileExtension = `.${entry.name.split(".").pop()?.toLowerCase()}`;

        // Req 2: Invalid extensions
        if (fileExtension !== requiredExtension) {
          console.error(
            colors.red(
              `Error : Invalid file found: ${entry.name}. Only ${requiredExtension} files are allowed.`,
            ),
          );
          Deno.exit(1);
        }

        fileNames.push(entry.name);
      }
    }

    if (fileNames.length === 0) {
      console.log(colors.yellow("No files found in the directory."));
      Deno.exit(1);
    }

    // Log folder contents
    console.log(colors.cyan(`Folder contents (${fileNames.length} files):`));
    fileNames.forEach((file) => console.log(colors.green(`File: ${file}`)));

    // Check all required files
    const requiredFiles = Object.values(schemas).filter((s) =>
      s.required && !s.multiple
    ).map((s) => s.fileName);
    for (const requiredFile of requiredFiles) {
      if (!fileNames.includes(requiredFile)) {
        console.error(
          colors.red(`Error : Required file "${requiredFile}" is missing.`),
        );
        Deno.exit(1);
      }
    }

    console.log(
      colors.green(
        "✅ Folder contents and required file existence check passed.",
      ),
    );
    return fileNames;
  }

  /**
   * 3 & 5. Schema validation (Header check for all files).
   * @param allFileNames - List of all files in the folder.
   * @param cgmRawBaseNames - The list of actual CGM raw file BASE names to check (Req 7).
   */
  static async validateFileSchemas(
    dirPath: string,
    allFileNames: string[],
    cgmRawBaseNames: string[],
  ): Promise<void> {
    console.log(
      colors.cyan("Performing schema (header) validation on all files."),
    );

    // Step 1: Validate fixed-name files (Required, Recommended, Optional Metadata)
    for (const schema of Object.values(schemas)) {
      if (allFileNames.includes(schema.fileName)) {
        await Validator.validateSingleFileSchema(
          dirPath,
          schema.fileName,
          schema,
        );
      }
    }

    // Step 2: Validate the ACTUAL CGM raw files
    const uniqueCgmRawBaseNames = [...new Set(cgmRawBaseNames)];
    for (const baseFileName of uniqueCgmRawBaseNames) {
      // Construct the full file name including the mandatory extension for checking
      const fullFileName = baseFileName.endsWith(requiredExtension)
        ? baseFileName
        : baseFileName + requiredExtension;

      const filePath = `${dirPath}/${fullFileName}`;

      // Ensure the file exists (redundant if Req 7 passes, but safe)
      if (!allFileNames.includes(fullFileName)) continue;

      // Since we already ensured existence, now we check content (Req 5)
      const headers = await getFileHeaders(filePath);
      // Req 5: cgm_tracing columns can differ, check only for non-empty headers
      if (headers.length === 0) {
        console.error(
          colors.red(
            `Error: CGM raw file "${fullFileName}" is empty or has no headers.`,
          ),
        );
        Deno.exit(1);
      }
      console.log(
        colors.green(
          ` Schema check passed for CGM raw file: ${fullFileName} (Columns differ for cgm_tracing).`,
        ),
      );
    }

    console.log(colors.green("✅ All file schema validations passed."));
  }

  /**
   * Helper for schema validation of a single file.
   */
  private static async validateSingleFileSchema(
    dirPath: string,
    fileName: string,
    schema: FileSchema,
  ): Promise<void> {
    const filePath = `${dirPath}/${fileName}`;
    const actualHeaders = await getFileHeaders(filePath);
    const missingHeaders: string[] = [];

    for (const col of schema.columns) {
      if (col.required && !actualHeaders.includes(col.name)) {
        missingHeaders.push(col.name);
      }
    }

    if (missingHeaders.length > 0) {
      console.error(
        colors.red(
          `Error : File "${fileName}" is missing required column(s): ${
            missingHeaders.join(", ")
          }`,
        ),
      );
      Deno.exit(1);
    }
    console.log(colors.green(`   - Schema check passed for ${fileName}.`));
  }

  /**
   * 6. Check file_name column in cgm_file_metadata.csv for emptiness.
   * @returns List of CGM raw file names found in the metadata (BASE NAME, without extension).
   */
  static async validateCgmMetadataFilenames(
    dirPath: string,
  ): Promise<string[]> {
    console.log(
      colors.cyan("Validating 'file_name' column in cgm_file_metadata."),
    );
    const metadataPath = `${dirPath}/${cgmMetadataFileName}`;
    const metadataContent = await getFileContent(metadataPath);

    if (metadataContent.length === 0) {
      console.error(
        colors.red(
          "Error: cgm_file_metadata.csv has no data rows. Must contain at least one row linking a CGM file.",
        ),
      );
      Deno.exit(1);
    }

    const headers = await getFileHeaders(metadataPath);
    const fileNameIndex = headers.indexOf("file_name");

    if (fileNameIndex === -1) {
      console.error(
        colors.red(
          "Internal Error: 'file_name' column not found in cgm_file_metadata (Schema validation failed).",
        ),
      );
      Deno.exit(1);
    }

    const cgmRawBaseNames: string[] = []; // Array to hold base names
    let lineNum = 1; // Start after header
    for (const line of metadataContent) {
      lineNum++;
      const columns = line.split(",").map((c) =>
        c.trim().replace(/^['"]|['"]$/g, "")
      );
      const fileName = columns[fileNameIndex];

      if (!fileName || fileName.length === 0) {
        console.error(
          colors.red(
            `Error: 'file_name' is empty in ${cgmMetadataFileName} at line ${lineNum}.`,
          ),
        );
        Deno.exit(1);
      }
      // Store the base name from the column
      cgmRawBaseNames.push(fileName);
    }

    console.log(
      colors.green(
        "✅ 'file_name' column in cgm_file_metadata.csv is not empty.",
      ),
    );
    return cgmRawBaseNames;
  }

  /**
   * 7. Check if cgm raw files (from metadata) are present in folder.
   * @param cgmRawBaseNames - List of CGM file base names from cgm_file_metadata.
   * @param allFileNames - List of all files (with extensions) in the folder.
   */
  static checkCgmRawFilePresence(
    cgmRawBaseNames: string[],
    allFileNames: string[],
  ): void {
    console.log(
      colors.cyan("Checking if CGM raw files listed in metadata are present."),
    );
    const uniqueRawBaseNames = [...new Set(cgmRawBaseNames)];

    for (const baseFileName of uniqueRawBaseNames) {
      // Construct the full file name, assuming .csv is mandatory (Req 2)
      const fullFileName = baseFileName.endsWith(requiredExtension)
        ? baseFileName
        : baseFileName + requiredExtension;

      if (!allFileNames.includes(fullFileName)) {
        console.error(
          colors.red(
            `Error: CGM raw file "${fullFileName}" (derived from metadata base name "${baseFileName}" and mandatory extension ${requiredExtension}) is missing from the folder.`,
          ),
        );
        Deno.exit(1);
      }
    }
    console.log(
      colors.green(
        "✅ All CGM raw files listed in metadata are present in the folder.",
      ),
    );
  }

  /**
   * 8. Check mapping fields in cgm_file_metadata for emptiness.
   * @param dirPath - Path to the directory.
   */
  static async validateCgmMetadataMappingFields(
    dirPath: string,
  ): Promise<void> {
    console.log(colors.cyan("Validating mapping fields in cgm_file_metadata."));
    const metadataPath = `${dirPath}/${cgmMetadataFileName}`;
    const metadataContent = await getFileContent(metadataPath);

    // Existence and rows checked in Req 4 and 6, just check content here
    if (metadataContent.length === 0) {
      /* should not happen if Req 6 passed */ return;
    }

    const headers = await getFileHeaders(metadataPath);
    const dateMapIndex = headers.indexOf("map_field_of_cgm_date");
    const valueMapIndex = headers.indexOf("map_field_of_cgm_value");

    // Indices should be valid if schema validation passed
    if (dateMapIndex === -1 || valueMapIndex === -1) Deno.exit(1);

    let lineNum = 1; // Start after header
    for (const line of metadataContent) {
      lineNum++;
      const columns = line.split(",").map((c) =>
        c.trim().replace(/^['"]|['"]$/g, "")
      );
      const dateMap = columns[dateMapIndex];
      const valueMap = columns[valueMapIndex];

      if (!dateMap || dateMap.length === 0) {
        console.error(
          colors.red(
            `Error : 'map_field_of_cgm_date' is empty in ${cgmMetadataFileName} at line ${lineNum}.`,
          ),
        );
        Deno.exit(1);
      }
      if (!valueMap || valueMap.length === 0) {
        console.error(
          colors.red(
            `Error : 'map_field_of_cgm_value' is empty in ${cgmMetadataFileName} at line ${lineNum}.`,
          ),
        );
        Deno.exit(1);
      }
    }

    console.log(
      colors.green(
        "✅ All mapping fields in cgm_file_metadata.csv are not empty.",
      ),
    );
  }


/**
 * Reads a metadata CSV, ensures all required columns are non-empty, and extracts the list
 * of dependent files from the 'file_name' column using a robust parsing method.
 * **This function is used by both meal and fitness validation logic.**
 */
static async _validateAndExtractMetadata(
    folderName: string,
    metadataFileName: string,
): Promise<string[]> {
    const fullPath = `${folderName}/${metadataFileName}`;
    let records: Record<string, string>[] = [];

    // 1. Get and validate headers robustly (trimmed by getFileHeaders)
    const headers = await getFileHeaders(fullPath);
    const expectedHeader = "file_name";

    // Safety check for the critical header
    if (!headers.includes(expectedHeader)) {
        console.error(
            colors.red(
                `Error in '${metadataFileName}': Required column '${expectedHeader}' is missing from the headers: [${headers.join(', ')}]`,
            ),
        );
        Deno.exit(1);
    }
    
    // 2. Read content and parse data using the validated and trimmed headers
    try {
        const csvContent = await Deno.readTextFile(fullPath);
        
        // Use Deno's std/csv utility. Explicitly setting headers and skipping the first row.
        records = parse(csvContent, { 
            skipFirstRow: true, // Skip the header row we already read/validated
            headers: headers, // Use the trimmed headers we retrieved
            separator: ',',
        }) as Record<string, string>[];

    } catch (error) {
        console.error(
            colors.red(`Error reading or parsing metadata file '${metadataFileName}': ${error.message}`),
        );
        Deno.exit(1);
    }
    
    // Check 3: Ensure there is data after parsing
    if (records.length === 0) {
        console.error(
            colors.red(
                `Error in '${metadataFileName}': File is empty or contains only headers. Must contain data rows.`,
            ),
        );
        Deno.exit(1);
    }

    const dependentFileNames: string[] = [];
    
    // Check 4: Non-Empty Columns and Extract Dependent File Names
    records.forEach((row, index) => {
        const rowNumber = index + 2; // 1-based index for data row (1 for header, 1 for index)
        
        for (const key of headers) { // Iterate over the known good headers
            const value = row[key]; // Access using the known good key
            
            // Check if column value is null, undefined, or empty string (after trimming)
            // Note: If the file has a missing column entry (e.g., ,, in CSV), the parser might return "" or undefined.
            if (value === null || value === undefined || String(value).trim().length === 0) {
                // Determine if this column is required based on the schema (meal_file_metadata and fitness_file_metadata)
                const schema = schemas[metadataFileName.replace(".csv", "")];
                const isRequired = schema.columns.some(col => col.name === key && col.required);

                if (isRequired) {
                    console.error(
                        colors.red(
                            `Error in '${metadataFileName}' (Data Row ${rowNumber}): Required column '${key}' cannot be empty.`,
                        ),
                    );
                    Deno.exit(1);
                }
                // NOTE: We only check required columns for emptiness in this step.
            }
        }
        
        // Extract dependent file names
        dependentFileNames.push(row[expectedHeader].trim());
    });

    return dependentFileNames;
}


  /**
   * 9. Conditional existence check for meal/fitness data and metadata.
   * **Focuses solely on the metadata file as the trigger for both meal and fitness.**
   * @param folderName - Path to the directory.
   * @param allFileNames - List of all files in the folder.
   */
  static async validateOptionalFileExistence(folderName: string, allFileNames: string[]): Promise<void> {
    console.log(
      colors.cyan("Conditional check for meal/fitness data and metadata (Metadata-driven)."),
    );

    const mealMetadataFileName = "meal_file_metadata.csv";
    const fitnessMetadataFileName = "fitness_file_metadata.csv";

    const mealMetadataPresent = allFileNames.includes(mealMetadataFileName);
    const fitnessMetadataPresent = allFileNames.includes(
      fitnessMetadataFileName,
    );
    
    // -------------------- MEAL CHECKS --------------------
    
    // Trigger validation only if the MEAL metadata file is present.
    if (mealMetadataPresent) {
      console.log(colors.dim(` -> Validating content of '${mealMetadataFileName}'...`));
      
      // Step 1: Validate metadata content and extract dependent file names
      const dependentMealFiles = await Validator._validateAndExtractMetadata(
        folderName,
        mealMetadataFileName,
      );
      
      const listedDataFileBaseNames = [...new Set(dependentMealFiles.map(f => f.split('/').pop() || f))]; 
      
      if(listedDataFileBaseNames.length === 0){
        console.error(
          colors.red(
            `Error : '${mealMetadataFileName}' is present but contains no data entries (file_name is empty).`,
          ),
        );
        Deno.exit(1);
      }

      // Step 2: Check existence and headers for ALL dependent raw files listed
      for (const listedFileBaseName of listedDataFileBaseNames) {
        // Determine the full file name with the required extension (THIS IS THE FIX)
        const fullFileName = listedFileBaseName.endsWith(requiredExtension)
          ? listedFileBaseName
          : listedFileBaseName + requiredExtension;

        // Check existence in the folder
        if (!allFileNames.includes(fullFileName)) {
          console.error(
            colors.red(
              // Error message now reflects the expected full file name
              `Error : File '${listedFileBaseName}' listed in '${mealMetadataFileName}' is missing from the data folder (expected filename: ${fullFileName}).`,
            ),
          );
          Deno.exit(1);
        }

        // Check if the dependent raw file has headers (non-empty)
        const filePath = `${folderName}/${fullFileName}`;
        const headers = await getFileHeaders(filePath);
        if (headers.length === 0) {
          console.error(
            colors.red(
              `Error: Dependent meal data file "${fullFileName}" (listed in metadata) is empty or has no headers.`,
            ),
          );
          Deno.exit(1);
        }
      }
      console.log(colors.dim(` -> All dependent meal files found and are not empty.`)); 
    }
    
    // -------------------- FITNESS CHECKS --------------------
    
    // Trigger validation only if the FITNESS metadata file is present.
    if (fitnessMetadataPresent) {
      console.log(colors.dim(` -> Validating content of '${fitnessMetadataFileName}'...`));
      
      // Step 1: Validate metadata content and extract dependent file names
      const dependentFitnessFiles = await Validator._validateAndExtractMetadata(
        folderName,
        fitnessMetadataFileName,
      );
      
      const listedDataFileBaseNames = [...new Set(dependentFitnessFiles.map(f => f.split('/').pop() || f))]; 

      if(listedDataFileBaseNames.length === 0){
        console.error(
          colors.red(
            `Error : '${fitnessMetadataFileName}' is present but contains no data entries (file_name is empty).`,
          ),
        );
        Deno.exit(1);
      }
      
      // Step 2: Check existence and headers for ALL dependent raw files listed
      for (const listedFileBaseName of listedDataFileBaseNames) {
        // Determine the full file name with the required extension (THIS IS THE FIX)
        const fullFileName = listedFileBaseName.endsWith(requiredExtension)
          ? listedFileBaseName
          : listedFileBaseName + requiredExtension;

        // Check existence in the folder
        if (!allFileNames.includes(fullFileName)) {
          console.error(
            colors.red(
              // Error message now reflects the expected full file name
              `Error : File '${listedFileBaseName}' listed in '${fitnessMetadataFileName}' is missing from the data folder (expected filename: ${fullFileName}).`,
            ),
          );
          Deno.exit(1);
        }

        // Check if the dependent raw file has headers (non-empty)
        const filePath = `${folderName}/${fullFileName}`;
        const headers = await getFileHeaders(filePath);
        if (headers.length === 0) {
          console.error(
            colors.red(
              `Error: Dependent fitness data file "${fullFileName}" (listed in metadata) is empty or has no headers.`,
            ),
          );
          Deno.exit(1);
        }
      }
      console.log(colors.dim(` -> All dependent fitness files found and are not empty.`)); 
    }
    
    console.log(
      colors.green("✅ Optional file existence, dependency, and content integrity check passed."),
    );
  }
}


// Helper functions for performance timing
function timeStart(label: string): number {
  console.log(colors.dim(`\nStarting ${label}...`));
  return performance.now();
}

function timeEnd(label: string, startTime: number): void {
  const durationMs = performance.now() - startTime;
  const durationSeconds = (durationMs / 1000).toFixed(2);
  console.log(
    colors.yellow(
      ` ${label} completed in ${durationSeconds} seconds.`,
    ),
  );
}

class App {
    private folderName: string;
    private tenantId: string | undefined;
    private tenantName: string | undefined;

    constructor(folderName: string, tenantId?: string, tenantName?: string) {
        this.folderName = folderName;
        this.tenantId = tenantId;
        this.tenantName = tenantName;
        if (tenantId) console.log(colors.dim(`Tenant ID received: ${tenantId}`));
        if (tenantName) {
            console.log(colors.dim(`Tenant Name received: ${tenantName}`));
        }
    }

    /**
     * Executes all the pre-validation checks and exits on first failure.
     * This function is intended to be called from the main block to act as a gate.
     */
    async runValidationGate() {
        let startTime: number;

        console.log(colors.yellow("Starting Data Folder Validation Process..."));
        try {
            startTime = timeStart("Data Validation");

            // 1. Structure: Check folder name for spaces
            Validator.checkFolderName(this.folderName);

            // 2, 4. Structure/Completeness: Check contents, list files, and check fixed REQUIRED file existence
            const allFileNames = await Validator.validateFolderContentsAndList(
                this.folderName,
            );

            // 6. Metadata: Validate file_name column in cgm_file_metadata and extract CGM raw file BASE names
            const cgmRawBaseNames = await Validator.validateCgmMetadataFilenames(
                this.folderName,
            );

            // 7. Completeness: Check if all CGM raw files are present
            Validator.checkCgmRawFilePresence(cgmRawBaseNames, allFileNames);

            // 3, 5. Metadata/Completeness: Schema validation (Headers)
            await Validator.validateFileSchemas(
                this.folderName,
                allFileNames,
                cgmRawBaseNames,
            );

            // 8. Metadata: Validate mapping fields in cgm_file_metadata
            await Validator.validateCgmMetadataMappingFields(this.folderName);

            // 9. Dependencies: Conditional existence, content, and file presence check for meal/fitness
            await Validator.validateOptionalFileExistence(this.folderName, allFileNames);

            timeEnd("Data Validation", startTime);
            console.log(
                colors.green("✅ All Data Pre-Validation Passed. Proceeding to Ingestion/ETL."),
            );
            // Successful exit (exit code 0) allows the Bash script to proceed.
            // No need for explicit Deno.exit(0) as it's the default.

        } catch (error) {
            // Validation functions within the Validator class already call Deno.exit(1) on critical failure.
            // If control reaches here due to an unexpected error, log and exit.
            console.error(
                colors.red(
                    `CRITICAL VALIDATION FAILURE: ${
                        error instanceof Error ? error.message : String(error)
                    }`,
                ),
            );
            Deno.exit(1); // Ensure non-zero exit code for Bash to catch.
        }
    }
}

// Main Execution Block
if (import.meta.main) {
    const args = Deno.args;

    if (args.length === 0) {
        console.error(
            colors.red("No folder name provided. Please provide a folder name."),
        );
        console.error(
            colors.yellow(
                "Usage: deno run drhctl.ts <folderName> [tenantId] [tenantName]",
            ),
        );
        Deno.exit(1);
    }

    const folderName = args[0];
    const tenantId = args[1];
    const tenantName = args[2];

    // Run the application with the provided arguments
    const app = new App(folderName, tenantId, tenantName);
    
    // Call the validation function only.
    await app.runValidationGate();
}