# SPRY DRH EDGE PLATFORM

**End-to-end platform for Diabetes Research Hub (DRH) Edge data integration using Spry and SQLPage.**

## Overview

The **Diabetes Research Hub (DRH) SQLPage Application** is an ETL (Extract, Transform, Load) pipeline and web interface designed to process and visualize raw diabetes research data. This project automates the conversion of raw study files (e.g., CSV, Parquet) into a structured **SQLite database** and uses the **Spry** framework to generate a dynamic user interface powered by **SQLPage**.

The goal is to provide a centralized platform for managing and analyzing continuous glucose monitor (CGM) data from various research studies.

-----

## 🌟 Features

The platform performs a complete workflow for converting raw diabetes research data (CGM, meal, fitness) into a structured SQLite database and presenting it via a rich, interactive web UI.


* **Data Conversion:** Automates the ingestion and conversion of raw study files (e.g., CSV) into a structured format using the `surveilr` tool.
* **DuckDB ETL:** Utilizes **DuckDB** for complex data transformation and integration, including combining CGM tracings and generating derived meal and fitness metadata.
* **SQLPage UI:** Generates a modern, interactive data dashboard using **SQLPage** powered by the resulting SQLite database.
* **Comprehensive Dashboards:** Includes dedicated pages for:
  * Study Participant Dashboard (metrics, demographics)
  * Combined CGM Tracing, Meal, and Fitness Data
  * Ingestion, Verification, and De-Identification Logs
  * Associated metadata (Researchers, Institutions, Devices)

-----

## 💻 Technology Stack

| Technology | Role |
| :--- | :--- |
| **Spry** | Manages the project tasks and generates the SQLPage presentation layer. |
| **SQLPage** | The core web application framework, using SQL to render dynamic web pages. |
| **surveilr** | Performs CSV file conversion and transformation into an RSSD (Research Study Data Database) format. |
| **DuckDB** | Utilized for complex data transformations and ETL operations. |
| **SQLite** | The final, structured database format used by SQLPage. |

-----

## 🛠️ Prerequisites & Setup

### Prerequisites

Ensure you have the following installed to run the platform:

1. **[Deno](https://deno.land/):** Used to run the Spry CLI tool (`spry.ts`).
2. **[Surveilr](https://github.com/surveilr/packages/releases):** The data-processing utility for file ingestion and orchestration.
3. **DuckDB**: Used within the data preparation scripts for ETL operations.
4. **direnv**: Recommended for managing environment variables easily.

### ⚙️ Installation Steps

Follow these steps to install the required tools on a Linux system.

#### 1. Install Deno

Deno is required to run the Spry CLI.

```bash
# Using the recommended installation script
curl -fsSL https://deno.land/x/install/install.sh | sh
# Ensure Deno is added to your PATH (the script usually suggests the line)
# Example: export PATH="$HOME/.deno/bin:$PATH"
```

#### 2. Install DuckDB (v1.4.1+)

DuckDB is used for complex ETL and data transformations.

```bash
# Download and install the latest stable version
wget https://github.com/duckdb/duckdb/releases/download/v1.4.1/duckdb_cli-linux-amd64.zip
unzip duckdb_cli-linux-amd64.zip
chmod +x duckdb
sudo mv duckdb /usr/local/bin/
```

#### 3. Install SQLite

SQLite is the final structured database used by SQLPage. On most systems, it can be installed via the package manager.

```bash
# For Debian/Ubuntu-based systems
sudo apt update
sudo apt install sqlite3 libsqlite3-dev
```

#### 4\. Install Surveilr

Surveilr is the data-processing utility for file ingestion.The latest surveilr packages can be found [here.](https://github.com/surveilr/packages/releases)

```bash
# Download the latest stable release (e.g., v3.6.0)
wget https://github.com/surveilr/packages/releases/download/3.6.0/surveilr_3.6.0_x86_64-unknown-linux-gnu.tar.gz

# Extract it
tar -xzf surveilr_3.6.0_x86_64-unknown-linux-gnu.tar.gz

# Install it by moving the executable to a directory in your PATH
sudo mv surveilr /usr/local/bin/
```

### Environment Variables

Configuration is handled through environment variables, ideally managed with **direnv** and stored in a local `.envrc` file.

You can generate a starter `.envrc` file and add it to your local configuration using Spry:

```bash
./spry.ts task prepare-env
direnv allow
```

| Variable | Description | Example Value | Required for `prepare-db` |
| :--- | :--- | :--- | :--- |
| **`SPRY_DB`** | The database connection URL used by SQLPage and Spry. | `sqlite://resource-surveillance.sqlite.db?mode=rwc` | Yes |
| **`PORT`** | The TCP port for the local SQLPage server. | `9227` | Yes |
| **`STUDY_DATA_PATH`** | The path to the folder containing your raw study files (the input folder for ingestion). | `raw-data/synthetic-data/` | Yes |
| **`TENANT_ID`** | A unique, short identifier for your study or tenant. | `FLCG` | Yes |
| **`TENANT_NAME`** | The full, human-readable name for your study or organization. | `"Florida Clinical Group"` | Yes |

**Example `.envrc` content:**

```envrc
export SPRY_DB="sqlite://resource-surveillance.sqlite.db?mode=rwc"
export PORT=9227
export STUDY_DATA_PATH="raw-data/synthetic-data/"
export TENANT_ID="FLCG"
export TENANT_NAME="Florida Clinical Group"
direnv allow
```

> ⚠️ **Security Note:** Never commit secrets or production credentials into `.envrc`. Ensure `.envrc` and the generated database file (e.g., `resource-surveillance.sqlite.db`) are added to your `.gitignore`.

-----

## 🚀 Usage

The project's workflow involves two main steps: preparing the database (ETL) and running the web server (UI).

### 1. Prepare the Database (`prepare-db`)

This task executes the full ETL pipeline to ingest and transform the raw data into the structured SQLite database.

1. **Organize Data:** Place your research data files in the directory specified by **`STUDY_DATA_PATH`**.

2. **Run Ingestion:** Execute the main task script from your terminal:

    ```bash
    ./spry.ts task prepare-db
    ```

    This script removes any previous database, executes the validation checks, and then uses `surveilr` and **DuckDB** to process the data and generate the final database structure.

### 2. Run the SQLPage Server (`build-run-server`)

This command builds the necessary files for the SQLPage application and starts the local web server.

```bash
./spry.ts task build-run-server
```

You can now access the **Diabetes Research Hub Edge UI** in your browser at the address specified by your **`PORT`** environment variable (e.g., `http://localhost:9227`).

-----

## 🛠️ Development & Deployment

### Development / Watch Mode

For active development, the watch mode automatically regenerates the SQLPage application whenever the `Spryfile.md` or other watched files are updated.

```bash
./spry.ts spc --fs dev-src.auto --destroy-first --conf sqlpage/sqlpage.json --watch --with-sqlpage
```

* `--watch`: Monitors `Spryfile.md` for changes.
* `--with-sqlpage`: Automatically starts and restarts the SQLPage server after each successful build.

### Single-Database Deployment (Production)

To package the entire SQLPage application into the SQLite database itself (for simpler deployment without a `dev-src.auto` directory):

```bash
./spry.ts task build-to-db
# This command first removes the dev directory, then packages all SQLPage files into the database.
```

### Cleanup

To remove generated artifacts like the development source directory and temporary SQL files:

```bash
./spry.ts task clean
```
