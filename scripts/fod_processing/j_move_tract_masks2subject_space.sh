#!/usr/bin/env bash
# Warp binary tract masks from template space back into each subject's native space.
#
# Inputs:
#   - template-space tract masks in:
#       temp_images/fibres_tracked_in_template/<TRACT>/<TRACT>_mask.nii.gz
#   - inverse warps (template -> subject) in:
#       temp_images/fod_to_template/warps/*_tpl2subj_warp.mif
#   - subject native masks in:
#       temp_images/FOD_images/<subject>_dwi_mask.mif
#
# Outputs:
#   - subject-space binary tract masks in:
#       temp_images/fibres_subject_space/<subject>/<TRACT>_mask.nii.gz
#
# Notes:
#   - Uses nearest-neighbour interpolation to preserve binary masks.
#   - Re-binarises with >0 as a defensive step and writes uint8 NIfTI masks.
#   - Uses available tpl2subj warps as the driver of subject discovery.

set -euo pipefail

# -----------------------------
# USER SETTINGS
# -----------------------------
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"

# Keep intermediate files inside subject folders?
KEEP_INTERMEDIATES="${KEEP_INTERMEDIATES:-0}"

# -----------------------------
# PATHS
# -----------------------------
script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"

TEMP_DIR="$PROJECT_DIR/temp_images"

WARP_DIR="$TEMP_DIR/fod_to_template/warps"
FOD_DIR="$TEMP_DIR/FOD_images"
TRACT_ROOT="$TEMP_DIR/fibres_tracked_in_template"
OUT_ROOT="$TEMP_DIR/fibres_subject_space"

mkdir -p "$OUT_ROOT"

echo "Project dir        : $PROJECT_DIR"
echo "Temp dir           : $TEMP_DIR"
echo "Warp dir           : $WARP_DIR"
echo "FOD dir            : $FOD_DIR"
echo "Template tract dir : $TRACT_ROOT"
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
need_cmd find
need_cmd mkdir
need_cmd rm
need_cmd sed
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
need_dir "$TRACT_ROOT"

# -----------------------------
# HELPERS
# -----------------------------
strip_nii_ext() {
    local name="$1"
    name="${name%.nii.gz}"
    name="${name%.nii}"
    printf '%s\n' "$name"
}

extract_subject_base_from_warp() {
    local warp_name="$1"
    local base
    base="$(basename "$warp_name")"
    base="${base%_FOD_wm_norm_tpl2subj_warp.mif}"
    printf '%s\n' "$base"
}

find_template_mask() {
    local tract_dir="$1"
    local tract_name
    local mask_path

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

    local warped_mif
    local binary_mif

    warped_mif="$tmp_dir/warped_mask.mif"
    binary_mif="$tmp_dir/binary_mask.mif"

    mrtrix mrtransform \
        "$template_mask_nii" \
        "$warped_mif" \
        -warp "$tpl2subj_warp" \
        -template "$subject_template" \
        -interp nearest \
        -force

    # Defensive re-binarisation
    mrtrix mrcalc "$warped_mif" 0 -gt "$binary_mif" -force

    mrtrix mrconvert \
        "$binary_mif" \
        "$out_mask_nii" \
        -datatype uint8 \
        -force
}

# -----------------------------
# COLLECT INPUTS
# -----------------------------
mapfile -t warp_files < <(find "$WARP_DIR" -maxdepth 1 -type f -name "*_tpl2subj_warp.mif" | sort)
if [[ "${#warp_files[@]}" -eq 0 ]]; then
    echo "ERROR: no tpl2subj warp files found in $WARP_DIR" >&2
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
    subject_dir="$OUT_ROOT/$subject_base"
    tmp_dir="$subject_dir/tmp"
    subject_mask="$FOD_DIR/${subject_base}_dwi_mask.mif"

    echo "=== ${subject_base} ==="
    echo "  warp         : $tpl2subj_warp"
    echo "  native grid  : $subject_mask"
    echo "  output dir   : $subject_dir"

    need_file "$subject_mask"

    mkdir -p "$subject_dir" "$tmp_dir"

    for tract_dir in "${tract_dirs[@]}"; do
        tract_name="$(basename "$tract_dir")"
        template_mask="$(find_template_mask "$tract_dir")"
        out_mask="$subject_dir/${tract_name}_mask.nii.gz"
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
