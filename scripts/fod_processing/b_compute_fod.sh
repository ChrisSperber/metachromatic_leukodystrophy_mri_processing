#!/usr/bin/env bash
# Generate multi-tissue FOD images from a TSV listing DWI paths (+ bval/bvec),
# then multi-tissue normalise (mtnormalise).
# Outputs are written into PROJECT_DIR/temp_images/FOD_images with a stable naming scheme.

set -euo pipefail

# -----------------------------
# USER SETTINGS
# -----------------------------
# Name of the conda env that has MRtrix3 (optional).
# If empty, the script assumes MRtrix commands are already in PATH.
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"

# If 1: use "conda run -n <env> <cmd>" for each MRtrix command (robust, no activation needed).
# If 0: try to "conda activate" once (works if conda is properly initialised in non-interactive shells).
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"

# Storage switches
# KEEP_GM_CSF_OUTPUTS:
#   1 -> keep GM/CSF FODs (both raw + norm, unless deleted by other switches)
#   0 -> delete GM/CSF outputs after successful normalisation (default: 0)
KEEP_GM_CSF_OUTPUTS="${KEEP_GM_CSF_OUTPUTS:-0}"

# DELETE_NONNORM_FODS:
#   1 -> delete non-normalised FODs after successful mtnormalise (default: 1)
#   0 -> keep non-normalised FODs
DELETE_NONNORM_FODS="${DELETE_NONNORM_FODS:-1}"

# DELETE_MASK:
#   1 -> delete mask after successful mtnormalise (default: 1)
#   0 -> keep mask
DELETE_MASK="${DELETE_MASK:-1}"

# (Optional) keep or delete intermediate input mif + response files
# Default is to KEEP them (useful for debugging); set to 1 to delete after success.
DELETE_INPUT_MIF="${DELETE_INPUT_MIF:-0}"
DELETE_RESPONSE_FILES="${DELETE_RESPONSE_FILES:-0}"

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

FAIL_LOG="$OUT_DIR/fod_failures.tsv"
if [[ ! -f "$FAIL_LOG" ]]; then
    echo -e "Subject_ID\tDate_Tag\tDTI_Method\tDWI_Path\tReason" > "$FAIL_LOG"
fi

echo "Project dir : $PROJECT_DIR"
echo "Data dir    : $DATA_DIR"
echo "TSV         : $TSV_PATH"
echo "Output dir  : $OUT_DIR"
echo "Conda env   : ${MRTRIX_CONDA_ENV} (USE_CONDA_RUN=${USE_CONDA_RUN})"
echo "KEEP_GM_CSF_OUTPUTS=${KEEP_GM_CSF_OUTPUTS}  DELETE_NONNORM_FODS=${DELETE_NONNORM_FODS}  DELETE_MASK=${DELETE_MASK}"
echo "DELETE_INPUT_MIF=${DELETE_INPUT_MIF}  DELETE_RESPONSE_FILES=${DELETE_RESPONSE_FILES}"
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
need_cmd gzip

if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" != "1" ]]; then
    # shellcheck disable=SC1091
    eval "$(conda shell.bash hook)"
    conda activate "$MRTRIX_CONDA_ENV"
fi

# MRtrix command availability checks
if [[ "$USE_CONDA_RUN" == "1" ]]; then
    mrtrix mrconvert -help >/dev/null 2>&1 || { echo "mrconvert not runnable via conda run" >&2; exit 1; }
    mrtrix dwi2response -help >/dev/null 2>&1 || { echo "dwi2response not runnable via conda run" >&2; exit 1; }
    mrtrix dwi2fod -help >/dev/null 2>&1 || { echo "dwi2fod not runnable via conda run" >&2; exit 1; }
    mrtrix dwi2mask -help >/dev/null 2>&1 || { echo "dwi2mask not runnable via conda run" >&2; exit 1; }
    mrtrix mtnormalise -help >/dev/null 2>&1 || { echo "mtnormalise not runnable via conda run" >&2; exit 1; }
else
    need_cmd mrconvert
    need_cmd dwi2response
    need_cmd dwi2fod
    need_cmd dwi2mask
    need_cmd mtnormalise
fi

# -----------------------------
# MAIN LOOP
# TSV columns:
# Subject_ID  Date_Tag  DTI_Method  dwiPath  bvalPath  bvecPath  bvals
# -----------------------------
echo "Starting TSV processing..."

tail -n +2 "$TSV_PATH" | sed 's/\r$//' | while IFS=$'\t' read -r subject_id date_tag dti_method dwi_rel bval_rel bvec_rel bvals; do
    [[ -z "${subject_id:-}" ]] && continue
    [[ -z "${date_tag:-}" ]] && continue

    dwi_path="$DATA_DIR/$dwi_rel"
    bval_path="$DATA_DIR/$bval_rel"
    bvec_path="$DATA_DIR/$bvec_rel"

    base="subject_${subject_id}_date_${date_tag}"

    # response outputs
    wm_resp="$OUT_DIR/${base}_response_wm.txt"
    gm_resp="$OUT_DIR/${base}_response_gm.txt"
    csf_resp="$OUT_DIR/${base}_response_csf.txt"

    # raw FODs
    wm_fod="$OUT_DIR/${base}_FOD_wm.mif"
    gm_fod="$OUT_DIR/${base}_FOD_gm.mif"
    csf_fod="$OUT_DIR/${base}_FOD_csf.mif"

    # normalised FODs
    wm_fod_norm="$OUT_DIR/${base}_FOD_wm_norm.mif"
    gm_fod_norm="$OUT_DIR/${base}_FOD_gm_norm.mif"
    csf_fod_norm="$OUT_DIR/${base}_FOD_csf_norm.mif"

    # input and mask
    in_mif="$OUT_DIR/${base}_dwi_input.mif"
    mask_mif="$OUT_DIR/${base}_dwi_mask.mif"

    echo "=== ${base}  (DTI_Method=${dti_method}) ==="
    echo "  DWI  : $dwi_path"
    echo "  bval : $bval_path"
    echo "  bvec : $bvec_path"
    echo "  bvals: $bvals"

    # existence checks
    if [[ ! -f "$dwi_path" ]]; then
        echo "  WARNING: missing DWI -> skipping" >&2
        echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${dwi_path}\tMISSING_DWI" >> "$FAIL_LOG"
        echo
        continue
    fi
    if [[ ! -f "$bval_path" || ! -f "$bvec_path" ]]; then
        echo "  WARNING: missing bval/bvec -> skipping" >&2
        echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${dwi_path}\tMISSING_BVAL_BVEC" >> "$FAIL_LOG"
        echo
        continue
    fi

    # integrity check for .nii.gz
    if [[ "$dwi_path" == *.nii.gz ]]; then
        if ! gzip -t "$dwi_path" >/dev/null 2>&1; then
            echo "  ERROR: corrupted gzip (CRC) -> skipping" >&2
            echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${dwi_path}\tCORRUPT_GZIP" >> "$FAIL_LOG"
            echo
            continue
        fi
    fi

    # If final product exists, you may skip entire subject (optional; keep as conservative: only skip if WM norm exists)
    if [[ -s "$wm_fod_norm" ]]; then
        echo "  WM normalised FOD exists, skipping subject."
        echo
        continue
    fi

    # (1) Convert to MIF with gradients
    if [[ ! -f "$in_mif" ]]; then
        echo "  Converting to MIF (embed gradients)..."
        if ! mrtrix mrconvert "$dwi_path" "$in_mif" -fslgrad "$bvec_path" "$bval_path" -force; then
            echo "  ERROR: mrconvert failed -> skipping" >&2
            echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${dwi_path}\tMRCONVERT_FAILED" >> "$FAIL_LOG"
            echo
            continue
        fi
    else
        echo "  Input MIF exists, skipping mrconvert."
    fi

    # (2) Estimate responses (dhollander)
    if [[ ! -f "$wm_resp" || ! -f "$gm_resp" || ! -f "$csf_resp" ]]; then
        echo "  Estimating responses (dhollander)..."
        if ! mrtrix dwi2response dhollander "$in_mif" "$wm_resp" "$gm_resp" "$csf_resp" -force; then
            echo "  ERROR: dwi2response failed -> skipping" >&2
            echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${dwi_path}\tDWI2RESPONSE_FAILED" >> "$FAIL_LOG"
            echo
            continue
        fi
    else
        echo "  Responses exist, skipping dwi2response."
    fi

    # (3) MSMT FODs (needed for mtnormalise)
    if [[ ! -f "$wm_fod" || ! -f "$gm_fod" || ! -f "$csf_fod" ]]; then
        echo "  Generating MSMT FODs (msmt_csd)..."
        if ! mrtrix dwi2fod msmt_csd \
            "$in_mif" \
            "$wm_resp" "$wm_fod" \
            "$gm_resp" "$gm_fod" \
            "$csf_resp" "$csf_fod" \
            -force; then
            echo "  ERROR: dwi2fod msmt_csd failed -> skipping" >&2
            echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${dwi_path}\tDWI2FOD_MSMT_FAILED" >> "$FAIL_LOG"
            echo
            continue
        fi
    else
        echo "  Raw FODs exist, skipping dwi2fod."
    fi

    # (4) Brain mask (required/helpful for mtnormalise)
    if [[ ! -f "$mask_mif" ]]; then
        echo "  Computing brain mask (dwi2mask)..."
        if ! mrtrix dwi2mask "$in_mif" "$mask_mif" -force; then
            echo "  ERROR: dwi2mask failed -> skipping" >&2
            echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${dwi_path}\tDWI2MASK_FAILED" >> "$FAIL_LOG"
            echo
            continue
        fi
    else
        echo "  Mask exists, skipping dwi2mask."
    fi

    # (5) Multi-tissue normalisation
    echo "  Normalising FODs (mtnormalise)..."
    if ! mrtrix mtnormalise \
        "$wm_fod" "$wm_fod_norm" \
        "$gm_fod" "$gm_fod_norm" \
        "$csf_fod" "$csf_fod_norm" \
        -mask "$mask_mif" \
        -force; then
        echo "  ERROR: mtnormalise failed -> skipping" >&2
        echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${dwi_path}\tMTNORMALISE_FAILED" >> "$FAIL_LOG"
        echo
        continue
    fi

    # Sanity: ensure required output exists
    if [[ ! -s "$wm_fod_norm" ]]; then
        echo "  ERROR: WM norm FOD missing/empty after mtnormalise -> skipping cleanup" >&2
        echo -e "${subject_id}\t${date_tag}\t${dti_method}\t${dwi_path}\tWM_NORM_MISSING" >> "$FAIL_LOG"
        echo
        continue
    fi

    # -----------------------------
    # CLEANUP (only after success)
    # -----------------------------
    if [[ "$DELETE_NONNORM_FODS" == "1" ]]; then
        echo "  Cleanup: deleting non-normalised FODs..."
        rm -f "$wm_fod" "$gm_fod" "$csf_fod"
    fi

    if [[ "$KEEP_GM_CSF_OUTPUTS" != "1" ]]; then
        echo "  Cleanup: deleting GM/CSF normalised outputs..."
        rm -f "$gm_fod_norm" "$csf_fod_norm"
        # optionally also delete response GM/CSF; controlled by DELETE_RESPONSE_FILES below
    fi

    if [[ "$DELETE_MASK" == "1" ]]; then
        echo "  Cleanup: deleting mask..."
        rm -f "$mask_mif"
    fi

    if [[ "$DELETE_RESPONSE_FILES" == "1" ]]; then
        echo "  Cleanup: deleting response files..."
        rm -f "$wm_resp" "$gm_resp" "$csf_resp"
    fi

    if [[ "$DELETE_INPUT_MIF" == "1" ]]; then
        echo "  Cleanup: deleting input MIF..."
        rm -f "$in_mif"
    fi

    echo
done

echo "All done."
