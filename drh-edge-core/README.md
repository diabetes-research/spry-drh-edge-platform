
# Spry DRH EDGE Data Exploration Example

This SQLPage exemplar automates the conversion of study data files uploaded by the end user (following the prescribed folder structure) from the
[official DRH Website](https://drh.diabetestechnology.org/organize-cgm-data)
into a structured SQLite database and presents the content through a drill-down HTML web application.

## Instructions

1. **Prepare and upload the study data**
   - Prepare and upload study data as described [here](https://drh.diabetestechnology.org/organize-cgm-data).
   - Ensure the surveilr version (example 3.3.0)

2. **Run the Shell script**
   Execute the Shell script(performs complex ETL) described in [`Spryfile.md`](Spryfile.md):

   ```bash
   ./spry.ts task prepare-db
   ```

3. **Build the SQLPage notebook and populate the database**
   Generate the SQLPage notebook from `Spryfile.md` and load it into the database to create entries in the `sqlpage_files` table:

   ```bash
   ./spry.ts spc --fs dev-src.auto --destroy-first --conf sqlpage/sqlpage.json 
   
   ```

   The `./spry.ts spc` command (Spry SQLPage Content) packages SQLPage content.
   For more information, run:

   ```bash
   ./spry.ts help spc
   ```

4. **Start the SQLPage server**

   ```bash
   SQLPAGE_SITE_PREFIX="" sqlpage
   ```

---
