#!/usr/bin/env bash
# Generate WM FOD images from a TSV listing DWI paths (+ bval/bvec).
# Outputs are written into PROJECT_DIR/temp_images/FOD_images with a stable naming scheme.
# Note: Though naming conventions vary, all data are effectively multishell and are processed
# accordingly

set -euo pipefail

# -----------------------------
# USER SETTINGS
# -----------------------------
# Name of the conda env that has MRtrix3 (optional)
# If empty, the script assumes mrconvert/dwi2response/dwi2fod are already in PATH.
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"

# If 1: use "conda run -n <env> <cmd>" for each MRtrix command (robust, no activation needed).
# If 0: try to "conda activate" once (works if conda is properly initialised in non-interactive shells).
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"

# -----------------------------
# PATHS
# -----------------------------
script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"
DATA_DIR="$PROJECT_DIR/mld_data"
SRC_DIR="$PROJECT_DIR/temp_images"
OUT_DIR="$SRC_DIR/FOD_images"

# Path to TSV
TSV_PATH="$script_dir/a_collect_dwi_files.tsv"

if [[ ! -f "$TSV_PATH" ]]; then
    echo "TSV not found: $TSV_PATH" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

echo "Project dir : $PROJECT_DIR"
echo "TSV         : $TSV_PATH"
echo "Output dir  : $OUT_DIR"
echo "Conda env   : ${MRTRIX_CONDA_ENV} (USE_CONDA_RUN=${USE_CONDA_RUN})"
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

# Run MRtrix command either via conda run, or directly (or via conda activate).
mrtrix() {
    if [[ -n "$MRTRIX_CONDA_ENV" ]]; then
        if [[ "$USE_CONDA_RUN" == "1" ]]; then
            conda run -n "$MRTRIX_CONDA_ENV" "$@"
        else
            # Expect user has "conda" initialised; we'll activate once below.
            "$@"
        fi
    else
        "$@"
    fi
}

# If using conda run, we need conda itself available.
if [[ -n "$MRTRIX_CONDA_ENV" ]]; then
    need_cmd conda
fi

# If NOT using conda run, try to activate once (only if env name provided).
if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" != "1" ]]; then
    # non-interactive shells often need the conda hook
    # shellcheck disable=SC1091
    eval "$(conda shell.bash hook)"
    conda activate "$MRTRIX_CONDA_ENV"
fi

# Now ensure MRtrix commands are runnable (either directly or via conda run).
# If USE_CONDA_RUN=1, these checks should be done via mrtrix wrapper:
if [[ "$USE_CONDA_RUN" == "1" ]]; then
    mrtrix mrconvert -version >/dev/null 2>&1 || { echo "mrconvert not runnable via conda run" >&2; exit 1; }
    mrtrix dwi2response -version >/dev/null 2>&1 || { echo "dwi2response not runnable via conda run" >&2; exit 1; }
    mrtrix dwi2fod -version >/dev/null 2>&1 || { echo "dwi2fod not runnable via conda run" >&2; exit 1; }
else
    need_cmd mrconvert
    need_cmd dwi2response
    need_cmd dwi2fod
fi

# -----------------------------
# MAIN LOOP
# assumed TSV columns:
# Subject_ID  Date_Tag  DTI_Method  dwiPath  bvalPath  bvecPath
# -----------------------------
echo "Starting TSV processing..."

# Skip header, preserve tabs, handle possible CRLF line endings.
tail -n +2 "$TSV_PATH" | sed 's/\r$//' | while IFS=$'\t' read -r subject_id date_tag dti_method dwi_rel bval_rel bvec_rel bvals; do
    # basic guard
    [[ -z "${subject_id:-}" ]] && continue
    [[ -z "${date_tag:-}" ]] && continue

    # resolve paths relative to project dir
    dwi_path="$DATA_DIR/$dwi_rel"
    bval_path="$DATA_DIR/$bval_rel"
    bvec_path="$DATA_DIR/$bvec_rel"

    # outputs
    base="subject_${subject_id}_date_${date_tag}"
    wm_resp="$OUT_DIR/${base}_response_wm.txt"
    gm_resp="$OUT_DIR/${base}_response_gm.txt"
    csf_resp="$OUT_DIR/${base}_response_csf.txt"

    wm_fod_mif="$OUT_DIR/${base}_FOD_wm.mif"
    gm_fod_mif="$OUT_DIR/${base}_FOD_gm.mif"
    csf_fod_mif="$OUT_DIR/${base}_FOD_csf.mif"

    # temp input mif (embedded grads)
    in_mif="$OUT_DIR/${base}_dwi_input.mif"


    echo "=== ${base}  (DTI_Method=${dti_method}) ==="
    echo "  DWI : $dwi_path"
    echo "  bval: $bval_path"
    echo "  bvec: $bvec_path"
    echo "  bvals: $bvals"

    # existence checks
    if [[ ! -f "$dwi_path" ]]; then
        echo "  WARNING: missing DWI: $dwi_path  -> skipping" >&2
        continue
    fi
    if [[ ! -f "$bval_path" || ! -f "$bvec_path" ]]; then
        echo "  WARNING: missing bval/bvec -> skipping" >&2
        continue
    fi

    # (1) Convert NIfTI + grads -> .mif (once)
    if [[ ! -f "$in_mif" ]]; then
        echo "  Converting to MIF (embed gradients)..."
        mrtrix mrconvert "$dwi_path" "$in_mif" -fslgrad "$bvec_path" "$bval_path" -force
    else
        echo "  Input MIF exists, skipping mrconvert."
    fi

    # (2) Estimate response (once)
    if [[ ! -f "$wm_resp" || ! -f "$gm_resp" || ! -f "$csf_resp" ]]; then
        echo "  Estimating responses (dhollander)..."
        mrtrix dwi2response dhollander "$in_mif" "$wm_resp" "$gm_resp" "$csf_resp" -force
    else
        echo "  Responses exist, skipping dwi2response."
    fi

    # (3) Generate MSMT FODs
    if [[ ! -f "$wm_fod_mif" || ! -f "$gm_fod_mif" || ! -f "$csf_fod_mif" ]]; then
        echo "  Generating MSMT FODs (msmt_csd)..."
        mrtrix dwi2fod msmt_csd \
            "$in_mif" \
            "$wm_resp" "$wm_fod_mif" \
            "$gm_resp" "$gm_fod_mif" \
            "$csf_resp" "$csf_fod_mif" \
            -force
    else
        echo "  FODs exist, skipping dwi2fod."
    fi

    echo
done

echo "All done."
