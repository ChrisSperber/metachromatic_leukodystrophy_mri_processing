#!/usr/bin/env bash
# Generate TractSeg-compatible peak maps from existing WM FOD + DWI mask listed in a TSV.
# Outputs are written into PROJECT_DIR/temp_images/Peak_images with a stable naming scheme:
#   subject_<ID>_date_<DATETAG>_peaks.nii.gz
#
# TSV is expected to contain (at least) these tab-separated columns (header row required):
#   Subject_ID  Date_Tag  DTI_Method  ...  MIF_PATH  DWI_MASK
#
# The script will:
#   - read MIF_PATH (WM FOD, e.g. *_FOD_wm_norm.mif) and DWI_MASK (e.g. *_dwi_mask.mif)
#   - run sh2peaks with -mask
#
# Notes:
#   - We explicitly export peaks to NIfTI (.nii.gz) to match common TractSeg usage.
#   - If .mif peaks are preferred, set PEAKS_AS_MIF=1.

set -euo pipefail

# -----------------------------
# USER SETTINGS
# -----------------------------
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"

# Output format:
#   0 -> write peaks as NIfTI (.nii.gz)  [default]
#   1 -> write peaks as .mif
PEAKS_AS_MIF="${PEAKS_AS_MIF:-0}"

# Cleanup switches
# DELETE_EXISTING_BAD_OUTPUTS:
#   1 -> if peaks exist but are empty/corrupt, delete and regenerate
#   0 -> leave as-is (default)
DELETE_EXISTING_BAD_OUTPUTS="${DELETE_EXISTING_BAD_OUTPUTS:-0}"

# -----------------------------
# PATHS
# -----------------------------
script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"
SRC_DIR="$PROJECT_DIR/temp_images"

# New folder alongside FOD_images:
OUT_DIR="$SRC_DIR/peak_images"

TSV_PATH="$script_dir/a_collect_dwi_files.tsv"
if [[ ! -f "$TSV_PATH" ]]; then
    echo "TSV not found: $TSV_PATH" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

FAIL_LOG="$OUT_DIR/peaks_failures.tsv"
if [[ ! -f "$FAIL_LOG" ]]; then
    echo -e "Subject_ID\tDate_Tag\tDTI_Method\tWM_FOD_Path\tMask_Path\tReason" > "$FAIL_LOG"
fi

QC_LOG="$OUT_DIR/peaks_qc.tsv"
if [[ ! -f "$QC_LOG" ]]; then
    echo -e "Subject_ID\tDate_Tag\tDTI_Method\tPeaks_Path\tStatus" > "$QC_LOG"
fi

echo "Project dir : $PROJECT_DIR"
echo "TSV         : $TSV_PATH"
echo "Output dir  : $OUT_DIR"
echo "Conda env   : ${MRTRIX_CONDA_ENV} (USE_CONDA_RUN=${USE_CONDA_RUN})"
echo "PEAKS_AS_MIF=${PEAKS_AS_MIF}"
echo "DELETE_EXISTING_BAD_OUTPUTS=${DELETE_EXISTING_BAD_OUTPUTS}"
echo

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
    if [[ -n "$MRTRIX_CONDA_ENV" ]]; then
        if [[ "$USE_CONDA_RUN" == "1" ]]; then
            conda run -n "$MRTRIX_CONDA_ENV" "$@"
        else
            "$@"
        fi
    else
        "$@"
    fi
}

if [[ -n "$MRTRIX_CONDA_ENV" ]]; then
    need_cmd conda
fi

if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" != "1" ]]; then
    # shellcheck disable=SC1091
    eval "$(conda shell.bash hook)"
    conda activate "$MRTRIX_CONDA_ENV"
fi

# MRtrix command availability checks
if [[ "$USE_CONDA_RUN" == "1" ]]; then
    mrtrix sh2peaks -help >/dev/null 2>&1 || { echo "sh2peaks not runnable via conda run" >&2; exit 1; }
    mrtrix mrinfo -help >/dev/null 2>&1 || { echo "mrinfo not runnable via conda run" >&2; exit 1; }
else
    need_cmd sh2peaks
    need_cmd mrinfo
fi

# -----------------------------
# HELPERS
# -----------------------------
# Check whether an MRtrix-readable image is valid (quickly).
is_mrtrix_readable() {
    local path="$1"
    mrtrix mrinfo "$path" >/dev/null 2>&1
}

# -----------------------------
# MAIN LOOP
# TSV columns (your current manifest includes these, plus others):
# Subject_ID  Date_Tag  DTI_Method  DWI_Path  BVAL_Path  BVEC_Path  BVALS  MIF_PATH  DWI_MASK
# We only use: Subject_ID, Date_Tag, DTI_Method, MIF_PATH, DWI_MASK
# -----------------------------
echo "Starting TSV processing..."

tail -n +2 "$TSV_PATH" | sed 's/\r$//' | while IFS=$'\t' read -r subject_id date_tag dti_method _ _ _ _ mif_path dwi_mask_path; do
    [[ -z "${subject_id:-}" ]] && continue
    [[ -z "${date_tag:-}" ]] && continue

    base="subject_${subject_id}_date_${date_tag}"

    if [[ "$PEAKS_AS_MIF" == "1" ]]; then
        peaks_out="$OUT_DIR/${base}_peaks.mif"
    else
        peaks_out="$OUT_DIR/${base}_peaks.nii.gz"
    fi

    echo "=== ${base}  (DTI_Method=${dti_method}) ==="
    echo "  WM FOD : $mif_path"
    echo "  Mask   : $dwi_mask_path"
    echo "  Peaks  : $peaks_out"

    # existence checks
    if [[ -z "${mif_path:-}" || ! -f "$mif_path" ]]; then
        echo "  WARNING: missing WM FOD -> skipping" >&2
        echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${mif_path:-NA}\t${dwi_mask_path:-NA}\tMISSING_WM_FOD" >> "$FAIL_LOG"
        echo
        continue
    fi
    if [[ -z "${dwi_mask_path:-}" || ! -f "$dwi_mask_path" ]]; then
        echo "  WARNING: missing mask -> skipping" >&2
        echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${mif_path}\t${dwi_mask_path:-NA}\tMISSING_MASK" >> "$FAIL_LOG"
        echo
        continue
    fi

    # basic readability checks
    if ! is_mrtrix_readable "$mif_path"; then
        echo "  ERROR: WM FOD not readable by MRtrix -> skipping" >&2
        echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${mif_path}\t${dwi_mask_path}\tWM_FOD_NOT_READABLE" >> "$FAIL_LOG"
        echo
        continue
    fi
    if ! is_mrtrix_readable "$dwi_mask_path"; then
        echo "  ERROR: mask not readable by MRtrix -> skipping" >&2
        echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${mif_path}\t${dwi_mask_path}\tMASK_NOT_READABLE" >> "$FAIL_LOG"
        echo
        continue
    fi

    # skip if final product exists
    if [[ -s "$peaks_out" ]]; then
        echo "  Peaks exist, skipping subject."
        echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${peaks_out}\tEXISTS" >> "$QC_LOG"
        echo
        continue
    fi

    # if output exists but is empty and you want regeneration
    if [[ -e "$peaks_out" && ! -s "$peaks_out" && "$DELETE_EXISTING_BAD_OUTPUTS" == "1" ]]; then
        echo "  Removing empty peaks output for regeneration..."
        rm -f "$peaks_out"
    fi

    # (1) Create peaks
    echo "  Creating peaks (sh2peaks)..."
    if ! mrtrix sh2peaks "$mif_path" "$peaks_out" -mask "$dwi_mask_path" -force; then
        echo "  ERROR: sh2peaks failed -> skipping" >&2
        echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${mif_path}\t${dwi_mask_path}\tSH2PEAKS_FAILED" >> "$FAIL_LOG"
        echo
        continue
    fi

    # sanity: ensure output exists and is readable
    if [[ ! -s "$peaks_out" ]]; then
        echo "  ERROR: peaks output missing/empty after sh2peaks" >&2
        echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${mif_path}\t${dwi_mask_path}\tPEAKS_MISSING_OR_EMPTY" >> "$FAIL_LOG"
        echo
        continue
    fi
    if ! is_mrtrix_readable "$peaks_out"; then
        echo "  ERROR: peaks output not readable by MRtrix" >&2
        echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${mif_path}\t${dwi_mask_path}\tPEAKS_NOT_READABLE" >> "$FAIL_LOG"
        echo
        continue
    fi

    echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${peaks_out}\tOK" >> "$QC_LOG"

    echo
done

echo "All done."
