#!/usr/bin/env python3
"""
generate-study-supporting-files.py  (CGMND edition)
====================================================
Reads cgmnd-study-info.txt and emits a set of relational CSV files that
populate the DRH schema for the CGMND study:

    study.csv
    institution.csv
    investigator.csv
    author.csv
    lab.csv
    site.csv
    publication.csv

The study-info file uses a *multi-block* format: the same key (e.g.
InstitutionNames, LabNames, SiteNames) appears repeatedly — once per
entity — with its companion keys immediately beneath it.  Sections are
delimited by lines that start with "---".

Usage
-----
python3 support/aides/cgmnd/generate-study-supporting-files.py \\
    support/aides/cgmnd/cgmnd-study-info.txt \\
    examples/cgmnd-supporting-data

python3 : 3.8+
Deps    : pandas (all others are stdlib)
"""

import os
import re
import sys
import argparse
from typing import Dict, List, Optional, Tuple

import pandas as pd

# ---------------------------------------------------------------------------
# ID validation patterns
# ---------------------------------------------------------------------------
_STUDY_ID_RE   = re.compile(r"^[A-Z0-9]{4,6}$")
_GENERAL_ID_RE = re.compile(r"^[A-Z0-9][A-Z0-9\-]{1,12}[A-Z0-9]$")


def _validate_study_id(sid: str) -> str:
    if not _STUDY_ID_RE.match(sid):
        print(f"[ERROR] StudyID '{sid}' must match ^[A-Z0-9]{{4,6}}$.")
        sys.exit(1)
    return sid


def _validate_id(value: str, label: str) -> str:
    if not _GENERAL_ID_RE.match(value):
        print(f"[ERROR] ID '{value}' ({label}) must match ^[A-Z0-9][A-Z0-9-]{{1,12}}[A-Z0-9]$.")
        sys.exit(1)
    return value


# ---------------------------------------------------------------------------
# Study-info file parser
# ---------------------------------------------------------------------------

def _is_section_header(line: str) -> bool:
    """Return True for lines like '--- STUDY DATA ---' or '---- INSTITUTIONS ---'."""
    stripped = line.strip()
    return stripped.startswith("---") or stripped.startswith("#")


def parse_study_info(path: str) -> Tuple[Dict[str, str], List[Dict[str, str]]]:
    """
    Parse the cgmnd-study-info.txt file.

    Returns
    -------
    header : dict
        Single-value fields (StudyID, StudyName, …, Investigators, Authors,
        PubTitles, DOIs, PubSites).
    blocks : list of dict
        Every repeated-key block (InstitutionNames, LabNames/SiteNames).
        Each dict also contains a ``_block_key`` entry with the trigger key
        that opened the block.
    """
    if not os.path.exists(path):
        print(f"[ERROR] File not found: {path}")
        sys.exit(1)

    # Keys that start a new multi-block entity
    BLOCK_TRIGGERS = {"InstitutionNames", "LabNames", "PubTitles"}

    header: Dict[str, str] = {}
    blocks: List[Dict[str, str]] = []

    current_block: Optional[Dict[str, str]] = None

    with open(path, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.rstrip("\n")

            # Section header: flush current block and reset to header mode
            if _is_section_header(line):
                if current_block is not None:
                    blocks.append(current_block)
                    current_block = None
                continue

            # Skip blank lines
            if not line.strip():
                continue

            # Must be a "Key: value" line
            if ":" not in line:
                continue

            key, _, val = line.partition(":")
            key = key.strip()
            val = val.strip()

            if key in BLOCK_TRIGGERS:
                # Save previous block (if any)
                if current_block is not None:
                    blocks.append(current_block)
                # Start a fresh block
                current_block = {"_block_key": key, key: val}
            elif current_block is not None:
                # Companion key belonging to the current block
                current_block[key] = val
            else:
                # Top-level singleton field
                header[key] = val

        # Flush the final block
        if current_block is not None:
            blocks.append(current_block)

    return header, blocks


def _split_semi(value: str) -> List[str]:
    """Split a semicolon-delimited string, stripping whitespace, dropping empties."""
    return [v.strip() for v in value.split(";") if v.strip()]


def _split_comma(value: str) -> List[str]:
    """Split a comma-delimited string, stripping whitespace, dropping empties."""
    return [v.strip() for v in value.split(",") if v.strip()]


# ---------------------------------------------------------------------------
# CSV generators
# ---------------------------------------------------------------------------

def _write_study(header: Dict[str, str], sid: str, output_dir: str) -> None:
    row = {
        "study_id":             sid,
        "study_name":           header.get("StudyName", ""),
        "start_date":           header.get("StartDate", ""),
        "end_date":             header.get("EndDate", ""),
        "treatment_modalities": header.get("TreatmentModalities", ""),
        "funding_source":       header.get("FundingSource", ""),
        "nct_number":           header.get("NCTNumber", ""),
        "study_description":    header.get("StudyDescription", ""),
    }
    _save(pd.DataFrame([row]), output_dir, "study.csv")


def _write_institutions(blocks: List[Dict], output_dir: str) -> List[Dict]:
    """Return list of institution dicts (needed for downstream linking)."""
    inst_blocks = [b for b in blocks if b["_block_key"] == "InstitutionNames"]
    rows = []
    for i, b in enumerate(inst_blocks):
        iid = _validate_id(f"INST-{i + 1:02d}", "institution_id")
        rows.append({
            "institution_id":   iid,
            "institution_name": b.get("InstitutionNames", ""),
            "city":             b.get("Cities", ""),
            "state":            b.get("States", ""),
            "country":          b.get("Countries", "").rstrip(";").strip(),
        })
    _save(pd.DataFrame(rows), output_dir, "institution.csv")
    return rows


def _write_investigators(header: Dict, sid: str, inst_rows: List[Dict], output_dir: str) -> List[Dict]:
    names  = _split_semi(header.get("Investigators", ""))
    emails = _split_semi(header.get("InvestigatorEmails", ""))
    rows = []
    for i, name in enumerate(names):
        iid = _validate_id(f"INV-{i + 1:02d}", "investigator_id")
        # Link first investigator to first institution, rest to None (unknown site)
        inst_link = inst_rows[0]["institution_id"] if inst_rows else ""
        rows.append({
            "investigator_id":   iid,
            "investigator_name": name,
            "email":             emails[i] if i < len(emails) else "",
            "institution_id":    inst_link,
            "study_id":          sid,
        })
    _save(pd.DataFrame(rows), output_dir, "investigator.csv")
    return rows


def _write_authors(header: Dict, sid: str, inv_rows: List[Dict], output_dir: str) -> None:
    names = _split_semi(header.get("Authors", ""))
    # Build a lookup: investigator_name → investigator_id
    inv_lookup = {r["investigator_name"]: r["investigator_id"] for r in inv_rows}
    rows = []
    for i, name in enumerate(names):
        aid = _validate_id(f"AUTH-{i + 1:02d}", "author_id")
        rows.append({
            "author_id":      aid,
            "name":           name,
            "email":          "",
            "investigator_id": inv_lookup.get(name, ""),
            "study_id":        sid,
        })
    _save(pd.DataFrame(rows), output_dir, "author.csv")


def _write_labs_and_sites(blocks: List[Dict], sid: str, inst_rows: List[Dict], output_dir: str) -> None:
    lab_blocks = [b for b in blocks if b["_block_key"] == "LabNames"]
    lab_rows  = []
    site_rows = []

    for i, b in enumerate(lab_blocks):
        lab_id  = _validate_id(f"LAB-{i + 1:02d}", "lab_id")
        site_id = _validate_id(f"SITE-{i + 1:02d}", "site_id")

        # Attempt to match institution by name (fuzzy substring match)
        inst_id = inst_rows[0]["institution_id"] if inst_rows else ""
        lab_name = b.get("LabNames", "")
        for ir in inst_rows:
            if any(part.strip().lower() in ir["institution_name"].lower()
                   for part in lab_name.split("/") if len(part.strip()) > 4):
                inst_id = ir["institution_id"]
                break

        lab_rows.append({
            "lab_id":         lab_id,
            "lab_name":       lab_name,
            "lab_pi":         b.get("LabPIs", ""),
            "institution_id": inst_id,
            "study_id":       sid,
        })

        site_rows.append({
            "study_id":   sid,
            "site_id":    site_id,
            "site_name":  b.get("SiteNames", ""),
            "site_type":  b.get("SiteTypes", "").rstrip(";").strip(),
        })

    _save(pd.DataFrame(lab_rows),  output_dir, "lab.csv")
    _save(pd.DataFrame(site_rows), output_dir, "site.csv")


def _write_publications(blocks: List[Dict], sid: str, output_dir: str) -> None:
    pub_blocks = [b for b in blocks if b["_block_key"] == "PubTitles"]
    rows = []
    pub_counter = 0
    for b in pub_blocks:
        titles  = _split_comma(b.get("PubTitles", ""))   or [b.get("PubTitles", "")]
        dois    = _split_comma(b.get("DOIs", ""))
        sites   = _split_comma(b.get("PubSites", ""))

        # One row per (title / DOI / site) combination; if only one title, fan out by DOI
        if len(titles) == 1:
            title = titles[0]
            # Fan out across DOIs
            for j in range(max(len(dois), 1)):
                pub_counter += 1
                pid = _validate_id(f"PUB-{pub_counter:02d}", "publication_id")
                rows.append({
                    "publication_id":          pid,
                    "publication_title":        title,
                    "digital_object_identifier": dois[j] if j < len(dois) else "",
                    "publication_site":          sites[j] if j < len(sites) else "",
                    "study_id":                  sid,
                })
        else:
            for j, title in enumerate(titles):
                pub_counter += 1
                pid = _validate_id(f"PUB-{pub_counter:02d}", "publication_id")
                rows.append({
                    "publication_id":          pid,
                    "publication_title":        title,
                    "digital_object_identifier": dois[j] if j < len(dois) else "",
                    "publication_site":          sites[j] if j < len(sites) else "",
                    "study_id":                  sid,
                })
    _save(pd.DataFrame(rows), output_dir, "publication.csv")


def _save(df: pd.DataFrame, output_dir: str, filename: str) -> None:
    path = os.path.join(output_dir, filename)
    df.to_csv(path, index=False, na_rep="")
    print(f"  ✓  {filename:30s} ({len(df)} row{'s' if len(df) != 1 else ''})")


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def run(input_file: str, output_dir: str) -> None:
    os.makedirs(output_dir, exist_ok=True)

    print(f"\nParsing  : {input_file}")
    header, blocks = parse_study_info(input_file)

    sid = _validate_study_id(header.get("StudyID", "CGMN").upper())
    print(f"StudyID  : {sid}")
    print(f"Blocks   : {len(blocks)} entity block(s) detected\n")

    print("Generating CSVs …")
    _write_study(header, sid, output_dir)
    inst_rows = _write_institutions(blocks, output_dir)
    inv_rows  = _write_investigators(header, sid, inst_rows, output_dir)
    _write_authors(header, sid, inv_rows, output_dir)
    _write_labs_and_sites(blocks, sid, inst_rows, output_dir)
    _write_publications(blocks, sid, output_dir)

    print(f"\nSuccess! All supporting files written to: {output_dir}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Convert cgmnd-study-info.txt to relational DRH CSVs (CGMND edition).",
    )
    parser.add_argument(
        "input",
        help="Path to the study-info text file (e.g. cgmnd-study-info.txt)",
    )
    parser.add_argument(
        "output",
        help="Directory where CSV files will be saved (created if absent)",
    )
    args = parser.parse_args()
    run(args.input, args.output)