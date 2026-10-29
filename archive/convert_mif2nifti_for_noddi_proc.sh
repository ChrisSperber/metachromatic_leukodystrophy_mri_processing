#!/usr/bin/env bash
set -euo pipefail

# Activate MRtrix Conda environment
eval "$(conda shell.bash hook)"
conda activate mrtrix3

DATA_MASTER_DIR="/home/chris/projects/mld_data_master_2026"
INVENTORY="$DATA_MASTER_DIR/imaging_file_manifest.csv"
OUTPUT_DIR="$DATA_MASTER_DIR/derivatives/noddi_temp"

# Read inventory using Python to handle CSV quoting correctly.
read_inventory() {
    python3 - "$INVENTORY" <<'PY'
import csv
import sys

with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f):
        if row.get("Excluded", "").strip().lower() in ("true", "1", "yes"):
            continue

        print("\t".join([
            row["SubjectID"],
            row["SessionID"],
            row.get("PathDWIMIF", ""),
            row.get("PathMaskMIF", ""),
        ]))
PY
}

count=0
skipped=0

while IFS=$'\t' read -r subject session dwi mask; do
    # Paths in the inventory are relative to DATA_MASTER_DIR.
    if [[ -z "$dwi" || -z "$mask" ||
          ! -f "$DATA_MASTER_DIR/$dwi" ||
          ! -f "$DATA_MASTER_DIR/$mask" ]]; then
        echo "SKIP: $subject/$session (missing DWI or mask)"
        ((skipped+=1))
        continue
    fi

    target="$OUTPUT_DIR/sub-$subject/ses-$session/dwi"
    mkdir -p "$target"

    echo "Converting: $subject/$session"

    mrconvert "$DATA_MASTER_DIR/$dwi" "$target/dwi.nii.gz" \
        -export_grad_fsl "$target/dwi.bvec" "$target/dwi.bval" \
        -force

    mrconvert "$DATA_MASTER_DIR/$mask" "$target/mask.nii.gz" \
        -force

    ((count+=1))

done < <(read_inventory)

echo "Finished: $count converted, $skipped skipped."
