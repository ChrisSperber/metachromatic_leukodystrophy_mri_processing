#!/usr/bin/env bash
# Build a template-space mean FA image by warping subject FA maps into the
# existing WM FOD template space using the control->template warps produced
# by c_generate_controls_template.sh.
#
# Inputs:
#   - temp_images/fod_template/warps/*.mif
#       one control->template warp per subject, named like:
#       subject_MLD103_date_Unknown_FOD_wm_norm.mif
#   - temp_images/FA_images/*_FA.nii.gz
#       matching FA images named like:
#       subject_MLD103_date_Unknown_FA.nii.gz
#   - temp_images/fod_template/wm_fod_template_<vox>mm.mif
#   - temp_images/fod_template/template_mask_<vox>mm.mif
#
# Outputs:
#   - temp_images/FA_template/transformed_controls_fa/
#       one warped FA image per subject in template space
#   - temp_images/FA_template/transformed_controls_fa_stack_4d.mif
#   - temp_images/FA_template/template_FA_<vox>mm.mif
#   - (optional) temp_images/FA_template/template_FA_<vox>mm.nii.gz
#   - temp_images/FA_template/template_FA.log
#
# Notes:
#   - Uses the already existing control->template warps from the FOD template workflow.
#   - Applies linear interpolation to FA images (continuous scalar images).
#   - Averages all warped FA images in template space.
#   - Optionally masks the mean FA by the template mask.

set -euo pipefail

# -----------------------------
# USER SETTINGS
# -----------------------------
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"

# Threads for MRtrix
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"

# Must match the FOD template voxel size already used
TEMPLATE_VOXEL_SIZE="${TEMPLATE_VOXEL_SIZE:-2.0}"

# FA filenames in FA_DIR:
#   subject_X_date_Y_FA.nii.gz
FA_SUFFIX="${FA_SUFFIX:-_FA.nii.gz}"

# Input warp filenames in WARP_DIR:
#   subject_X_date_Y_FOD_wm_norm.mif
WARP_SUFFIX="${WARP_SUFFIX:-_FOD_wm_norm.mif}"

# Interpolation for FA warping
FA_INTERP="${FA_INTERP:-linear}"

# Mask the final mean FA with the template mask
MASK_TEMPLATE_FA="${MASK_TEMPLATE_FA:-1}"

# Export final mean FA as NIfTI
EXPORT_TEMPLATE_FA_NIFTI="${EXPORT_TEMPLATE_FA_NIFTI:-1}"

# -----------------------------
# PATHS
# -----------------------------
script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"

SRC_DIR="$PROJECT_DIR/temp_images"

FA_DIR="$SRC_DIR/FA_images"

FOD_TPL_DIR="$SRC_DIR/fod_template"
WARP_DIR="$FOD_TPL_DIR/warps"
TEMPLATE_REF="$FOD_TPL_DIR/wm_fod_template_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_MASK="$FOD_TPL_DIR/template_mask_${TEMPLATE_VOXEL_SIZE}mm.mif"

OUT_DIR="$SRC_DIR/FA_template"
LOG_PATH="$OUT_DIR/template_FA.log"

XFM_FA_DIR="$OUT_DIR/transformed_controls_fa"
FA_STACK_4D="$OUT_DIR/transformed_controls_fa_stack_4d.mif"
TEMPLATE_FA="$OUT_DIR/template_FA_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_FA_NII="$OUT_DIR/template_FA_${TEMPLATE_VOXEL_SIZE}mm.nii.gz"

TEMPLATE_FA_UNMASKED="$OUT_DIR/template_FA_${TEMPLATE_VOXEL_SIZE}mm_unmasked.mif"

mkdir -p "$OUT_DIR" "$XFM_FA_DIR"

echo "Project dir       : $PROJECT_DIR"
echo "FA dir            : $FA_DIR"
echo "FOD template dir  : $FOD_TPL_DIR"
echo "Warp dir          : $WARP_DIR"
echo "Output dir        : $OUT_DIR"
echo "Conda env         : ${MRTRIX_CONDA_ENV} (USE_CONDA_RUN=${USE_CONDA_RUN})"
echo "Threads           : ${MRTRIX_NTHREADS}"
echo "Voxel size        : ${TEMPLATE_VOXEL_SIZE} mm"
echo "Template ref      : $TEMPLATE_REF"
echo "Template mask     : $TEMPLATE_MASK"
echo "FA suffix         : $FA_SUFFIX"
echo "Warp suffix       : $WARP_SUFFIX"
echo "FA interp         : $FA_INTERP"
echo "Mask mean FA      : ${MASK_TEMPLATE_FA}"
echo "Export nifti      : ${EXPORT_TEMPLATE_FA_NIFTI}"
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

need_cmd find
need_cmd sort
need_cmd wc
need_cmd basename
need_cmd date
need_cmd mkdir
need_cmd rm

if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" != "1" ]]; then
    eval "$(conda shell.bash hook)"
    conda activate "$MRTRIX_CONDA_ENV"
fi

# Ensure required MRtrix tools are runnable
if [[ "$USE_CONDA_RUN" == "1" ]]; then
    mrtrix mrtransform -help >/dev/null 2>&1 || { echo "mrtransform not runnable via conda run" >&2; exit 1; }
    mrtrix mrcat -help >/dev/null 2>&1 || { echo "mrcat not runnable via conda run" >&2; exit 1; }
    mrtrix mrmath -help >/dev/null 2>&1 || { echo "mrmath not runnable via conda run" >&2; exit 1; }
    mrtrix mrcalc -help >/dev/null 2>&1 || { echo "mrcalc not runnable via conda run" >&2; exit 1; }
    if [[ "$EXPORT_TEMPLATE_FA_NIFTI" == "1" ]]; then
        mrtrix mrconvert -help >/dev/null 2>&1 || { echo "mrconvert not runnable via conda run" >&2; exit 1; }
    fi
else
    need_cmd mrtransform
    need_cmd mrcat
    need_cmd mrmath
    need_cmd mrcalc
    [[ "$EXPORT_TEMPLATE_FA_NIFTI" == "1" ]] && need_cmd mrconvert
fi

export MRTRIX_NTHREADS

# -----------------------------
# INPUT CHECKS
# -----------------------------
[[ -d "$WARP_DIR" ]] || { echo "Missing warp dir: $WARP_DIR" >&2; exit 1; }
[[ -d "$FA_DIR" ]] || { echo "Missing FA dir: $FA_DIR" >&2; exit 1; }
[[ -f "$TEMPLATE_REF" ]] || { echo "Missing template reference: $TEMPLATE_REF" >&2; exit 1; }

if [[ "$MASK_TEMPLATE_FA" == "1" && ! -f "$TEMPLATE_MASK" ]]; then
    echo "Missing template mask: $TEMPLATE_MASK" >&2
    exit 1
fi

# -----------------------------
# LOG HEADER
# -----------------------------
{
    echo "=== template FA generation ==="
    echo "Date               : $(date)"
    echo "PROJECT_DIR        : $PROJECT_DIR"
    echo "FA_DIR             : $FA_DIR"
    echo "FOD_TPL_DIR        : $FOD_TPL_DIR"
    echo "WARP_DIR           : $WARP_DIR"
    echo "OUT_DIR            : $OUT_DIR"
    echo "TEMPLATE_REF       : $TEMPLATE_REF"
    echo "TEMPLATE_MASK      : $TEMPLATE_MASK"
    echo "TEMPLATE_FA        : $TEMPLATE_FA"
    echo "MRTRIX_CONDA_ENV   : $MRTRIX_CONDA_ENV"
    echo "USE_CONDA_RUN      : $USE_CONDA_RUN"
    echo "MRTRIX_NTHREADS    : $MRTRIX_NTHREADS"
    echo "TEMPLATE_VOXEL_SIZE: $TEMPLATE_VOXEL_SIZE"
    echo "FA_SUFFIX          : $FA_SUFFIX"
    echo "WARP_SUFFIX        : $WARP_SUFFIX"
    echo "FA_INTERP          : $FA_INTERP"
    echo "MASK_TEMPLATE_FA   : $MASK_TEMPLATE_FA"
    echo "EXPORT_TEMPLATE_FA_NIFTI: $EXPORT_TEMPLATE_FA_NIFTI"
    echo
    echo "=== MRtrix version ==="
    mrtrix mrinfo -version 2>/dev/null || true
    echo
} > "$LOG_PATH"

# -----------------------------
# 1) FIND WARPS AND WARP MATCHING FA IMAGES
# -----------------------------
echo "Warping subject FA maps into template space..."
rm -f "$XFM_FA_DIR"/*.mif 2>/dev/null || true

n_warps_total=0
n_kept=0
n_missing_fa=0

while IFS= read -r warp; do
    n_warps_total=$((n_warps_total + 1))

    warp_bname="$(basename "$warp")"
    baseprefix="${warp_bname%"${WARP_SUFFIX}"}"

    if [[ "$baseprefix" == "$warp_bname" ]]; then
        echo "WARNING: warp filename does not match expected suffix -> skipping" >&2
        echo "  Warp: $warp_bname" >&2
        continue
    fi

    fa_src="$FA_DIR/${baseprefix}${FA_SUFFIX}"
    fa_out="$XFM_FA_DIR/${baseprefix}_FA_in_template.mif"

    if [[ ! -f "$fa_src" ]]; then
        echo "WARNING: missing FA for warp ${warp_bname} -> skipping" >&2
        echo "  Expected: $fa_src" >&2
        n_missing_fa=$((n_missing_fa + 1))
        continue
    fi

    mrtrix mrtransform "$fa_src" "$fa_out" \
        -warp_full "$warp" \
        -template "$TEMPLATE_REF" \
        -interp "$FA_INTERP" \
        -force >> "$LOG_PATH" 2>&1

    n_kept=$((n_kept + 1))
done < <(find "$WARP_DIR" -maxdepth 1 -type f -name "*.mif" | sort)

echo "Found ${n_warps_total} warp files."
echo "Warped FA images for ${n_kept} subjects."
echo "Missing FA images for ${n_missing_fa} subjects."
echo

if [[ "$n_kept" -lt 3 ]]; then
    echo "ERROR: too few warped FA images to build template FA (need at least 3)." >&2
    exit 1
fi

# -----------------------------
# 2) AVERAGE WARPED FA IMAGES
# -----------------------------
echo "Averaging transformed FA images in template space..."
mrtrix mrcat "$XFM_FA_DIR"/*.mif -axis 3 "$FA_STACK_4D" -force >> "$LOG_PATH" 2>&1
mrtrix mrmath "$FA_STACK_4D" mean -axis 3 "$TEMPLATE_FA_UNMASKED" -force >> "$LOG_PATH" 2>&1

if [[ "$MASK_TEMPLATE_FA" == "1" ]]; then
    mrtrix mrcalc "$TEMPLATE_FA_UNMASKED" "$TEMPLATE_MASK" -mult "$TEMPLATE_FA" -force >> "$LOG_PATH" 2>&1
    rm -f "$TEMPLATE_FA_UNMASKED"
else
    mv -f "$TEMPLATE_FA_UNMASKED" "$TEMPLATE_FA"
fi

echo "Template FA created:"
echo "  $TEMPLATE_FA"

# -----------------------------
# 3) OPTIONAL NIFTI EXPORT
# -----------------------------
if [[ "$EXPORT_TEMPLATE_FA_NIFTI" == "1" ]]; then
    mrtrix mrconvert "$TEMPLATE_FA" "$TEMPLATE_FA_NII" -datatype float32 -force >> "$LOG_PATH" 2>&1
    echo "Template FA NIfTI created:"
    echo "  $TEMPLATE_FA_NII"
fi

echo
echo "Done."
echo "Main outputs:"
echo "  $XFM_FA_DIR"
echo "  $FA_STACK_4D"
echo "  $TEMPLATE_FA"
[[ "$EXPORT_TEMPLATE_FA_NIFTI" == "1" ]] && echo "  $TEMPLATE_FA_NII"
echo "Log:"
echo "  $LOG_PATH"
