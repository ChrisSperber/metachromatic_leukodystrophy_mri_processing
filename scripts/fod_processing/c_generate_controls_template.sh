#!/usr/bin/env bash
# Build a WM FOD population template from control subjects (subject_MLD*),
# using normalised WM FOD images (*_FOD_wm_norm.mif) produced previously.
#
# Outputs:
#   - temp_images/fod_template/controls_wm_fod_norm_list.txt
#   - temp_images/fod_template/wm_fod_template_2mm.mif
#   - temp_images/fod_template/population_template.log
#   - temp_images/fod_template/scratch/ (intermediates)
#   - (optional) temp_images/fod_template/template_AFD.mif (+ .nii.gz)

set -euo pipefail

# -----------------------------
# USER SETTINGS
# -----------------------------
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"

# Threads for MRtrix (exported so MRtrix picks it up)
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"

# Template voxel size (2.0 mm matches DWI resolution)
TEMPLATE_VOXEL_SIZE="${TEMPLATE_VOXEL_SIZE:-2.0}"

# Pattern for control subjects in flat FOD output folder
CONTROL_GLOB="${CONTROL_GLOB:-subject_MLD*_FOD_wm_norm.mif}"

# If 1: derive an AFD map from the template WM FOD for QC
MAKE_TEMPLATE_AFD="${MAKE_TEMPLATE_AFD:-1}"

# If 1: also export AFD as NIfTI
EXPORT_TEMPLATE_AFD_NIFTI="${EXPORT_TEMPLATE_AFD_NIFTI:-1}"

# -----------------------------
# PATHS
# -----------------------------
script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"

SRC_DIR="$PROJECT_DIR/temp_images"
FOD_DIR="$SRC_DIR/FOD_images"

TPL_DIR="$SRC_DIR/fod_template"
SCRATCH_DIR="$TPL_DIR/scratch"

LIST_PATH="$TPL_DIR/controls_wm_fod_norm_list.txt"
TEMPLATE_OUT="$TPL_DIR/wm_fod_template_${TEMPLATE_VOXEL_SIZE}mm.mif"
LOG_PATH="$TPL_DIR/population_template.log"

# template AFD outputs (QC)
AFD_DIR="$TPL_DIR/template_fixels"
TEMPLATE_AFD_MIF="$TPL_DIR/template_AFD_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_AFD_NII="$TPL_DIR/template_AFD_${TEMPLATE_VOXEL_SIZE}mm.nii.gz"

mkdir -p "$TPL_DIR" "$SCRATCH_DIR"
# mrtrix works on a single folder, create one with symlinks
TPL_INPUT_DIR="$TPL_DIR/input_controls"
mkdir -p "$TPL_INPUT_DIR"


echo "Project dir  : $PROJECT_DIR"
echo "FOD dir      : $FOD_DIR"
echo "Template dir : $TPL_DIR"
echo "Conda env    : ${MRTRIX_CONDA_ENV} (USE_CONDA_RUN=${USE_CONDA_RUN})"
echo "Threads      : ${MRTRIX_NTHREADS}"
echo "Voxel size   : ${TEMPLATE_VOXEL_SIZE} mm"
echo "Control glob : ${CONTROL_GLOB}"
echo "Make AFD     : ${MAKE_TEMPLATE_AFD} (export nifti=${EXPORT_TEMPLATE_AFD_NIFTI})"
echo "TPL_INPUT_DIR: $TPL_INPUT_DIR"
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

if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" != "1" ]]; then
    eval "$(conda shell.bash hook)"
    conda activate "$MRTRIX_CONDA_ENV"
fi

# Ensure required MRtrix tools are runnable
if [[ "$USE_CONDA_RUN" == "1" ]]; then
    mrtrix population_template -help >/dev/null 2>&1 || { echo "population_template not runnable via conda run" >&2; exit 1; }
    if [[ "$MAKE_TEMPLATE_AFD" == "1" ]]; then
        mrtrix fod2fixel -help >/dev/null 2>&1 || { echo "fod2fixel not runnable via conda run" >&2; exit 1; }
        mrtrix mrconvert -help >/dev/null 2>&1 || { echo "mrconvert not runnable via conda run" >&2; exit 1; }
    fi
else
    need_cmd population_template
    if [[ "$MAKE_TEMPLATE_AFD" == "1" ]]; then
        need_cmd fod2fixel
        need_cmd mrconvert
    fi
fi

# Set MRtrix threads for this script
export MRTRIX_NTHREADS

# -----------------------------
# 1) COLLECT CONTROL FODS
# -----------------------------
echo "Collecting control WM FODs..."
find "$FOD_DIR" -type f -name "$CONTROL_GLOB" | sort > "$LIST_PATH"

n=$(wc -l < "$LIST_PATH" | tr -d ' ')
echo "Found ${n} control FODs."
echo "List file: $LIST_PATH"

if [[ "$n" -lt 3 ]]; then
    echo "ERROR: too few inputs for template building (need at least 3). Check CONTROL_GLOB / folder." >&2
    exit 1
fi

echo
echo "First 5 inputs:"
head -n 5 "$LIST_PATH" || true
echo

echo "Preparing template input directory (symlinks)..."
find "$TPL_INPUT_DIR" -maxdepth 1 -type l -delete

while IFS= read -r fod; do
    ln -s "$fod" "$TPL_INPUT_DIR/$(basename "$fod")"
done < "$LIST_PATH"

# -----------------------------
# 2) BUILD TEMPLATE
# -----------------------------
echo "Building population template..."
echo "Logging to: $LOG_PATH"
echo

{
    echo "=== population_template run ==="
    echo "Date: $(date)"
    echo "FOD_DIR: $FOD_DIR"
    echo "LIST_PATH: $LIST_PATH"
    echo "TEMPLATE_OUT: $TEMPLATE_OUT"
    echo "VOXEL_SIZE: $TEMPLATE_VOXEL_SIZE"
    echo "MRTRIX_NTHREADS: $MRTRIX_NTHREADS"
    echo
} > "$LOG_PATH"

mrtrix population_template \
    "$TPL_INPUT_DIR" \
    "$TEMPLATE_OUT" \
    -voxel_size "$TEMPLATE_VOXEL_SIZE" \
    -scratch "$SCRATCH_DIR" \
    -force >> "$LOG_PATH" 2>&1

echo
echo "Template created:"
echo "  $TEMPLATE_OUT"
echo

# -----------------------------
# 3) DERIVE TEMPLATE AFD (QC)  -> 3D voxel NIfTI
# -----------------------------
if [[ "$MAKE_TEMPLATE_AFD" == "1" ]]; then
    echo "Deriving template AFD map (QC)..."
    rm -rf "$AFD_DIR"
    mkdir -p "$AFD_DIR"

    # fod2fixel: -afd must be a filename within the fixel dir
    AFD_FX_BASENAME="template_AFD_fixel.mif"
    AFD_FX_PATH="${AFD_DIR}/${AFD_FX_BASENAME}"

    # 3D voxel AFD (MIF) + NIfTI paths
    AFD_VOX_MIF="${AFD_DIR}/template_AFD_voxel.mif"

    # 1) Compute fixel-wise AFD (vector per fixel)
    mrtrix fod2fixel "$TEMPLATE_OUT" "$AFD_DIR" -afd "$AFD_FX_BASENAME" -force >> "$LOG_PATH" 2>&1

    # 2) Convert fixel-wise -> voxel-wise 3D image (QC). Use mean (alt: sum/max).
    mrtrix fixel2voxel "$AFD_FX_PATH" mean "$AFD_VOX_MIF" >> "$LOG_PATH" 2>&1

    mkdir -p "$(dirname "$TEMPLATE_AFD_MIF")"
    mv -f "$AFD_VOX_MIF" "$TEMPLATE_AFD_MIF"

    echo "  AFD 3D (mif): $TEMPLATE_AFD_MIF"

    if [[ "$EXPORT_TEMPLATE_AFD_NIFTI" == "1" ]]; then
        mrtrix mrconvert "$TEMPLATE_AFD_MIF" "$TEMPLATE_AFD_NII" -datatype float32 -force >> "$LOG_PATH" 2>&1
        echo "  AFD 3D (nii): $TEMPLATE_AFD_NII"
    fi

    echo
fi

echo "Done."
