import pandas as pd 
import re
import os
import argparse

# CONFIGURATION
STUDY_ID_PATTERN = r"^[A-Z0-9]{4}$" 
GENERAL_ID_PATTERN = r"^[A-Z0-9][A-Z0-9-]{1,12}[A-Z0-9]$"


def validate(id_str, pattern):
    if not re.match(pattern, id_str):
        raise ValueError(f"ID '{id_str}' fails regex validation.")
    return id_str

def parse_list(raw_data, key):
    val = raw_data.get(key, '')
    return [item.strip() for item in val.split(';') if item.strip()]

def run(input_file, output_dir):
    # Create the output directory if it doesn't exist
    if not os.path.exists(output_dir): 
        os.makedirs(output_dir)

    # Load and parse text
    raw = {}
    if not os.path.exists(input_file):
        print(f"Error: {input_file} not found.")
        return
        
    with open(input_file, 'r') as f:
        for line in f:
            if ":" in line and not line.startswith("-"):
                k, v = line.split(":", 1)
                raw[k.strip()] = v.strip()

    # Dynamic Study ID from file
    sid = validate(raw.get('StudyID', 'CGM1').upper(), STUDY_ID_PATTERN)
    
    # 1. Study.csv
    pd.DataFrame([{
        "study_id": sid, 
        "study_name": raw.get('StudyName'), 
        "start_date": raw.get('StartDate'),
        "end_date": raw.get('EndDate'), 
        "treatment_modalities": raw.get('TreatmentModalities'),
        "funding_source": raw.get('FundingSource'), 
        "nct_number": raw.get('NCTNumber'),
        "study_description": raw.get('StudyDescription')
    }]).to_csv(os.path.join(output_dir, 'study.csv'), index=False, na_rep='')

    # 2. Institution.csv (Multi-increment)
    inst_names = parse_list(raw, 'InstitutionNames')
    cities, states, countries = parse_list(raw, 'Cities'), parse_list(raw, 'States'), parse_list(raw, 'Countries')
    inst_rows = []
    for i, name in enumerate(inst_names):
        iid = validate(f"INST-{i+1:02}", GENERAL_ID_PATTERN)
        inst_rows.append({
            "institution_id": iid, "institution_name": name, 
            "city": cities[i] if i < len(cities) else None,
            "state": states[i] if i < len(states) else None,
            "country": countries[i] if i < len(countries) else None
        })
    inst_df = pd.DataFrame(inst_rows)
    inst_df.to_csv(os.path.join(output_dir, 'institution.csv'), index=False, na_rep='')

    # 3. Investigator.csv (Multi-increment)
    inv_names = parse_list(raw, 'Investigators')
    emails = parse_list(raw, 'InvestigatorEmails')
    inv_rows = []
    for i, name in enumerate(inv_names):
        iid = validate(f"INV-{i+1:02}", GENERAL_ID_PATTERN)
        # Link to corresponding institution or default to first
        inst_link = inst_rows[i]['institution_id'] if i < len(inst_rows) else (inst_rows[0]['institution_id'] if inst_rows else None)
        inv_rows.append({
            "investigator_id": iid, "investigator_name": name, 
            "email": emails[i] if i < len(emails) else None,
            "institution_id": inst_link, "study_id": sid
        })
    inv_df = pd.DataFrame(inv_rows)
    inv_df.to_csv(os.path.join(output_dir, 'investigator.csv'), index=False, na_rep='')

    # 4. Author.csv (Multi-increment + Dynamic Link)
    auth_names = parse_list(raw, 'Authors')
    auth_rows = []
    for i, name in enumerate(auth_names):
        aid = validate(f"AUTH-{i+1:02}", GENERAL_ID_PATTERN)
        # Check if author is an investigator to link IDs
        match = inv_df[inv_df['investigator_name'] == name]
        inv_link = match['investigator_id'].values[0] if not match.empty else None
        auth_rows.append({
            "author_id": aid, "name": name, "email": None, 
            "investigator_id": inv_link, "study_id": sid
        })
    pd.DataFrame(auth_rows).to_csv(os.path.join(output_dir, 'author.csv'), index=False, na_rep='')

    # 5. Lab, 6. Publication, 7. Site (All Multi-increment)
    # Loop for remaining entities to handle multiple entries
    for key, prefix, filename in [
        ('LabNames', 'LAB', 'lab.csv'),
        ('PubTitles', 'PUB', 'publication.csv'),
        ('SiteNames', 'SITE', 'site.csv')
    ]:
        items = parse_list(raw, key)
        rows = []
        for i, val in enumerate(items):
            tid = validate(f"{prefix}-{i+1:02}", GENERAL_ID_PATTERN)
            if prefix == 'LAB':
                rows.append({"lab_id": tid, "lab_name": val, "lab_pi": parse_list(raw, 'LabPIs')[i] if i < len(parse_list(raw, 'LabPIs')) else None, "institution_id": inst_rows[0]['institution_id'], "study_id": sid})
            elif prefix == 'PUB':
                rows.append({"publication_id": tid, "publication_title": val, "digital_object_identifier": parse_list(raw, 'DOIs')[i] if i < len(parse_list(raw, 'DOIs')) else None, "publication_site": parse_list(raw, 'PubSites')[i] if i < len(parse_list(raw, 'PubSites')) else None, "study_id": sid})
            else:
                rows.append({"study_id": sid, "site_id": tid, "site_name": val, "site_type": parse_list(raw, 'SiteTypes')[i] if i < len(parse_list(raw, 'SiteTypes')) else None})
        pd.DataFrame(rows).to_csv(os.path.join(output_dir, filename), index=False, na_rep='')

    print(f"Success! Supporting files generated in: {output_dir}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Convert study-info text to relational CSVs.")
    
    # Adding parameters
    parser.add_argument("input", help="Path to the input text file (e.g., study-info.txt)") # cgmacros-study-info.txt
    parser.add_argument("output", help="Directory where CSV files will be saved")# examples/cgm-macros-supporting-data
    
    args = parser.parse_args()
    
    run(args.input, args.output)