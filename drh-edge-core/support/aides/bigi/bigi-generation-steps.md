# BIGI Data Generation Steps

Use the following commands to generate BIGI supporting files and study content.

## 1) Change into the project subdirectory

```bash
cd drh-edge-core
```

## 2) Generate study supporting files

```bash
python3 support/aides/bigi/generate-study-supporting-files.py \
       support/aides/bigi/bigi-study-info.txt \
       examples/bigi/
```

## 3) Generate BIGI study content

```bash
python3 support/aides/bigi/bigi-content-generator.py \
          --input-folder "examples/raw/bigi" \
          --output-folder "examples/" \
          --study-id "BIGI" \
          --study-name "BIG IDEAs Lab Glycemic Variability and Wearable Device Data" \
          --study-start-date "" \
          --study-end-date "" \
          --treatment-modalities "Continuous Glucose Monitoring (CGM), Wearable Physiological Monitoring, Digital Biomarker Engineering, Standardized Meal Testing, Oral Glucose Tolerance Test (OGTT)" \
          --funding-source "Duke MEDx" \
          --nct-number "" \
          --study-description "Dataset of 16 participants with elevated but non-diabetic glucose levels monitored for 8-10 days using Dexcom G6 CGM and Empatica E4 wearable devices to generate digital biomarkers for glycemic variability and prediabetes risk detection." \
          --timestamp-column "Timestamp (YYYY-MM-DDThh:mm:ss)"
```
