#!/usr/bin/env bash
# Warp manual binary ROIs from FA template space into each subject's native space.

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
script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"
REPO_DIR="$(realpath "$script_dir/../..")"

TEMP_DIR="$PROJECT_DIR/temp_images"

WARP_DIR="$TEMP_DIR/fod_to_template/warps"
FOD_DIR="$TEMP_DIR/FOD_images"
MANUAL_ROI_DIR="$REPO_DIR/src/manual_rois"
OUT_ROOT="$TEMP_DIR/manual_rois_subject_space"

mkdir -p "$OUT_ROOT"

echo "Project dir        : $PROJECT_DIR"
echo "Temp dir           : $TEMP_DIR"
echo "Warp dir           : $WARP_DIR"
echo "FOD dir            : $FOD_DIR"
echo "Manual ROI dir     : $MANUAL_ROI_DIR"
echo "Output root        : $OUT_ROOT"
echo "Conda env          : ${MRTRIX_CONDA_ENV} (USE_CONDA_RUN=${USE_CONDA_RUN})"
echo "Threads            : ${MRTRIX_NTHREADS}"
echo "Keep intermediates : ${KEEP_INTERMEDIATES}"
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

need_cmd basename
need_cmd dirname
need_cmd mkdir
need_cmd rm
need_cmd sort

if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" != "1" ]]; then
    eval "$(conda shell.bash hook)"
    conda activate "$MRTRIX_CONDA_ENV"
fi

if [[ "$USE_CONDA_RUN" == "1" ]]; then
    mrtrix mrtransform -help >/dev/null 2>&1 || { echo "mrtransform not runnable via conda run" >&2; exit 1; }
    mrtrix mrconvert -help >/dev/null 2>&1 || { echo "mrconvert not runnable via conda run" >&2; exit 1; }
    mrtrix mrcalc -help >/dev/null 2>&1 || { echo "mrcalc not runnable via conda run" >&2; exit 1; }
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
need_dir "$FOD_DIR"
need_dir "$MANUAL_ROI_DIR"

# -----------------------------
# HELPERS
# -----------------------------
extract_subject_base_from_warp() {
    local warp_name="$1"
    local base
    base="$(basename "$warp_name")"
    base="${base%_FOD_wm_norm_tpl2subj_warp.mif}"
    printf '%s\n' "$base"
}

warp_one_roi() {
    local template_roi_nii="$1"
    local tpl2subj_warp="$2"
    local subject_template="$3"
    local out_roi_nii="$4"
    local tmp_dir="$5"

    local warped_mif
    local binary_mif

    warped_mif="$tmp_dir/warped_roi.mif"
    binary_mif="$tmp_dir/binary_roi.mif"

    mrtrix mrtransform \
        "$template_roi_nii" \
        "$warped_mif" \
        -warp "$tpl2subj_warp" \
        -template "$subject_template" \
        -interp nearest \
        -force

    mrtrix mrcalc "$warped_mif" 0 -gt "$binary_mif" -force

    mrtrix mrconvert \
        "$binary_mif" \
        "$out_roi_nii" \
        -datatype uint8 \
        -force
}

# -----------------------------
# REQUIRED ROIS
# -----------------------------
required_rois=(
    "ROI_CST_R.nii.gz"
    "ROI_CST_L.nii.gz"
    "ROI_FWM_R.nii.gz"
    "ROI_FWM_L.nii.gz"
    "ROI_PLIC_R.nii.gz"
    "ROI_PLIC_L.nii.gz"
)

roi_paths=()
for roi_name in "${required_rois[@]}"; do
    roi_path="$MANUAL_ROI_DIR/$roi_name"
    need_file "$roi_path"
    roi_paths+=("$roi_path")
done

# -----------------------------
# COLLECT INPUTS
# -----------------------------
mapfile -t warp_files < <(find "$WARP_DIR" -maxdepth 1 -type f -name "*_tpl2subj_warp.mif" | sort)
if [[ "${#warp_files[@]}" -eq 0 ]]; then
    echo "ERROR: no tpl2subj warp files found in $WARP_DIR" >&2
    exit 1
fi

echo "Found ${#warp_files[@]} inverse warp files."
echo "Found ${#roi_paths[@]} required manual ROIs."
echo

# -----------------------------
# MAIN LOOP
# -----------------------------
for tpl2subj_warp in "${warp_files[@]}"; do
    subject_base="$(extract_subject_base_from_warp "$tpl2subj_warp")"
    subject_dir="$OUT_ROOT/$subject_base"
    tmp_dir="$subject_dir/tmp"
    subject_mask="$FOD_DIR/${subject_base}_dwi_mask.mif"

    echo "=== ${subject_base} ==="
    echo "  warp         : $tpl2subj_warp"
    echo "  native grid  : $subject_mask"
    echo "  output dir   : $subject_dir"

    need_file "$subject_mask"

    mkdir -p "$subject_dir" "$tmp_dir"

    for roi_path in "${roi_paths[@]}"; do
        roi_name="$(basename "$roi_path")"
        out_roi="$subject_dir/${subject_base}_${roi_name}"
        roi_stem="${roi_name%.nii.gz}"
        roi_tmp_dir="$tmp_dir/$roi_stem"

        mkdir -p "$roi_tmp_dir"

        echo "  -> ${roi_name}"
        echo "     template roi : $roi_path"
        echo "     output roi   : $out_roi"

        warp_one_roi \
            "$roi_path" \
            "$tpl2subj_warp" \
            "$subject_mask" \
            "$out_roi" \
            "$roi_tmp_dir"
    done

    if [[ "$KEEP_INTERMEDIATES" != "1" ]]; then
        rm -rf "$tmp_dir"
    fi

    echo
done

echo "Done."
