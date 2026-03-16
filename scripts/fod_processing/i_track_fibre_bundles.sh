#!/usr/bin/env bash
# Track selected fibre bundles in template space from a whole-brain template tractogram.
#
# Current tracts:
#   - cst_left
#   - cst_right
#
# For each tract, the script:
#   1) extracts atlas-based include/exclude ROIs
#   2) converts manual include/exclude ROIs to MRtrix format
#   3) selects streamlines from the whole-brain tractogram using include/exclude ROIs
#   4) creates:
#        - tract .tck
#        - streamline density map (.nii.gz)
#        - binary tract mask (.nii.gz)
#        - text summary
#
# Main function:
#   extract_tract <tract_name> <atlas_label> <manual_include_roi> <manual_exclude_roi>
#
# Arguments:
#   tract_name           Output name, e.g. "cst_left"
#   atlas_label          Integer label in LPBA atlas for cortical include ROI
#   manual_include_roi   Path to unilateral manual include ROI (e.g. PLIC)
#   manual_exclude_roi   Path to shared/manual exclusion ROI (e.g. medial CC)
#
# Notes:
#   - Binary mask threshold is applied to the density map:
#       * default: > 0
#       * can be changed via BINARY_MIN_DENSITY
#   - Intermediates are deleted by default (KEEP_INTERMEDIATES=0)
#   - ROIs and tractogram must already be in the same template space

set -euo pipefail

# -----------------------------
# USER SETTINGS
# -----------------------------
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"

MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"

# Keep temporary/intermediate files inside each tract folder?
KEEP_INTERMEDIATES="${KEEP_INTERMEDIATES:-0}"

# Density threshold for binary mask creation:
#   0 -> mask voxels with density > 0
#   N>0 -> mask voxels with density >= N
BINARY_MIN_DENSITY="${BINARY_MIN_DENSITY:-0}"

# -----------------------------
# PATHS
# -----------------------------
script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"

TEMP_DIR="$PROJECT_DIR/temp_images"
OUT_ROOT="$TEMP_DIR/fibres_tracked_in_template"

TRACTOGRAM="$TEMP_DIR/fod_template/tractography/template_tracks_2000000.tck"
TEMPLATE_IMAGE="$TEMP_DIR/FA_template/template_FA_2.0mm.nii.gz"
ATLAS_NII="$TEMP_DIR/sri_atlas_template/lpba40_in_template.nii.gz"

ROI_DIR="$(realpath "$script_dir/../../src/manual_rois")"
CC_EXCLUDE_NII="$ROI_DIR/manual_medialCC_roi_template.nii.gz"
PLIC_LEFT_NII="$ROI_DIR/manual_PLIC_L_roi_template.nii.gz"
PLIC_RIGHT_NII="$ROI_DIR/manual_PLIC_R_roi_template.nii.gz"

mkdir -p "$OUT_ROOT"

echo "Project dir        : $PROJECT_DIR"
echo "Temp dir           : $TEMP_DIR"
echo "Output root        : $OUT_ROOT"
echo "Tractogram         : $TRACTOGRAM"
echo "Template image     : $TEMPLATE_IMAGE"
echo "Atlas              : $ATLAS_NII"
echo "Manual ROI dir     : $ROI_DIR"
echo "Conda env          : ${MRTRIX_CONDA_ENV} (USE_CONDA_RUN=${USE_CONDA_RUN})"
echo "Threads            : ${MRTRIX_NTHREADS}"
echo "Keep intermediates : ${KEEP_INTERMEDIATES}"
echo "Binary min density : ${BINARY_MIN_DENSITY}"
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
need_cmd date
need_cmd mkdir
need_cmd rm
need_cmd wc
need_cmd awk
need_cmd grep

if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" != "1" ]]; then
    eval "$(conda shell.bash hook)"
    conda activate "$MRTRIX_CONDA_ENV"
fi

if [[ "$USE_CONDA_RUN" == "1" ]]; then
    mrtrix mrconvert -help >/dev/null 2>&1 || { echo "mrconvert not runnable via conda run" >&2; exit 1; }
    mrtrix mrcalc -help >/dev/null 2>&1 || { echo "mrcalc not runnable via conda run" >&2; exit 1; }
    mrtrix tckedit -help >/dev/null 2>&1 || { echo "tckedit not runnable via conda run" >&2; exit 1; }
    mrtrix tckmap -help >/dev/null 2>&1 || { echo "tckmap not runnable via conda run" >&2; exit 1; }
    mrtrix tckinfo -help >/dev/null 2>&1 || { echo "tckinfo not runnable via conda run" >&2; exit 1; }
    mrtrix mrstats -help >/dev/null 2>&1 || { echo "mrstats not runnable via conda run" >&2; exit 1; }
else
    need_cmd mrconvert
    need_cmd mrcalc
    need_cmd tckedit
    need_cmd tckmap
    need_cmd tckinfo
    need_cmd mrstats
fi

export MRTRIX_NTHREADS

# -----------------------------
# INPUT CHECKS
# -----------------------------
need_file() {
    [[ -f "$1" ]] || {
        echo "Required file not found: $1" >&2
        exit 1
    }
}

need_file "$TRACTOGRAM"
need_file "$TEMPLATE_IMAGE"
need_file "$ATLAS_NII"
need_file "$CC_EXCLUDE_NII"
need_file "$PLIC_LEFT_NII"
need_file "$PLIC_RIGHT_NII"

# -----------------------------
# HELPERS
# -----------------------------
extract_tract() {
    local tract_name="$1"
    local atlas_label="$2"
    local manual_include_nii="$3"
    local manual_exclude_nii="$4"

    local tract_dir
    local roi_dir
    local tmp_dir
    local summary_txt
    local tract_tck
    local density_mif
    local density_nii
    local mask_mif
    local mask_nii

    tract_dir="$OUT_ROOT/$tract_name"
    roi_dir="$tract_dir/rois"
    tmp_dir="$tract_dir/tmp"

    summary_txt="$tract_dir/${tract_name}_summary.txt"
    tract_tck="$tract_dir/${tract_name}.tck"
    density_mif="$tract_dir/${tract_name}_density.mif"
    density_nii="$tract_dir/${tract_name}_density.nii.gz"
    mask_mif="$tract_dir/${tract_name}_mask.mif"
    mask_nii="$tract_dir/${tract_name}_mask.nii.gz"

    mkdir -p "$tract_dir" "$roi_dir" "$tmp_dir"

    local atlas_mif
    local cortex_roi_mif
    local include_roi_mif
    local exclude_roi_mif

    atlas_mif="$tmp_dir/atlas.mif"
    cortex_roi_mif="$roi_dir/${tract_name}_precentral.mif"
    include_roi_mif="$roi_dir/${tract_name}_manual_include.mif"
    exclude_roi_mif="$roi_dir/${tract_name}_manual_exclude.mif"

    echo "=== ${tract_name} ==="

    # Convert atlas / manual ROIs to MRtrix format on template grid
    mrtrix mrconvert "$ATLAS_NII" "$atlas_mif" -force
    mrtrix mrconvert "$manual_include_nii" "$include_roi_mif" -force
    mrtrix mrconvert "$manual_exclude_nii" "$exclude_roi_mif" -force

    # Extract cortical ROI from integer atlas label
    mrtrix mrcalc "$atlas_mif" "$atlas_label" -eq "$cortex_roi_mif" -force

    # Select streamlines
    mrtrix tckedit "$TRACTOGRAM" "$tract_tck" \
        -include "$cortex_roi_mif" \
        -include "$include_roi_mif" \
        -exclude "$exclude_roi_mif" \
        -force

    # Density map on template grid
    mrtrix tckmap "$tract_tck" "$density_mif" \
        -template "$TEMPLATE_IMAGE" \
        -datatype uint32 \
        -force

    mrtrix mrconvert "$density_mif" "$density_nii" -force

    # Binary mask from density map
    if [[ "$BINARY_MIN_DENSITY" == "0" ]]; then
        mrtrix mrcalc "$density_mif" 0 -gt "$mask_mif" -force
    else
        mrtrix mrcalc "$density_mif" "$BINARY_MIN_DENSITY" -ge "$mask_mif" -force
    fi

    mrtrix mrconvert "$mask_mif" "$mask_nii" -datatype uint8 -force

    # Summary
    local n_streamlines
    local n_mask_voxels

    n_streamlines="$(
        mrtrix tckinfo "$tract_tck" 2>/dev/null \
        | awk -F: '/count/ {gsub(/^[ \t]+/, "", $2); print $2; exit}'
    )"

    n_mask_voxels="$(
        mrtrix mrstats "$mask_mif" -output count 2>/dev/null | awk 'NR==1 {print $1}'
    )"

    {
        echo "tract_name: ${tract_name}"
        echo "date: $(date)"
        echo "tractogram: ${TRACTOGRAM}"
        echo "template_image: ${TEMPLATE_IMAGE}"
        echo "atlas: ${ATLAS_NII}"
        echo "atlas_label_precentral: ${atlas_label}"
        echo "manual_include_roi: ${manual_include_nii}"
        echo "manual_exclude_roi: ${manual_exclude_nii}"
        echo "binary_min_density: ${BINARY_MIN_DENSITY}"
        echo "n_streamlines: ${n_streamlines:-NA}"
        echo "n_mask_voxels: ${n_mask_voxels:-NA}"
        echo "outputs:"
        echo "  tract_tck: ${tract_tck}"
        echo "  density_nii: ${density_nii}"
        echo "  mask_nii: ${mask_nii}"
    } > "$summary_txt"

    if [[ "$KEEP_INTERMEDIATES" != "1" ]]; then
        rm -rf "$tmp_dir"
        rm -f "$density_mif" "$mask_mif"
    fi

    echo "  tract     : $tract_tck"
    echo "  density   : $density_nii"
    echo "  mask      : $mask_nii"
    echo "  summary   : $summary_txt"
    echo
}

# -----------------------------
# RUN CURRENT TRACTS
# -----------------------------
extract_tract "cst_left"  "27" "$PLIC_LEFT_NII"  "$CC_EXCLUDE_NII"
extract_tract "cst_right" "28" "$PLIC_RIGHT_NII" "$CC_EXCLUDE_NII"

echo "Done."
