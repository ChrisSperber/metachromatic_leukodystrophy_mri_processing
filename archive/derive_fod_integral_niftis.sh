#!/usr/bin/env bash
set -euo pipefail

# Create a 3D WM FOD integral map for every session in the inventory.
# The first spherical-harmonic coefficient (c00) is multiplied by sqrt(4*pi).
# Outputs remain in native diffusion space; no registration is required.

DATA_MASTER_DIR="${DATA_MASTER_DIR:-/home/chris/projects/mld_data_master_2026}"
INVENTORY="${INVENTORY:-$DATA_MASTER_DIR/imaging_file_manifest.csv}"
DIFFUSION_DIR="${DIFFUSION_DIR:-$DATA_MASTER_DIR/derivatives/diffusion}"
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
FOD_INTEGRAL_SCALE="3.544907701811032"  # sqrt(4*pi), for orthonormal real SH

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$INVENTORY" ]] || fail "Inventory not found: $INVENTORY"
command -v python3 >/dev/null 2>&1 || fail 'python3 not found'
command -v conda >/dev/null 2>&1 || fail 'conda not found'
conda run -n "$MRTRIX_CONDA_ENV" mrconvert -help >/dev/null 2>&1 || \
    fail "mrconvert unavailable in Conda environment: $MRTRIX_CONDA_ENV"
conda run -n "$MRTRIX_CONDA_ENV" mrcalc -help >/dev/null 2>&1 || \
    fail "mrcalc unavailable in Conda environment: $MRTRIX_CONDA_ENV"

# A temporary directory for the inventory and intermediate coefficient image.
TEMP_DIR="$(mktemp -d "$DATA_MASTER_DIR/derivatives/.fod_integral_tmp.XXXXXX")"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

# Python's CSV parser handles quotes; write Unix line endings for Bash.
python3 - "$INVENTORY" "$TEMP_DIR/sessions.tsv" <<'PY'
import csv
import sys

source, destination = sys.argv[1:]
with open(source, newline="", encoding="utf-8-sig") as src:
    reader = csv.DictReader(src)
    required = {"SubjectID", "SessionID"}
    if not required.issubset(reader.fieldnames or []):
        raise SystemExit("Inventory lacks SubjectID and/or SessionID")
    seen = set()
    with open(destination, "w", encoding="utf-8", newline="\n") as dst:
        for row in reader:
            subject = row["SubjectID"].strip()
            session = row["SessionID"].strip()
            if not subject or not session or any(c in subject + session for c in "\t\r\n/"):
                raise SystemExit(f"Invalid subject/session: {subject!r}, {session!r}")
            if (subject, session) in seen:
                raise SystemExit(f"Duplicate session: {subject}, {session}")
            seen.add((subject, session))
            dst.write(f"{subject}\t{session}\n")
print(f"Validated {len(seen)} inventory sessions.")
PY

processed=0
skipped=0
missing=0
failed=0

while IFS=$'\t' read -r subject session; do
    fod_dir="$DIFFUSION_DIR/sub-${subject}/ses-${session}/fod"
    input="$fod_dir/FOD_wm_norm.mif"
    output="$fod_dir/FOD_wm_integral.nii.gz"
    stem="sub-${subject}_ses-${session}"

    if [[ -s "$output" ]]; then
        printf 'SKIP (exists): %s\n' "$stem"
        ((skipped += 1))
        continue
    fi
    if [[ ! -s "$input" ]]; then
        printf 'MISSING FOD: %s (%s)\n' "$stem" "$input" >&2
        ((missing += 1))
        continue
    fi

    printf 'Processing: %s\n' "$stem"
    coefficient="$TEMP_DIR/c00.mif"
    partial="$TEMP_DIR/integral.nii.gz"
    rm -f -- "$coefficient" "$partial"

    if conda run -n "$MRTRIX_CONDA_ENV" mrconvert "$input" "$coefficient" \
        -coord 3 0 -axes 0,1,2 && \
       conda run -n "$MRTRIX_CONDA_ENV" mrcalc "$coefficient" \
        "$FOD_INTEGRAL_SCALE" -mult "$partial" && [[ -s "$partial" ]]; then
        mv -- "$partial" "$output"
        ((processed += 1))
    else
        printf 'FAILED: %s\n' "$stem" >&2
        ((failed += 1))
    fi
done < "$TEMP_DIR/sessions.tsv"

printf '\nSummary: processed=%d skipped=%d missing=%d failed=%d\n' \
    "$processed" "$skipped" "$missing" "$failed"

if ((missing > 0 || failed > 0)); then
    exit 1
fi
