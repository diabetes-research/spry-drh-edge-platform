#!/usr/bin/env -S deno run --allow-all

import { build$, CommandBuilder } from "https://deno.land/x/dax@0.33.0/mod.ts";
import { ensureDir, existsSync } from "https://deno.land/std@0.201.0/fs/mod.ts";
import * as colors from "https://deno.land/std@0.224.0/fmt/colors.ts";
import { parse } from "https://deno.land/std/csv/mod.ts";


// GLOBAL SETUP & DAX
const $ = build$({ commandBuilder: new CommandBuilder().noThrow() });

// DOCTOR TYPES (Copied from doctor.ts for consistency) 

export type ReportResult = {
  readonly ok: string;
} | {
  readonly warn: string;
} | {
  readonly suggest: string;
};

export interface DoctorReporter {
  (
    args: ReportResult | {
      test: () => ReportResult | Promise<ReportResult>;
    },
  ): Promise<void>;
}

export interface DoctorDiagnostic {
  readonly diagnose: (report: DoctorReporter) => Promise<void>;
}

export interface DoctorCategory {
  readonly label: string;
  readonly diagnostics: () => Generator<DoctorDiagnostic, void>;
}

export function doctorCategory(
  label: string,
  diagnostics: () => Generator<DoctorDiagnostic, void>,
): DoctorCategory {
  return {
    label,
    diagnostics,
  };
}

/** Function to get Deno version info. */
export function denoDoctor(): DoctorCategory {
  return doctorCategory("Deno Runtime", function* () {
    const deno: DoctorDiagnostic = {
      diagnose: async (report: DoctorReporter) => {
        report({ ok: (await $`deno --version`.lines())[0] });
      },
    };
    yield deno;
  });
}


// --- JSON REPORT INTERFACES ---

export interface DiagnosticResult {
  check: string;
  status: "PASS" | "FAIL" | "WARNING";
  details: string;
}
export interface FinalReport {
  timestamp: string;
  folderName: string;
  tenantId: string;
  tenantName: string;
  overallStatus: "PASS" | "FAIL" | "WARNING";
  results: DiagnosticResult[];
}

// --- CONSTANTS AND SCHEMAS (Copied from drh-pre-validation.ts) ---
const requiredExtension = ".csv";
const cgmMetadataFileName = "cgm_file_metadata.csv";
const DUCKDB_VERSION_REQUIRED = "1.4.1";

type ColumnSchema = { name: string; required: boolean; };
type FileSchema = { fileName: string; required: boolean; multiple: boolean; columns: ColumnSchema[]; };

const schemas: Record<string, FileSchema> = {
  // Required Files
  "cgm_file_metadata": { fileName: "cgm_file_metadata.csv", required: true, multiple: false, columns: [
    { name: "metadata_id", required: true }, { name: "patient_id", required: true }, { name: "file_name", required: true }, 
    { name: "map_field_of_cgm_date", required: true }, { name: "map_field_of_cgm_value", required: true }, { name: "study_id", required: true },
    { name: "devicename", required: false }, { name: "device_id", required: false }, { name: "source_platform", required: false },
    { name: "file_format", required: false }, { name: "file_upload_date", required: false }, { name: "data_start_date", required: false }, 
    { name: "data_end_date", required: false }
  ]},
  "participant": { fileName: "participant.csv", required: true, multiple: false, columns: [
    { name: "participant_id", required: true }, { name: "study_id", required: true }, 
    { name: "site_id", required: false }, { name: "diagnosis_icd", required: false }, 
    { name: "med_rxnorm", required: false }, { name: "treatment_modality", required: false },
    { name: "gender", required: false }, { name: "race_ethnicity", required: false }, 
    { name: "age", required: false }, { name: "bmi", required: false }, 
    { name: "baseline_hba1c", required: false }, { name: "diabetes_type", required: false }, 
    { name: "study_arm", required: false }
  ]},
  // Recommended/Optional Files
  "site": { fileName: "site.csv", required: false, multiple: false, columns: [{ name: "study_id", required: true }, { name: "site_id", required: true }] },
  "study": { fileName: "study.csv", required: false, multiple: false, columns: [{ name: "study_id", required: true }] },
  "investigator": { fileName: "investigator.csv", required: false, multiple: false, columns: [{ name: "investigator_id", required: true }, { name: "study_id", required: true }] },
  "meal_file_metadata": { fileName: "meal_file_metadata.csv", required: false, multiple: false, columns: [{ name: "meal_meta_id", required: true }, { name: "participant_id", required: true }, { name: "file_name", required: true }] },
  "fitness_file_metadata": { fileName: "fitness_file_metadata.csv", required: false, multiple: false, columns: [{ name: "fitness_meta_id", required: true }, { name: "participant_id", required: true }, { name: "file_name", required: true }] },
  "institution": { fileName: "institution.csv", required: false, multiple: false, columns: [{ name: "institution_id", required: true }] },
  "lab": { fileName: "lab.csv", required: false, multiple: false, columns: [{ name: "lab_id", required: true }] },
  "author": { fileName: "author.csv", required: false, multiple: false, columns: [{ name: "author_id", required: true }] },
  "publication": { fileName: "publication.csv", required: false, multiple: false, columns: [{ name: "publication_id", required: true }] },
};

// --- CORE UTILITIES ---

/** Helper function to convert version strings (e.g., "1.4.1") to a comparable number. */
function versionToNumber(version: string): number {
    const parts = version.replace(/^v/, '').split('.').map(Number);
    return parts[0] * 1000000 + (parts[1] || 0) * 1000 + (parts[2] || 0);
}

/** Reads the first line of a CSV file to get headers. */
async function getFileHeaders(filePath: string): Promise<string[]> {
  try {
    const content = await Deno.readTextFile(filePath);
    const firstLine = content.split("\n")[0];
    if (!firstLine) return [];
    return firstLine.split(",").map((h) =>
      h.trim().replace(/^['"]|['"]$/g, "")
    );
  } catch (e) {
    throw new Error(`Failed to read headers from ${filePath}: ${e.message}`);
  }
}

/** Reads the content of a CSV file (excluding headers). */
async function getFileContent(filePath: string): Promise<string[]> {
  try {
    const content = await Deno.readTextFile(filePath);
    const lines = content.trim().split("\n").slice(1).map((line) => line.trim())
      .filter((line) => line.length > 0);
    return lines;
  } catch (e) {
    throw new Error(`Failed to read content from ${filePath}: ${e.message}`);
  }
}

/** Prints the iconic doctor-style console output (🆗, 💡, 🚫). */
const consoleReport = (options: ReportResult) => {
    if ("ok" in options) {
        console.info(" 🆗", colors.green(options.ok));
    } else if ("suggest" in options) {
        console.info(" 💡", colors.yellow(options.suggest));
    } else {
        console.warn(" 🚫", colors.brightRed(options.warn));
    }
};

// --- DOCTOR DEPENDENCY CHECKS (STEP 1) ---

function getDoctorCategories(): DoctorCategory[] {
    return [
        // 1. Deno Runtime check (User requested this first)
        denoDoctor(), 
        
        // 2. Other Project Dependencies
        doctorCategory("Project Runtime Dependencies", function* () {
            // Surveilr Check
            yield {
                diagnose: async (report) => {
                    if (await $.commandExists("surveilr")) {
                        const versionOutput = await $`surveilr --version`.noThrow().text();
                        return report({ ok: `Surveilr found. Version: ${versionOutput.split('\n')[0].trim()}.` });
                    } else {
                        return report({ warn: "Surveilr not found in PATH, install it" });
                    }
                },
            };
            // DuckDB Check
            yield {
                diagnose: async (report) => {
                    const requiredVersion = DUCKDB_VERSION_REQUIRED;
                    if (await $.commandExists("duckdb")) {
                        const versionOutput = await $`duckdb --version`.noThrow().text();
                        const match = versionOutput.split('\n')[0].trim().match(/v?(\d+\.\d+\.\d+)/); 
                        
                        if (match && versionToNumber(match[1]) >= versionToNumber(requiredVersion)) {
                            return report({ ok: `DuckDB version ${match[1]} installed (meets minimum requirement of ${requiredVersion}).` });
                        } else if (match) {
                            return report({ warn: `DuckDB found, but version is too old: ${match[1]}. Required: ${requiredVersion} or newer.` });
                        } else {
                            return report({ warn: `DuckDB found, but version could not be parsed` });
                        }
                    } else {
                        return report({ warn: `DuckDB not found in PATH, install it` });
                    }
                },
            };
            // SQLite Check
            yield { 
                diagnose: async (report) => {
                    if (await $.commandExists("sqlite3")) {
                        try {
                            const versionOutput = await $`sqlite3 --version`.noThrow().text();
                            const version = versionOutput.split(' ')[0].trim();
                            return report({ ok: `SQLite found. Version: ${version}.` });
                        } catch (e) {
                             return report({ warn: `SQLite found, but version could not be retrieved: ${e.message}` });
                        }
                    } else {
                        return report({ warn: "SQLite not found in PATH, install it" });
                    }
                },
            };
        }),
    ];
}

/** * Executes the dependency checks, printing icons and capturing structured results. */
async function runDoctorChecks(): Promise<void> {
    console.log(colors.cyan("\n--- 1. Running System Dependency Checks ---"));
    
    for (const category of getDoctorCategories()) {
        console.info(colors.dim(`\n${category.label}`)); 

        for (const diagnostic of category.diagnostics()) {
            await diagnostic.diagnose(async (args) => {
                let result: ReportResult;

                if ("test" in args) {
                    try {
                        result = await args.test();
                    } catch (err) {
                        result = { warn: err.toString() };
                    }
                } else {
                    result = args;
                }
                
                // 1. Print the requested iconic console output
                consoleReport(result);

                // 2. Capture the result into the DiagnosticResult structure for the JSON report
                let status: DiagnosticResult["status"];
                let message: string;
                
                if ("ok" in result) {
                    status = "PASS";
                    message = result.ok;
                } else if ("warn" in result) {
                    status = "FAIL"; 
                    message = result.warn;
                } else { // "suggest" in result
                    status = "WARNING"; 
                    message = result.suggest;
                }
                
                const checkName = `[Dependency] ${category.label}`; 
                
                // Update global status
                if (status === "FAIL") {
                    Validator.overallStatus = "FAIL"; 
                } else if (status === "WARNING" && Validator.overallStatus === "PASS") {
                    Validator.overallStatus = "WARNING";
                }

                Validator.results.push({ check: checkName, status, details: message });
            });
        }
    }
}


class Validator {
  static results: DiagnosticResult[] = [];
  static overallStatus: FinalReport['overallStatus'] = "PASS";

  /** * Records the result, updates overall status, and prints the iconic output for all validation checks. */
  static recordResult(check: string, status: DiagnosticResult["status"], details: string) {
      // 1. Convert Validator status to Doctor ReportResult structure
      let reportResult: ReportResult;
      const fullMessage = `${check}: ${details}`; 

      if (status === "PASS") {
          reportResult = { ok: fullMessage };
      } else if (status === "WARNING") {
          reportResult = { suggest: fullMessage };
      } else { // "FAIL"
          reportResult = { warn: fullMessage };
      }

      // 2. Print the requested iconic console output
      consoleReport(reportResult);

      // 3. Update overall status and capture structured result for JSON report
      if (status === "FAIL") {
          Validator.overallStatus = "FAIL";
      } else if (status === "WARNING" && Validator.overallStatus === "PASS") {
          Validator.overallStatus = "WARNING";
      }
      Validator.results.push({ check, status, details });
  }

  // 1. Check folder name for spaces (Req 1)
  static checkFolderName(dirPath: string): void {
      dirPath = dirPath.trim();
      const checkName = "Folder Name Check (No Spaces)";
      if (/\s/.test(dirPath)) {
          Validator.recordResult(checkName, "FAIL", `The specified path "${dirPath}" contains spaces.`);
          throw new Error(`Critical Validation Failure: Folder name "${dirPath}" contains spaces.`);
      } else {
          Validator.recordResult(checkName, "PASS", "Passed.");
      }
  }

  // 2, 4. Check contents, list files, and check fixed REQUIRED file existence (Req 2, 4)
  static async validateFolderContentsAndList(dirPath: string): Promise<string[]> {
      const checkName = "Folder Contents and Required File Presence";
      
      if (!existsSync(dirPath)) {
          Validator.recordResult(checkName, "FAIL", `The specified folder "${dirPath}" does not exist.`);
          throw new Error(`Critical Validation Failure: The specified folder "${dirPath}" does not exist.`);
      }

      const fileNames: string[] = [];
      let structuralFailure = false;

      for await (const entry of Deno.readDir(dirPath)) {
          if (entry.isDirectory) {
              Validator.recordResult(checkName, "FAIL", `Subfolder found: ${entry.name}. Only csv files are allowed.`);
              structuralFailure = true;
          } else if (entry.isFile) {
              const fileExtension = `.${entry.name.split(".").pop()?.toLowerCase()}`;
              if (fileExtension !== requiredExtension) {
                  Validator.recordResult(checkName, "FAIL", `Invalid file found: ${entry.name}. Only ${requiredExtension} files are allowed.`);
                  structuralFailure = true;
              } else {
                  fileNames.push(entry.name);
              }
          }
      }

      if (fileNames.length === 0) {
          Validator.recordResult(checkName, "FAIL", "No files found in the directory.");
          structuralFailure = true;
      }
      
      const requiredFiles = Object.values(schemas).filter((s) => s.required && !s.multiple).map((s) => s.fileName);
      for (const requiredFile of requiredFiles) {
          if (!fileNames.includes(requiredFile)) {
              Validator.recordResult(checkName, "FAIL", `Required file "${requiredFile}" is missing.`);
              structuralFailure = true;
          }
      }
      
      if (structuralFailure) {
           throw new Error("Critical Validation Failure: Folder structure or required files check failed (See previous logs).");
      }
      
      Validator.recordResult(checkName, "PASS", `Folder structure and required files check passed (${fileNames.length} files found).`);
      return fileNames;
  }
  
  // 6. Validate 'file_name' column in cgm_file_metadata (Req 6)
  static async validateCgmMetadataFilenames(dirPath: string): Promise<string[]> {
      const metadataPath = `${dirPath}/${cgmMetadataFileName}`;
      const checkName = `Metadata Content Check (${cgmMetadataFileName} - file_name)`;
      
      const headers = await getFileHeaders(metadataPath);
      const expectedHeader = "file_name";
      const fileNameIndex = headers.indexOf(expectedHeader);

      if (fileNameIndex === -1) {
          Validator.recordResult(checkName, "FAIL", `Required column '${expectedHeader}' is missing from the headers.`);
          throw new Error(`Critical Validation Failure: '${expectedHeader}' column not found in ${cgmMetadataFileName}.`);
      }
      
      const metadataContent = await getFileContent(metadataPath);
      if (metadataContent.length === 0) {
          Validator.recordResult(checkName, "FAIL", `${cgmMetadataFileName} has no data rows. Must contain at least one row.`);
          throw new Error(`Critical Validation Failure: ${cgmMetadataFileName} has no data rows.`);
      }
      
      const cgmRawBaseNames: string[] = [];
      let contentFailure = false;
      let lineNum = 1; 
      for (const line of metadataContent) {
          lineNum++;
          const columns = line.split(",").map((c) => c.trim().replace(/^['"]|['"]$/g, ""));
          const fileName = columns[fileNameIndex];

          if (!fileName || fileName.length === 0) {
              Validator.recordResult(checkName, "FAIL", `'${expectedHeader}' is empty at line ${lineNum}.`);
              contentFailure = true;
          }
          cgmRawBaseNames.push(fileName);
      }
      
      if (contentFailure) {
          throw new Error(`Critical Validation Failure: Empty 'file_name' found in ${cgmMetadataFileName}.`);
      }
      
      Validator.recordResult(checkName, "PASS", "All 'file_name' entries are non-empty.");
      return cgmRawBaseNames;
  }
  
  // 7. Check if cgm raw files (from metadata) are present in folder (Req 7)
  static checkCgmRawFilePresence(cgmRawBaseNames: string[], allFileNames: string[]): void {
      const checkName = "CGM Raw File Existence Check (from metadata)";
      const uniqueRawBaseNames = [...new Set(cgmRawBaseNames)];
      let missingFile = false;

      for (const baseFileName of uniqueRawBaseNames) {
          const fullFileName = baseFileName.endsWith(requiredExtension)
            ? baseFileName
            : baseFileName + requiredExtension;

          if (!allFileNames.includes(fullFileName)) {
              Validator.recordResult(checkName, "FAIL", `CGM raw file "${fullFileName}" is missing from the folder.`);
              missingFile = true;
          }
      }
      
      if (missingFile) {
          throw new Error("Critical Validation Failure: One or more CGM raw files listed in metadata are missing.");
      }
      
      Validator.recordResult(checkName, "PASS", "All CGM raw files listed in metadata are present.");
  }

  // 3, 5. Schema validation (Header check for all files) (Req 3, 5)
  static async validateFileSchemas(dirPath: string, allFileNames: string[], cgmRawBaseNames: string[]): Promise<void> {
      let schemaFailure = false;
      
      // Step 1: Validate fixed-name files
      for (const schema of Object.values(schemas)) {
          if (allFileNames.includes(schema.fileName) && !schema.fileName.includes("_file_metadata")) { // Skip metadata files since they are validated more deeply elsewhere
              try {
                  await Validator.validateSingleFileSchema(dirPath, schema.fileName, schema);
              } catch (e) {
                  schemaFailure = true;
              }
          }
      }

      // Step 2: Validate the ACTUAL CGM raw files (check for non-empty headers)
      const uniqueCgmRawBaseNames = [...new Set(cgmRawBaseNames)];
      for (const baseFileName of uniqueCgmRawBaseNames) {
          const fullFileName = baseFileName.endsWith(requiredExtension) ? baseFileName : baseFileName + requiredExtension;
          const filePath = `${dirPath}/${fullFileName}`;

          if (!allFileNames.includes(fullFileName)) continue; 

          const rawCheckName = `Schema Check (CGM Raw: ${fullFileName})`;
          const headers = await getFileHeaders(filePath);
          
          if (headers.length === 0) {
              Validator.recordResult(rawCheckName, "FAIL", "File is empty or has no headers.");
              schemaFailure = true;
          } else {
              Validator.recordResult(rawCheckName, "PASS", "Headers are present.");
          }
      }
      
      if (schemaFailure) {
          throw new Error("Critical Validation Failure: Schema validation failed for one or more files.");
      }
  }
  
  // Helper for Schema validation
  private static async validateSingleFileSchema(dirPath: string, fileName: string, schema: FileSchema): Promise<void> {
      const filePath = `${dirPath}/${fileName}`;
      const checkName = `Schema Check (${fileName})`;
      const actualHeaders = await getFileHeaders(filePath);
      const missingHeaders: string[] = [];

      for (const col of schema.columns) {
          if (col.required && !actualHeaders.includes(col.name)) {
              missingHeaders.push(col.name);
          }
      }

      if (missingHeaders.length > 0) {
          Validator.recordResult(checkName, "FAIL", `Missing required column(s): ${missingHeaders.join(", ")}`);
          throw new Error(`Schema validation failed for ${fileName}.`);
      }
      Validator.recordResult(checkName, "PASS", "Headers present.");
  }
  
  // 8. Check mapping fields in cgm_file_metadata for emptiness (Req 8)
  static async validateCgmMetadataMappingFields(dirPath: string): Promise<void> {
      const metadataPath = `${dirPath}/${cgmMetadataFileName}`;
      const checkName = `Metadata Content Check (${cgmMetadataFileName} - Mapping Fields)`;
      const metadataContent = await getFileContent(metadataPath);
      const headers = await getFileHeaders(metadataPath);
      
      const dateMapIndex = headers.indexOf("map_field_of_cgm_date");
      const valueMapIndex = headers.indexOf("map_field_of_cgm_value");
      let contentFailure = false;

      if (dateMapIndex === -1 || valueMapIndex === -1) return; // Should not happen if schema check passed

      let lineNum = 1;
      for (const line of metadataContent) {
          lineNum++;
          const columns = line.split(",").map((c) => c.trim().replace(/^['"]|['"]$/g, ""));
          const dateMap = columns[dateMapIndex];
          const valueMap = columns[valueMapIndex];

          if (!dateMap || dateMap.length === 0) {
              Validator.recordResult(checkName, "FAIL", `'map_field_of_cgm_date' is empty at line ${lineNum}.`);
              contentFailure = true;
          }
          if (!valueMap || valueMap.length === 0) {
              Validator.recordResult(checkName, "FAIL", `'map_field_of_cgm_value' is empty at line ${lineNum}.`);
              contentFailure = true;
          }
      }
      
      if (contentFailure) {
          throw new Error(`Critical Validation Failure: Empty mapping fields found in ${cgmMetadataFileName}.`);
      }
      
      Validator.recordResult(checkName, "PASS", "All mapping fields are non-empty.");
  }
  
  // Helper function: Reads a metadata CSV, validates required columns, and extracts dependent files.
  static async _validateAndExtractMetadata(
      folderName: string,
      metadataFileName: string,
  ): Promise<string[]> {
      const fullPath = `${folderName}/${metadataFileName}`;
      const checkName = `Metadata Validation (${metadataFileName})`;
      let records: Record<string, string>[] = [];

      try {
          const headers = await getFileHeaders(fullPath);
          const expectedHeader = "file_name";
          
          if (!headers.includes(expectedHeader)) {
              Validator.recordResult(checkName, "FAIL", `Required column '${expectedHeader}' is missing from the headers.`);
              throw new Error("Missing critical header.");
          }
          
          const csvContent = await Deno.readTextFile(fullPath);
          records = parse(csvContent, { 
              skipFirstRow: true, headers: headers, separator: ',',
          }) as Record<string, string>[];
          
          if (records.length === 0) {
              Validator.recordResult(checkName, "FAIL", "File is empty or contains only headers.");
              throw new Error("No data rows found.");
          }

          const dependentFileNames: string[] = [];
          const schema = schemas[metadataFileName.replace(".csv", "")];
          let contentFailure = false;

          records.forEach((row, index) => {
              const rowNumber = index + 2; 
              for (const key of headers) {
                  const value = row[key];
                  
                  if (value === null || value === undefined || String(value).trim().length === 0) {
                      const isRequired = schema.columns.some(col => col.name === key && col.required);
                      if (isRequired) {
                          Validator.recordResult(checkName, "FAIL", `Required column '${key}' is empty at row ${rowNumber}.`);
                          contentFailure = true;
                      }
                  }
              }
              dependentFileNames.push(row[expectedHeader].trim());
          });
          
          if (contentFailure) {
              throw new Error("Empty required columns found in metadata.");
          }
          
          return dependentFileNames;

      } catch (error) {
          if (!error.message.startsWith("Critical Validation Failure")) {
              Validator.recordResult(checkName, "FAIL", `Error processing metadata file: ${error.message}`);
          }
          throw new Error(`Critical Validation Failure: ${metadataFileName} failed processing.`);
      }
  }

  // 9. Conditional existence check for meal/fitness data and metadata (Req 9)
  static async validateOptionalFileExistence(folderName: string, allFileNames: string[]): Promise<void> {
      const mealMetadataFileName = "meal_file_metadata.csv";
      const fitnessMetadataFileName = "fitness_file_metadata.csv";
      let overallPass = true;
      
      const mealMetadataPresent = allFileNames.includes(mealMetadataFileName);
      const fitnessMetadataPresent = allFileNames.includes(fitnessMetadataFileName);
      
      const checkName = "Optional File Existence and Dependency Check";

      // MEAL CHECKS
      if (mealMetadataPresent) {
          try {
              const dependentMealFiles = await Validator._validateAndExtractMetadata(folderName, mealMetadataFileName);
              const listedDataFileBaseNames = [...new Set(dependentMealFiles.map(f => f.split('/').pop() || f))]; 
              
              if(listedDataFileBaseNames.length === 0) {
                  Validator.recordResult(checkName, "FAIL", `'${mealMetadataFileName}' is present but lists no dependent files.`);
                  throw new Error("No dependent files listed.");
              }

              for (const listedFileBaseName of listedDataFileBaseNames) {
                  const fullFileName = listedFileBaseName.endsWith(requiredExtension) ? listedFileBaseName : listedFileBaseName + requiredExtension;
                  if (!allFileNames.includes(fullFileName)) {
                      Validator.recordResult(checkName, "FAIL", `Dependent file '${fullFileName}' listed in '${mealMetadataFileName}' is missing.`);
                      throw new Error("Missing dependent file.");
                  }
                  const headers = await getFileHeaders(`${folderName}/${fullFileName}`);
                  if (headers.length === 0) {
                      Validator.recordResult(checkName, "FAIL", `Dependent file '${fullFileName}' is empty or has no headers.`);
                      throw new Error("Empty dependent file.");
                  }
              }
              Validator.recordResult(checkName, "PASS", `${mealMetadataFileName} and all listed dependent files passed.`);

          } catch (e) {
              overallPass = false;
          }
      } else {
          Validator.recordResult(checkName, "PASS", `${mealMetadataFileName} not provided (Optional).`);
      }
      
      // FITNESS CHECKS
      if (fitnessMetadataPresent) {
          try {
              const dependentFitnessFiles = await Validator._validateAndExtractMetadata(folderName, fitnessMetadataFileName);
              const listedDataFileBaseNames = [...new Set(dependentFitnessFiles.map(f => f.split('/').pop() || f))]; 
              
              if(listedDataFileBaseNames.length === 0) {
                  Validator.recordResult(checkName, "FAIL", `'${fitnessMetadataFileName}' is present but lists no dependent files.`);
                  throw new Error("No dependent files listed.");
              }
              
              for (const listedFileBaseName of listedDataFileBaseNames) {
                  const fullFileName = listedFileBaseName.endsWith(requiredExtension) ? listedFileBaseName : listedFileBaseName + requiredExtension;
                  if (!allFileNames.includes(fullFileName)) {
                      Validator.recordResult(checkName, "FAIL", `Dependent file '${fullFileName}' listed in '${fitnessMetadataFileName}' is missing.`);
                      throw new Error("Missing dependent file.");
                  }
                  const headers = await getFileHeaders(`${folderName}/${fullFileName}`);
                  if (headers.length === 0) {
                      Validator.recordResult(checkName, "FAIL", `Dependent file '${fullFileName}' is empty or has no headers.`);
                      throw new Error("Empty dependent file.");
                  }
              }
              Validator.recordResult(checkName, "PASS", `${fitnessMetadataFileName} and all listed dependent files passed.`);
          } catch (e) {
              overallPass = false;
          }
      } else {
          Validator.recordResult(checkName, "PASS", `${fitnessMetadataFileName} not provided (Optional).`);
      }

      if (!overallPass) {
          throw new Error("Critical Validation Failure: Optional file dependency checks failed (See previous logs).");
      }
  }
}


// --- DB INTERACTION LOGIC (Steps 3 & 4) ---

/** * Initializes the Surveilr RSSD schema in the database. (Step 3) */
async function initializeSurveilrDB(dbPath: string): Promise<void> {
    console.log(colors.cyan(`\n--- 3. Initializing Surveilr RSSD Database (${dbPath}) ---`));
    try {
        const result = await $`surveilr admin init -d ${dbPath}`.noThrow().stdout("inherit").stderr("inherit");
        
        if (result.code !== 0) {
            throw new Error(`Surveilr command failed with exit code ${result.code}.`);
        }
        console.log(colors.green("✅ Surveilr RSSD Initialized successfully."));
    } catch (e) {
        throw new Error(`Surveilr initialization failed: ${e instanceof Error ? e.message : String(e)}`);
    }
}

/** * Creates the validation_reports table and inserts the JSON report using the 'surveilr shell' CLI 
 * reading from a temporary SQL file, fulfilling the request to emit SQL to a file. 
 */
async function insertReportToDB(dbPath: string, report: FinalReport): Promise<void> {
    console.log(colors.cyan("\n--- 4. Inserting Validation Report to DB via 'surveilr shell' CLI (Using SQL File) ---"));
    console.log(colors.dim(`Actual DB path: ${dbPath}`)); 

    // 1. Define DDL SQL
    const createTableSql = `
        CREATE TABLE IF NOT EXISTS validation_reports (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            folder_name TEXT,
            tenant_id TEXT,
            tenant_name TEXT,
            overall_status TEXT NOT NULL,
            report_json TEXT 
        );
    `;
    
    // 2. Prepare DML data and SQL
    const reportJsonString = JSON.stringify(report);
    // Escape single quotes within the JSON string for SQL safety (' -> '').
    const escapedReportJson = reportJsonString.replaceAll("'", "''");
    
    const insertQuerySql = `
        INSERT INTO validation_reports (
            timestamp, folder_name, tenant_id, tenant_name, overall_status, report_json
        )
        VALUES (
            '${report.timestamp}', 
            '${report.folderName}', 
            '${report.tenantId}', 
            '${report.tenantName}', 
            '${report.overallStatus}', 
            '${escapedReportJson}'
        );
    `;

    const combinedSql = createTableSql + insertQuerySql;
    
    // Create a unique temporary SQL file path
    const timestampCleaned = report.timestamp.replace(/[:.]/g, '-');
    const sqlFilePath = `./validation-reports/insert_report_${timestampCleaned}.sql`; 
    

    try {
        // 3. Emit SQL to file
        await Deno.writeTextFile(sqlFilePath, combinedSql);
        console.log(colors.yellow(`\n📝 SQL statements emitted to file: ${sqlFilePath}`));
        
        // Print the emitted content for user verification
        console.log(colors.dim("\n--- Content of Emitted SQL File (Truncated) ---\n" + combinedSql.trim().split('\n').slice(0, 8).join('\n') + "\n... (omitting full JSON content)\n"));
        
        // 4. Execute SQL file using surveilr shell
        console.log(colors.dim(`Executing: surveilr shell ${sqlFilePath}`));

        const result = await $`surveilr shell   ${sqlFilePath}`.noThrow().stdout("inherit").stderr("inherit");
        
        if (result.code !== 0) {
             throw new Error(`surveilr shell execution failed with exit code ${result.code}.`);
        }
        
        console.log(colors.green(`✅ Validation Report inserted into ${dbPath} using 'surveilr shell' reading from SQL file.`));

    } catch (e) {
        throw new Error(`'surveilr shell' execution failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
        // 5. Clean up the temporary SQL file
        if (existsSync(sqlFilePath)) {
            await Deno.remove(sqlFilePath);
            console.log(colors.dim(`Cleaned up temporary file: ${sqlFilePath}`));
        }
    }
}
// --- MAIN APPLICATION LOGIC (App Class) ---

class App {
    constructor(private folderName: string, private tenantId: string, private tenantName: string) {}

    async runPreFlightGate(): Promise<FinalReport> { 
        Validator.results = []; 
        Validator.overallStatus = "PASS";
        const dbPath = "./resource-surveillance.sqlite.db";

        if (!dbPath) {
            // Note: Unlike the data validation, this is a fatal environment error that must halt immediately.
            console.error(colors.red("FATAL ERROR: SPRY_DB environment variable is not set. Cannot run database operations."));
            Deno.exit(1);
        }
        
        // --- Generate unique report file path ---
        const REPORT_DIR = "validation-reports";
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-'); 
        const fileName = `${timestamp}_${this.tenantId}_report.json`;
        const outputPath = `${REPORT_DIR}/${fileName}`;
        // -------------------------------------------

        try {
            // 1. Run Dependency Checks (Populates Validator.results internally with iconic output)
            await runDoctorChecks(); 

            // Only proceed to data validation if no critical dependency failure occurred
            if (Validator.overallStatus != "FAIL") {
                console.log(colors.cyan("\n--- 2. Running Data Structure and Content Validation (Iconic Output) ---"));
                
                // Execute all data validation checks. Critical failure throws an Error.
                Validator.checkFolderName(this.folderName);
                const allFileNames = await Validator.validateFolderContentsAndList(this.folderName);
                const cgmRawBaseNames = await Validator.validateCgmMetadataFilenames(this.folderName);
                Validator.checkCgmRawFilePresence(cgmRawBaseNames, allFileNames);
                await Validator.validateFileSchemas(this.folderName, allFileNames, cgmRawBaseNames);
                await Validator.validateCgmMetadataMappingFields(this.folderName);
                await Validator.validateOptionalFileExistence(this.folderName, allFileNames);
                
                console.log(colors.green(`\n✅ Overall Validation Status: ${Validator.overallStatus}`));
            } else {
                 console.log(colors.red("\n❌ Skipping Data/DB Operations due to critical dependency failure."));
            }

        } catch (error) {
            // Catches critical errors thrown by Validator methods or unexpected script errors
            console.error(colors.red(`\nCRITICAL FAILURE HALT: ${error instanceof Error ? error.message : String(error)}`));
            Validator.overallStatus = "FAIL";
        }
        
        // --- Generate and Save JSON Report (Always runs) ---
        const finalReport: FinalReport = {
            timestamp: new Date().toISOString(),
            folderName: this.folderName,
            tenantId: this.tenantId,
            tenantName: this.tenantName,
            overallStatus: Validator.overallStatus,
            results: Validator.results,
        };

        await ensureDir(REPORT_DIR); 
        await Deno.writeTextFile(outputPath, JSON.stringify(finalReport, null, 2));
        console.log(colors.yellow(`\n📝 JSON report generated at: ${outputPath}`));
        
        // --- Execute DB Operations only if validation passed (Steps 3 & 4) ---
        if (finalReport.overallStatus === "PASS") {
            try {
                await initializeSurveilrDB(dbPath); // Step 3
                await insertReportToDB(dbPath,finalReport); // Step 4
            } catch (dbError) {
                console.error(colors.red(`\nDATABASE OPERATION FAILURE: ${dbError instanceof Error ? dbError.message : String(dbError)}`));
                finalReport.overallStatus = "FAIL"; 
            }
        } else {
             console.log(colors.yellow("\nSkipping DB initialization/insertion due to validation failure."));
        }
        
        return finalReport;
    }
}

// --- MAIN EXECUTION BLOCK ---

if (import.meta.main) {
    try {
        const args = Deno.args;
        // Expected args: <folderName> <tenantId> <tenantName>
        if (args.length !== 3) { 
            console.error(colors.red("FATAL ERROR: Missing required arguments."));
            console.error(colors.yellow("Usage: deno run pre-etl-validation.ts <folderName> <tenantId> <tenantName>"));
            Deno.exit(1);
        }

        const folderName = args[0];
        const tenantId = args[1];
        const tenantName = args[2];
        
        const app = new App(folderName, tenantId, tenantName);
        const report = await app.runPreFlightGate(); 

        if (report.overallStatus === "PASS") {
            Deno.exit(0);
        } else {
            Deno.exit(1); // Ensures pipeline halts on FAIL or WARNING
        }
    } catch (e) {
        console.error(colors.red(`\nUNEXPECTED SCRIPT ERROR: ${e instanceof Error ? e.message : String(e)}`));
        Deno.exit(1);
    }
}