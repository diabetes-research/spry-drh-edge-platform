# Study Supporting Files(CSV) Generator

This document serves as a guide for researchers using the **Study Supporting Files(CSV) Generator**, a tool designed to convert human-readable study information into a structured, relational CSV format .

## Project Overview

The primary goal of this tool is to streamline the creation of metadata files for scientific datasets, such as the **CGMacros** project. By parsing a standardized text file, the script ensures that study details—ranging from funding sources to author-investigator relationships—are consistently formatted for database ingestion or public repository submission.

## Key Features

* **Automated ID Generation**: The script automatically creates validated, unique identifiers for institutions, investigators, authors, labs, publications, and sites (e.g., `AUTH-01`, `INST-01`).
* **Relational Mapping**: It intelligently links authors to their corresponding investigator profiles based on name matching.
* **Strict Validation**: The tool enforces a strict 4-character alphanumeric requirement for the `StudyID` and uses regex patterns to validate all generated entity IDs.
* **Standards-Compliant Output**: Missing data is represented as truly empty fields (`,,`) within the CSVs, adhering to data processing best practices.

### How to Use the Generator

Researchers can execute the generator via the command line by providing the input file and a target directory for the results.

**Env setup:**

```bash
cd drh-edge-core
./setup.sh
source venv/bin/activate.fish # if fish shell
```

**Command Syntax:**

```bash
venv/bin/python3 support/aides/cgmacros/generate-study-supporting-files.py <input_file_path> <output_directory_path>
```

**Example Run (CGMacros):**

```bash
venv/bin/python3 support/aides/cgmacros/generate-study-supporting-files.py support/aides/cgmacros/cgmacros-study-info.txt examples/cgm-macros-supporting-data
```

### Input File Requirements

The generator requires a text file (e.g., `cgmacros-study-info.txt`) structured with specific headers and `Key: Value` pairs. For entries containing multiple items, such as a list of authors or multiple institutions, use a **semicolon (`;`)** to separate the values.

---

### AI Prompt for Code Generation

If you need to regenerate or modify the underlying logic, use the following detailed prompt:

> "Create a Python script using `pandas` and `argparse` to convert a metadata text file into seven relational CSVs: `study`, `institution`, `investigator`, `author`, `lab`, `publication`, and `site`.
> **Technical Requirements:**
>
> * **CLI Interface**: Accept positional arguments for `input` (text file) and `output` (directory).
> * **ID Logic**: Validate `StudyID` as exactly 4 alphanumeric characters. Auto-increment other IDs (e.g., `INV-01`) using the pattern `^[A-Z0-9][A-Z0-9-]{1,12}[A-Z0-9]$`.
> * **Author Linking**: Map the `investigator_id` to an author if their name appears in both the Author and Investigator lists.
> * **Empty Values**: Ensure null data is saved as empty strings (`,,`) using `na_rep=''` in the CSV output.
> * **Multi-value Parsing**: Split values containing semicolons into separate relational rows."
