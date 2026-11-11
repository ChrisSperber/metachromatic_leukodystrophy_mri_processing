#!/usr/bin/env bash
# Warp binary tract masks from FOD template space into each subject's native DWI space.
# Adapted from scripts/fod_processing/j_move_tract_masks2subject_space.sh.
# Only subjects with a saved, QC-accepted template2subject warp are processed.
set -euo pipefail

# -----------------------------
# USER SETTINGS
# -----------------------------
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"
KEEP_INTERMEDIATES="${KEEP_INTERMEDIATES:-0}"

# -----------------------------
# PATHS
# -----------------------------
DATA_MASTER_DIR="${DATA_MASTER_DIR:-/home/chris/projects/mld_data_master_2026}"
DERIVATIVES_DIR="$DATA_MASTER_DIR/derivatives"
WARP_DIR="$DERIVATIVES_DIR/fod_registration/warps"
TRACT_ROOT="$DERIVATIVES_DIR/fod_tracts_template"
DIFFUSION_DIR="$DERIVATIVES_DIR/diffusion"
INVENTORY="$DATA_MASTER_DIR/imaging_file_manifest.csv"

printf 'Data master        : %s\n' "$DATA_MASTER_DIR"
printf 'Warp dir           : %s\n' "$WARP_DIR"
printf 'Template tract dir : %s\n' "$TRACT_ROOT"
printf 'Diffusion dir      : %s\n' "$DIFFUSION_DIR"
printf 'Inventory          : %s\n' "$INVENTORY"
printf 'Conda env          : %s (USE_CONDA_RUN=%s)\n' "$MRTRIX_CONDA_ENV" "$USE_CONDA_RUN"
printf 'Threads            : %s\n' "$MRTRIX_NTHREADS"
printf 'Keep intermediates : %s\n\n' "$KEEP_INTERMEDIATES"

# -----------------------------
# TOOL CHECKS / RUNNER
# -----------------------------
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Required tool '$1' not found in PATH" >&2
        exit 1
    }
}

mrtrix() {
    if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" == "1" ]]; then
        conda run -n "$MRTRIX_CONDA_ENV" "$@"
    else
        "$@"
    fi
}

if [[ -n "$MRTRIX_CONDA_ENV" ]]; then
    need_cmd conda
fi
need_cmd basename
need_cmd find
need_cmd mkdir
need_cmd rm
need_cmd sort

if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" != "1" ]]; then
    eval "$(conda shell.bash hook)"
    conda activate "$MRTRIX_CONDA_ENV"
fi

if [[ "$USE_CONDA_RUN" == "1" ]]; then
    mrtrix mrtransform -help >/dev/null 2>&1 || {
        echo "mrtransform not runnable via conda run" >&2
        exit 1
    }
    mrtrix mrconvert -help >/dev/null 2>&1 || {
        echo "mrconvert not runnable via conda run" >&2
        exit 1
    }
    mrtrix mrcalc -help >/dev/null 2>&1 || {
        echo "mrcalc not runnable via conda run" >&2
        exit 1
    }
else
    need_cmd mrtransform
    need_cmd mrconvert
    need_cmd mrcalc
fi
export MRTRIX_NTHREADS

# -----------------------------
# INPUT CHECKS
# -----------------------------
need_dir() {
    [[ -d "$1" ]] || {
        echo "Required directory not found: $1" >&2
        exit 1
    }
}

need_file() {
    [[ -f "$1" ]] || {
        echo "Required file not found: $1" >&2
        exit 1
    }
}

need_dir "$WARP_DIR"
need_dir "$TRACT_ROOT"
need_dir "$DIFFUSION_DIR"
need_file "$INVENTORY"
need_cmd python3

# -----------------------------
# HELPERS
# -----------------------------
extract_subject_base_from_warp() {
    local base
    base="$(basename "$1")"
    base="${base%_template2subject.mif}"
    printf '%s\n' "$base"
}

find_template_mask() {
    local tract_dir="$1"
    local tract_name mask_path
    tract_name="$(basename "$tract_dir")"
    mask_path="$tract_dir/${tract_name}_mask.nii.gz"

    [[ -f "$mask_path" ]] || {
        echo "ERROR: expected tract mask not found: $mask_path" >&2
        return 1
    }
    printf '%s\n' "$mask_path"
}

warp_one_mask() {
    local template_mask_nii="$1"
    local tpl2subj_warp="$2"
    local subject_template="$3"
    local out_mask_nii="$4"
    local tmp_dir="$5"

    local warped_mif="$tmp_dir/warped_mask.mif"
    local binary_mif="$tmp_dir/binary_mask.mif"

    mrtrix mrtransform \
        "$template_mask_nii" \
        "$warped_mif" \
        -warp "$tpl2subj_warp" \
        -template "$subject_template" \
        -interp nearest \
        -force

    # Re-binarise exactly as in the original script.
    mrtrix mrcalc "$warped_mif" 0 -gt "$binary_mif" -force

    mrtrix mrconvert \
        "$binary_mif" \
        "$out_mask_nii" \
        -datatype uint8 \
        -force
}

# -----------------------------
# RESOLVE NATIVE MASKS FROM INVENTORY
# -----------------------------
# Use PathMaskMIF rather than assuming a particular DWI mask filename.
# Write an intermediate TSV with Unix line endings to avoid the CRLF issue
# encountered earlier in this pipeline.
inventory_tsv="$(mktemp)"
trap 'rm -f "$inventory_tsv"' EXIT

python3 - "$INVENTORY" "$DATA_MASTER_DIR" "$inventory_tsv" <<'PY_INVENTORY'
import csv
import sys
from pathlib import Path

inventory, data_root, output = sys.argv[1:]
data_root = Path(data_root)
seen = set()

with open(inventory, newline="", encoding="utf-8-sig") as f, open(
    output, "w", newline="", encoding="utf-8"
) as out:
    reader = csv.DictReader(f)
    required = {"SubjectID", "SessionID", "PathMaskMIF"}
    missing = required - set(reader.fieldnames or [])
    if missing:
        raise SystemExit(f"Missing inventory columns: {sorted(missing)}")

    writer = csv.writer(out, delimiter="\t", lineterminator="\n")
    for row in reader:
        subject = (row.get("SubjectID") or "").strip()
        session = (row.get("SessionID") or "").strip()
        stem = f"sub-{subject}_ses-{session}"
        if not subject or not session or stem in seen:
            raise SystemExit(f"Missing or duplicate SubjectID/SessionID: {stem}")
        seen.add(stem)
        mask_text = (row.get("PathMaskMIF") or "").strip()
        if not mask_text:
            raise SystemExit(f"Missing PathMaskMIF for {stem}")
        mask = Path(mask_text)
        if not mask.is_absolute():
            mask = data_root / mask
        writer.writerow((stem, str(mask)))
PY_INVENTORY

declare -A mask_by_stem=()
while IFS=$'\t' read -r stem mask_path; do
    mask_by_stem["$stem"]="$mask_path"
done < "$inventory_tsv"

# -----------------------------
# COLLECT INPUTS
# -----------------------------
mapfile -t warp_files < <(find "$WARP_DIR" -maxdepth 1 -type f -name 'sub-*_ses-*_template2subject.mif' | sort)
if [[ "${#warp_files[@]}" -eq 0 ]]; then
    echo "ERROR: no template2subject warp files found in $WARP_DIR" >&2
    exit 1
fi

mapfile -t tract_dirs < <(find "$TRACT_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
if [[ "${#tract_dirs[@]}" -eq 0 ]]; then
    echo "ERROR: no tract folders found in $TRACT_ROOT" >&2
    exit 1
fi

echo "Found ${#warp_files[@]} inverse warp files."
echo "Found ${#tract_dirs[@]} tract folders."
echo

# -----------------------------
# MAIN LOOP
# -----------------------------
for tpl2subj_warp in "${warp_files[@]}"; do
    subject_base="$(extract_subject_base_from_warp "$tpl2subj_warp")"
    subject_id="${subject_base%%_ses-*}"
    session_id="ses-${subject_base#*_ses-}"

    subject_dir="$DIFFUSION_DIR/$subject_id/$session_id"
    output_dir="$subject_dir/tract_masks"
    tmp_dir="$output_dir/tmp"
    subject_mask="${mask_by_stem[$subject_base]:-}"
    [[ -n "$subject_mask" ]] || {
        echo "ERROR: no inventory entry for $subject_base" >&2
        exit 1
    }

    echo "=== ${subject_base} ==="
    echo "  warp         : $tpl2subj_warp"
    echo "  native grid  : $subject_mask"
    echo "  output dir   : $output_dir"
    need_file "$subject_mask"

    mkdir -p "$output_dir" "$tmp_dir"

    for tract_dir in "${tract_dirs[@]}"; do
        tract_name="$(basename "$tract_dir")"
        template_mask="$(find_template_mask "$tract_dir")"
        out_mask="$output_dir/${tract_name}_mask.nii.gz"
        tract_tmp_dir="$tmp_dir/$tract_name"

        mkdir -p "$tract_tmp_dir"

        echo "  -> ${tract_name}"
        echo "     template mask : $template_mask"
        echo "     output mask   : $out_mask"
        warp_one_mask \
            "$template_mask" \
            "$tpl2subj_warp" \
            "$subject_mask" \
            "$out_mask" \
            "$tract_tmp_dir"
    done

    if [[ "$KEEP_INTERMEDIATES" != "1" ]]; then
        rm -rf "$tmp_dir"
    fi
    echo
done

echo "Done."
