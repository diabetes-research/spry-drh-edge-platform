---
sqlpage-conf:
  database_url: "sqlite://DRH.studydata.sqlite.db?mode=rwc"
  web_root: "./dev-src.auto"
  allow_exec: true
  port: 9227
---

# Diabetes Research Hub (DRH) SQLPage Application

This script automates the conversion of raw diabetes research data (e.g.,
CSV, Parquet, or a private data warehouse export) into a structured SQLite database.

- Uses Spry to manage tasks and generate the SQLPage presentation layer.
- surveilr tool performs csv files conversation and transformation to RSSD
- Uses DuckDB for data transformation.(file meta ingest data,meal fitness data(if present),combined CGM data)
- Export back to sqlite db to be used in SQLpage

## Setup

Download your research data source (based on  the file format mentioned in  https://drh.diabetestechnology.org/organize-cgm-data ) and place it into the same
directory as this `README.md` and then run `spry.ts task prepare-db`. pass the study files folder name in the prepare-db task

```bash prepare-db --descr "Validates ,Extract data , Perform transformations through DuckDB and export to the SQLite database used by SQLPage"
#!/usr/bin/env -S bash
## example usage  ./run-drh-etl-surveilr.sh --data_path raw-data/flexi-cgm-study/ --tenant_id FLCG --tenant_name "FLCG" 
 ./run-drh-etl-surveilr.sh --data_path raw-data/flexi-cgm-study/ --tenant_id FLCG --tenant_name "FLCG" 

```

## SQLPage Dev / Watch mode

While you're developing, Spry's `dev-src.auto` generator should be used:

```bash prepare-sqlpage-dev --descr "Generate the dev-src.auto directory to work in SQLPage dev mode"
./spry.ts spc --fs dev-src.auto --destroy-first --conf sqlpage/sqlpage.json
./create-raw-cgm-sql-files.sh 
```

```bash clean --descr "Clean up the project directory's generated artifacts"
rm -rf dev-src.auto
```

In development mode, here’s the `--watch` convenience you can use so that
whenever you update `Spryfile.md`, it regenerates the SQLPage `dev-src.auto`,
which is then picked up automatically by the SQLPage server:

```bash
./spry.ts spc --fs dev-src.auto --destroy-first --conf sqlpage/sqlpage.json --watch --with-sqlpage
```

- `--watch` turns on watching all `--md` files passed in (defaults to `Spryfile.md`)
- `--with-sqlpage` starts and stops SQLPage after each build

Restarting SQLPage after each re-generation of dev-src.auto is **not**
necessary, so you can also use `--watch` without `--with-sqlpage` in one
terminal window while keeping the SQLPage server running in another terminal
window.

If you're running SQLPage in another terminal window, use:

```bash
./spry.ts spc --fs dev-src.auto --destroy-first --conf sqlpage/sqlpage.json --watch
```

## SQLPage single database deployment mode

After development is complete, the `dev-src.auto` can be removed and
single-database deployment can be used:

```bash deploy --descr "Generate sqlpage_files table upsert SQL and push them to SQLite"
rm -rf dev-src.auto
./spry.ts spc --package --conf sqlpage/sqlpage.json | sqlite3 DRH.studydata.sqlite.db
```

## Raw SQL

This raw SQL will be placed into HEAD/TAIL.

```sql TAIL --import ../../../lib/universal/schema-info.dml.sqlite.sql
-- this will be replaced by the content of schema-info.dml.sqlite.sql
```

This raw SQL will be placed into HEAD/TAIL. Include as a duplicate of the above
show style-difference between `sql TAIL --import` and `import` which creates
pseudo-cells.

```import --base ../../../lib/universal
sql *.sql TAIL
```

## Layout

This cell instructs Spry to automatically inject the SQL `PARTIAL` into all
SQLPage content cells. The name `global-layout.sql` is not significant (it's
required by Spry but only used for reference), but the `--inject **/*` argument
is how matching occurs. The `--BEGIN` and `--END` comments are not required by
Spry but make it easier to trace where _partial_ injections are occurring.

```sql PARTIAL global-layout.sql --inject **/*

-- BEGIN: PARTIAL global-layout.sql
SELECT 'shell' AS component,
       'Diabetes Research Hub Edge' AS title,
       NULL AS icon,
       'https://drh.diabetestechnology.org/_astro/favicon.CcrFY5y9.ico' AS favicon,
       'https://drh.diabetestechnology.org/images/diabetic-research-hub-logo.png' AS image,
       'fluid' AS layout,
       true AS fixed_top_menu,
       '/' AS link,
       '{"link":"/","title":"Home"}' AS menu_item,
       'https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/highlight.min.js' AS javascript,
       'https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/languages/sql.min.js' AS javascript,
       'https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/languages/handlebars.min.js' AS javascript,
       'https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/languages/json.min.js' AS javascript,
        '/static//d3-aide.js' AS javascript,
        '/js/chart-component.js' AS javascript,  
        '{"link":"https://drh.diabetestechnology.org/","title":"DRH Home","target": "__blank"}' AS menu_item, 
        '{"link":"https://www.diabetestechnology.org/index.shtml","title":"DTS Home","target": "__blank"}' AS menu_item,         
       '/static/stacked-bar-chart.js' AS javascript_module,
       '/static/gri-chart.js' AS javascript_module,
       '/static/dgp-chart.js' AS javascript_module,
       '/static/agp-chart.js' AS javascript_module,
       '/static/formula-component.js' AS javascript_module
       ;

SET resource_json = sqlpage.read_file_as_text('spry.d/auto/resource/${path}.auto.json');
SET page_title  = json_extract($resource_json, '$.route.caption');
-- END: PARTIAL global-layout.sql
-- this is the `${cell.info}` cell on line ${cell.startLine}
```

Get the brand assets and store them into the SQLPage content stream. They will
be stored as `assets/brand/*` because the `--base` is `https://drh.diabetestechnology.org`. The `--spc` reminds Spry to include it as part of
the SQLPage content since by default utf8 and other file types don't get
inserted into the stream.

## DRH EDGE  Home Page

Index page which automatically generates links to all `/drh` pages.

```sql index.sql { route: { caption: "DRH Edge UI Home" } }
-- @route.description "Welcome to Diabetes Research Hub Edge UI."

SELECT
      'card'                      as component,
      'Welcome to the Diabetes Research Hub Edge UI' as title,
      1                           as columns;

SELECT
      'About' as title,
      'green'                        as color,
      'white'                  as background_color,
      'The Diabetes Research Hub (DRH) addresses a growing need for a centralized platform to manage and analyze continuous glucose monitor (CGM) data.Our primary focus is to collect data from studies conducted by various researchers. Initially, we are concentrating on gathering CGM data, with plans to collect additional types of data in the future.' as description,
      'home'                 as icon;

SELECT
      'card'                  as component,
      'Files Log' as title,
      1                     as columns;


SELECT
    'Study Files Log'  as title,
    '/drh/ingestion-log.sql' as link,
    'This section provides an overview of the files that have been accepted and converted into database format for research purposes' as description,
    'book'                as icon,
    'red'                    as color;

;

SELECT
      'card'                  as component,
      'File Verification Results' as title,
      1                     as columns;

SELECT
    'Verification Log' AS title,
    '/drh/verification-validation-log.sql' AS link,
    'Use this section to review the issues identified in the file content and take appropriate corrective actions.' AS description,
    'table' AS icon,
    'red' AS color;



SELECT
      'card'                  as component,
      'Features ' as title,
      9                     as columns;


SELECT
    'Study Participant Dashboard'  as title,
    '/drh/study-participant-dashboard.sql' as link,
    'The dashboard presents key study details and participant-specific metrics in a clear, organized table format' as description,
    'table'                as icon,
    'red'                    as color;
;




SELECT
    'Researcher and Associated Information'  as title,
    '/drh/researcher-related-data.sql' as link,
    'This section provides detailed information about the individuals , institutions and labs involved in the research study.' as description,
    'book'                as icon,
    'red'                    as color;
;

SELECT
    'Study ResearchSite Details'  as title,
    '/drh/study-related-data.sql' as link,
    'This section provides detailed information about the study , and sites involved in the research study.' as description,
    'book'                as icon,
    'red'                    as color;
;

SELECT
    'Participant Demographics'  as title,
    '/drh/participant-related-data.sql' as link,
    'This section provides detailed information about the the participants involved in the research study.' as description,
    'book'                as icon,
    'red'                    as color;
;

SELECT
    'Author and Publication Details'  as title,
    '/drh/author-pub-data.sql' as link,
    'Information about research publications and the authors involved in the studies are also collected, contributing to the broader understanding and dissemination of research findings.' as description,
     'book' AS icon,
    'red'                    as color;
;



SELECT
    'CGM Meta Data and Associated information'  as title,
    '/drh/cgm-associated-data.sql' as link,
    'This section provides detailed information about the CGM device used, the relationship between the participant''s raw CGM tracing file and related metadata, and other pertinent information.' as description,
    'book'                as icon,
    'red'                    as color;

;


SELECT
    'Raw CGM Data Description' AS title,
    '/drh/cgm-data.sql' AS link,
    'Explore detailed information about glucose levels over time, including timestamp, and glucose value.' AS description,
    'book'                as icon,
    'red'                    as color;                

SELECT
    'Combined CGM Tracing' AS title,
    '/drh/cgm-combined-data.sql' AS link,
    'Explore the comprehensive CGM dataset, integrating glucose monitoring data from all participants for in-depth analysis of glycemic patterns and trends across the study.' AS description,
    'book'                as icon,
    'red'                    as color;         


SELECT
    'PHI De-Identification Results' AS title,
    '/drh/deidentification-log.sql' AS link,
    'Explore the results of PHI de-identification and review which columns have been modified.' AS description,
    'book'                as icon,
    'red'                    as color;
;

```


## Study Files Log Page

```sql drh/ingestion-log.sql { route: { caption: "Study Files Log" } }
-- @route.description "This section provides an overview of the files that have been accepted and converted into database format for research purposes"

SELECT 'text' AS component, $page_title AS title;

${paginate("drh_study_files_table_info")}

SELECT
  '
  This section provides an overview of the files that have been accepted and converted into database format for research purposes. The conversion process ensures that data from various sources is standardized, making it easier for researchers to analyze and draw meaningful insights.
  Additionally, the corresponding database table names generated from these files are listed for reference.' as contents;

SELECT 'table' AS component,
  TRUE AS sort,
  TRUE AS search;

SELECT
  file_name,
  file_format,
  table_name
FROM drh_study_files_table_info
ORDER BY file_name ASC
${pagination.limit}; 
${pagination.navigation} 

```

## Verification Validation log page

```sql drh/verification-validation-log.sql { route: { caption: "Verification And Validation Results" } }
-- @route.description "This section provides the verification and valdiation results performed on the study files"


SELECT 'text' AS component, $page_title AS title;

${paginate("drh_study_files_table_info")}

SELECT
    'text' as component,
    '
    Validation is a detailed process where we assess if the data within the files conforms to expecuted rules or constraints. This step ensures that the content of the files is both correct and meaningful before they are utilized for further processing.' as contents;



SELECT
  'steps' AS component,
  TRUE AS counter,
  'green' AS color;


SELECT
  'Check the Validation Log' AS title,
  'file' AS icon,
  '#' AS link,
  'If the log is empty, no action is required. Your files are good to go! If the log has entries, follow the steps below to fix any issues.' AS description;


SELECT
  'Note the Issues' AS title,
  'note' AS icon,
  '#' AS link,
  'Review the log to see what needs fixing for each file. Note them down to make a note on what needs to be changed in each file.' AS description;


SELECT
  'Stop the Edge UI' AS title,
  'square-rounded-x' AS icon,
  '#' AS link,
  'Make sure to stop the UI (press CTRL+C in the terminal).' AS description;


SELECT
  'Make Corrections in Files' AS title,
  'edit' AS icon,
  '#' AS link,
  'Edit the files according to the instructions provided in the log. For example, if a file is empty, fill it with the correct data.' AS description;


SELECT
  'Copy the modified Files to the folder' AS title,
  'copy' AS icon,
  '#' AS link,
  'Once you’ve made the necessary changes, replace the old files with the updated ones in the folder.' AS description;


SELECT
  'Execute the automated script again' AS title,
  'retry' AS icon,
  '#' AS link,
  'Run the command again to perform file conversion.' AS description;


SELECT
  'Repeat the steps until issues are resolved' AS title,
  'refresh' AS icon,
  '#' AS link,
  'Continue this process until the log is empty and all issues are resolved' AS description;


SELECT
    'text' as component,
    '
    Reminder: Keep updating and re-running the process until you see no entries in the log below.' as contents;


SELECT
  'alert' AS component,
  'success' AS color,
  '✅ There are no validation or verification issues. All checks passed successfully!' AS title,
  'Your data has passed all verification and validation checks.' AS description
WHERE (SELECT COUNT(*) FROM drh_vandv_orch_issues) = 0;



SELECT 'table' AS component,
  TRUE AS sort,
  TRUE AS search
WHERE (SELECT COUNT(*) FROM drh_vandv_orch_issues) > 0;

SELECT *
FROM drh_vandv_orch_issues
WHERE (SELECT COUNT(*) FROM drh_vandv_orch_issues) > 0
${pagination.limit}; 
${pagination.navigation}

```

## Study Participant Dashboard

```sql drh/study-participant-dashboard.sql{ route: { caption: "Study Participant Dashboard" } }
-- @route.description "The dashboard presents key study details and participant-specific metrics in a clear, organized table format"


${paginate("participant_dashboard_cached")}

SELECT
'datagrid' AS component; 

SELECT
    'Study Name' AS title,
    '' || study_name || '' AS description
FROM
    drh_study_vanity_metrics_details;

SELECT
    'Start Date' AS title,
    '' || start_date || '' AS description
FROM
    drh_study_vanity_metrics_details;

SELECT
    'End Date' AS title,
    '' || end_date || '' AS description
FROM
    drh_study_vanity_metrics_details;

SELECT
    'NCT Number' AS title,
    '' || nct_number || '' AS description
FROM
    drh_study_vanity_metrics_details;




SELECT
   'card'     as component,
   '' as title,
    4         as columns;

SELECT
   'Total Number Of Participants' AS title,
   '' || total_number_of_participants || '' AS description
FROM
    drh_study_vanity_metrics_details;

SELECT

    'Total CGM Files' AS title,
   '' || number_of_cgm_raw_files || '' AS description
FROM
  drh_number_cgm_count;



SELECT
   '% Female' AS title,
   '' || percentage_of_females || '' AS description
FROM
    drh_study_vanity_metrics_details;


SELECT
   'Average Age' AS title,
   '' || average_age || '' AS description
FROM
    drh_study_vanity_metrics_details;




SELECT
'datagrid' AS component;


SELECT
    'Study Description' AS title,
    '' || study_description || '' AS description
FROM
    drh_study_vanity_metrics_details;

    SELECT
    'Study Team' AS title,
    '' || investigators || '' AS description
FROM
    drh_study_vanity_metrics_details;


    SELECT
   'card'     as component,
   '' as title,
    1         as columns;

    SELECT
    'Device Wise Raw CGM File Count' AS title,
    GROUP_CONCAT(' ' || devicename || ': ' || number_of_files || '') AS description
    FROM
        drh_device_file_count_view;

    
    ${paginate("participant_dashboard_cached")}


  
  SELECT 'table' AS component,
        'participant_id' as markdown,
        TRUE AS sort,
        TRUE AS search;        
--   SELECT tenant_id,format('[%s]('||sqlpage.environment_variable('SQLPAGE_SITE_PREFIX') || '/drh/participant-info/index.sql?participant_id='||'%s)',
    SELECT tenant_id,participant_id,gender,age,study_arm,baseline_hba1c,cgm_devices,cgm_files,tir,tar_vh,tar_h,tbr_l,tbr_vl,tar,tbr,gmi,percent_gv,gri,days_of_wear,data_start_date,data_end_date FROM participant_dashboard_cached    
    order by participant_id
${pagination.limit}; 


${pagination.navigation}
;
```


## Researcher and Associated Information

```sql drh/researcher-related-data.sql{ route: { caption: "Researcher and Associated Information" } }
-- @route.description "This section provides detailed information about the individuals , institutions and labs involved in the research study."

SELECT 'text' AS component, $page_title AS title;

SELECT
  'text' as component,
  'The Diabetes Research Hub collaborates with a diverse group of researchers or investigators dedicated to advancing diabetes research. This section provides detailed information about the individuals and institutions involved in the research studies.' as contents;


SELECT
  'text' as component,
  'Researcher / Investigator ' as title;
SELECT
  'These are scientific professionals and medical experts who design and conduct studies related to diabetes management and treatment. Their expertise ranges from clinical research to data analysis, and they are crucial in interpreting results and guiding future research directions.Principal investigators lead the research projects, overseeing the study design, implementation, and data collection. They ensure the research adheres to ethical standards and provides valuable insights into diabetes management.' as contents;
SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
SELECT * from drh_investigator;

SELECT
  'text' as component,
  'Institution' as title;
SELECT
  'The researchers and investigators are associated with various institutions, including universities, research institutes, and hospitals. These institutions provide the necessary resources, facilities, and support for conducting high-quality research. Each institution brings its unique strengths and expertise to the collaborative research efforts.' as contents;
SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
SELECT * from drh_institution;


SELECT
  'text' as component,
  'Lab' as title;
SELECT
  'Within these institutions, specialized labs are equipped with state-of-the-art technology to conduct diabetes research. These labs focus on different aspects of diabetes studies, such as glucose monitoring, metabolic analysis, and data processing. They play a critical role in executing experiments, analyzing samples, and generating data that drive research conclusions.' as contents;
SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
SELECT * from drh_lab;


```


## Study ResearchSite Details

```sql drh/study-related-data.sql{ route: { caption: "Study ResearchSite Details" } }
-- @route.description "This section provides detailed information about the study , and sites involved in the research study."

SELECT 'text' AS component, $page_title AS title;



    SELECT
  'text' as component,
  '
  In Continuous Glucose Monitoring (CGM) research, studies are designed to evaluate the effectiveness, accuracy, and impact of CGM systems on diabetes management. Each study aims to gather comprehensive data on glucose levels, treatment efficacy, and patient outcomes to advance our understanding of diabetes care.

  ### Study Details

  - **Study ID**: A unique identifier assigned to each study.
  - **Study Name**: The name or title of the study.
  - **Start Date**: The date when the study begins.
  - **End Date**: The date when the study concludes.
  - **Treatment Modalities**: Different treatment methods or interventions used in the study.
  - **Funding Source**: The source(s) of financial support for the study.
  - **NCT Number**: ClinicalTrials.gov identifier for the study.
  - **Study Description**: A description of the study’s objectives, methodology, and scope.

  ' as contents_md;

  SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
  SELECT * from drh_study;


      SELECT
          'text' as component,
          '

## Site Information

Research sites are locations where the studies are conducted. They include clinical settings where participants are recruited, monitored, and data is collected.

### Site Details

  - **Study ID**: A unique identifier for the study associated with the site.
  - **Site ID**: A unique identifier for each research site.
  - **Site Name**: The name of the institution or facility where the research is carried out.
  - **Site Type**: The type or category of the site (e.g., hospital, clinic).

      ' as contents_md;

      SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
      SELECT * from drh_site;

```

## Participant Demographics


```sql drh/participant-related-data.sql{ route: { caption: "Participant Demographics" } }
-- @route.description "This section provides detailed information about the the participants involved in the research study."


${paginate("drh_participant")}

  SELECT
      'text' as component,
      '
## Participant Information

Participants are individuals who volunteer to take part in CGM research studies. Their data is crucial for evaluating the performance of CGM systems and their impact on diabetes management.

### Participant Details

  - **Participant ID**: A unique identifier assigned to each participant.
  - **Study ID**: A unique identifier for the study in which the participant is involved.
  - **Site ID**: The identifier for the site where the participant is enrolled.
  - **Diagnosis ICD**: The diagnosis code based on the International Classification of Diseases (ICD) system.
  - **Med RxNorm**: The medication code based on the RxNorm system.
  - **Treatment Modality**: The type of treatment or intervention administered to the participant.
  - **Gender**: The gender of the participant.
  - **Race Ethnicity**: The race and ethnicity of the participant.
  - **Age**: The age of the participant.
  - **BMI**: The Body Mass Index (BMI) of the participant.
  - **Baseline HbA1c**: The baseline Hemoglobin A1c level of the participant.
  - **Diabetes Type**: The type of diabetes diagnosed for the participant.
  - **Study Arm**: The study arm or group to which the participant is assigned.


      ' as contents_md;

    

    -- Display uniform_resource table with pagination
    SELECT 'table' AS component,
          TRUE AS sort,
          TRUE AS search;
    SELECT * FROM drh_participant
    ${pagination.limit}; 


${pagination.navigation}
        ;


```


## Author and Publication Details


```sql drh/author-pub-data.sql{ route: { caption: "Author and Publication Details" } }
-- @route.description "Information about research publications and the authors involved in the studies are also collected, contributing to the broader understanding and dissemination of research findings."


SELECT
  'text' as component,
  '

## Authors

This section contains information about the authors involved in study publications. Each author plays a crucial role in contributing to the research, and their details are important for recognizing their contributions.

### Author Details

- **Author ID**: A unique identifier for the author.
- **Name**: The full name of the author.
- **Email**: The email address of the author.
- **Investigator ID**: A unique identifier for the investigator the author is associated with.
- **Study ID**: A unique identifier for the study associated with the author.


      ' as contents_md;

  SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
  SELECT * from drh_author;
  SELECT
  'text' as component,
  '
## Publications Overview

This section provides information about the publications resulting from a study. Publications are essential for sharing research findings with the broader scientific community.

### Publication Details

- **Publication ID**: A unique identifier for the publication.
- **Publication Title**: The title of the publication.
- **Digital Object Identifier (DOI)**: Identifier for the digital object associated with the publication.
- **Publication Site**: The site or journal where the publication was released.
- **Study ID**: A unique identifier for the study associated with the publication.


  ' as contents_md;

  SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
  SELECT * from drh_publication;

```


## CGM Meta Data and Associated information


```sql drh/cgm-associated-data.sql{ route: { caption: "CGM Meta Data and Associated information" } }
-- @route.description "This section provides detailed information about the CGM device used, the relationship between the participant''s raw CGM tracing file and related metadata, and other pertinent information."

SELECT 'text' AS component, $page_title AS title;

${paginate("drh_cgmfilemetadata_view")}

 SELECT
'text' as component,
'

CGM file metadata provides essential information about the Continuous Glucose Monitoring (CGM) data files used in research studies. This metadata is crucial for understanding the context and quality of the data collected.

### Metadata Details

- **Metadata ID**: A unique identifier for the metadata record.
- **Device Name**: The name of the CGM device used to collect the data.
- **Device ID**: A unique identifier for the CGM device.
- **Source Platform**: The platform or system from which the CGM data originated.
- **Patient ID**: A unique identifier for the patient from whom the data was collected.
- **File Name**: The name of the uploaded CGM data file.
- **File Format**: The format of the uploaded file (e.g., CSV, Excel).
- **File Upload Date**: The date when the file was uploaded to the system.
- **Data Start Date**: The start date of the data period covered by the file.
- **Data End Date**: The end date of the data period covered by the file.
- **Study ID**: A unique identifier for the study associated with the CGM data.


' as contents_md;


-- Display uniform_resource table with pagination
SELECT 'table' AS component,
    TRUE AS sort,
    TRUE AS search;
SELECT * FROM drh_cgmfilemetadata_view
${pagination.limit}; 
${pagination.navigation}
        ;

```


## Raw CGM Data Description

```sql drh/cgm-data.sql{ route: { caption: "Raw CGM Data Description" } }
-- @route.description "Explore detailed information about glucose levels over time, including timestamp, and glucose value."

SELECT 'text' AS component, $page_title AS title;

SELECT
'text' as component,
'
The raw CGM data includes the following key elements.

- **Date_Time**:
The exact date and time when the glucose level was recorded. This is crucial for tracking glucose trends and patterns over time. The timestamp is usually formatted as YYYY-MM-DD HH:MM:SS.
- **CGM_Value**:
The measured glucose level at the given timestamp. This value is typically recorded in milligrams per deciliter (mg/dL) or millimoles per liter (mmol/L) and provides insight into the participant''s glucose fluctuations throughout the day.' as contents_md;

SELECT 'table' AS component,
        'Table' AS markdown,
        'Column Count' as align_right,
        TRUE as sort,
        TRUE as search;
SELECT '[' || table_name || '](cgm-data/raw-cgm/' || table_name || '.sql)' AS "Table"
FROM drh_raw_cgm_table_lst;


```


## Combined CGM Tracing

```sql drh/cgm-combined-data.sql{ route: { caption: "Combined CGM Tracing" } }
-- @route.description "Explore the comprehensive CGM dataset, integrating glucose monitoring data from all participants for in-depth analysis of glycemic patterns and trends across the study."

${paginate("combined_cgm_tracing")}

SELECT
'text' as component,
'

The **Combined CGM Tracing** refers to a consolidated dataset of continuous glucose monitoring (CGM) data, collected from multiple participants in a research study. CGM devices track glucose levels at regular intervals throughout the day, providing detailed insights into the participants'' glycemic control over time.

In a research study, this combined dataset is crucial for analyzing glucose trends across different participants and understanding overall patterns in response to interventions or treatments. The **Combined CGM Tracing** dataset typically includes:
- **Participant ID**: A unique identifier for each participant, ensuring the data is de-identified while allowing for tracking individual responses.
- **Date_Time**: The timestamp for each CGM reading, formatted uniformly to allow accurate time-based analysis.(YYYY-MM-DD HH:MM:SS)
- **CGM_Value**: The recorded glucose level at each time point, often converted to a standard unit (e.g., mg/dL or mmol/L) and stored as a real number for precise calculations.

This combined view enables researchers to perform comparative analyses, evaluate glycemic variability, and assess overall glycemic control across participants, which is essential for understanding the efficacy of treatments or interventions in the study. By aggregating data from multiple sources, researchers can identify population-level trends while maintaining the integrity of individual data. 

' as contents_md;

-- Display uniform_resource table with pagination
SELECT 'table' AS component,
    TRUE AS sort,
    TRUE AS search;
SELECT * FROM combined_cgm_tracing 
${pagination.limit}; 
${pagination.navigation};


```

## PHI De-Identification Results

```sql drh/deidentification-log.sql{ route: { caption: "PHI De-Identification Results" } }
-- @route.description "Explore the results of PHI de-identification and review which columns have been modified."

SELECT
  'text' as component,
  'DeIdentification Results' as title;
 SELECT
  'The DeIdentification Results section provides a view of the outcomes from the de-identification process ' as contents;


SELECT 'table' as component, 1 as search, 1 as sort, 1 as hover, 1 as striped_rows;
SELECT input_text as "deidentified column", orch_started_at,orch_finished_at ,diagnostics_md from drh_vw_orchestration_deidentify;


```