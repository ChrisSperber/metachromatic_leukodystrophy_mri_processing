#!/usr/bin/env bash
# Track selected fibre bundles in template space from a whole-brain template tractogram.
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
#   extract_tract "<tract_name>" "<include_atlas_groups>" "<exclude_atlas_groups>" \
#                 "<include_manual_rois>" "<exclude_manual_rois>"
#
# Arguments:
#   tract_name            Output name, e.g. "cst_left"
#   include_atlas_groups  Quoted string describing include atlas ROI groups
#   exclude_atlas_groups  Quoted string describing exclude atlas ROI groups
#   include_manual_rois   Quoted, space-separated paths to manual include ROIs
#   exclude_manual_rois   Quoted, space-separated paths to manual exclude ROIs
#
# Atlas group syntax:
#   - ';' separates groups
#   - ',' separates labels within one group
#   - labels within a group are merged by OR into one ROI
#   - different include groups are passed separately to tckedit, i.e. AND logic across groups
#
# Example:
#   "1,2,3;10;15,16"
#   -> include/exclude three atlas ROI groups:
#        group1 = label 1 OR 2 OR 3
#        group2 = label 10
#        group3 = label 15 OR 16
#
# Notes:
#   - the tzo116plus.nii labels in the SRI24 atlas are used
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
BINARY_MIN_DENSITY="${BINARY_MIN_DENSITY:-20}"

# -----------------------------
# PATHS
# -----------------------------
script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"

TEMP_DIR="$PROJECT_DIR/temp_images"
OUT_ROOT="$TEMP_DIR/fibres_tracked_in_template"

TRACTOGRAM="$TEMP_DIR/fod_template/tractography/template_tracks_2000000.tck"
TEMPLATE_IMAGE="$TEMP_DIR/FA_template/template_FA_2.0mm.nii.gz"
ATLAS_NII="$TEMP_DIR/sri_atlas_template/tzo116plus_in_template.nii.gz"

ROI_DIR="$(realpath "$script_dir/../../src/manual_rois")"
CC_MEDIAL_NII="$ROI_DIR/manual_medialCC_roi_template.nii.gz"
PLIC_LEFT_NII="$ROI_DIR/manual_PLIC_L_roi_template.nii.gz"
PLIC_RIGHT_NII="$ROI_DIR/manual_PLIC_R_roi_template.nii.gz"
PEDUNCLE_LEFT_NII="$ROI_DIR/manual_peduncle_L_roi_template.nii.gz"
PEDUNCLE_RIGHT_NII="$ROI_DIR/manual_peduncle_R_roi_template.nii.gz"
POSTERIOR_BRAINSTEM_NII="$ROI_DIR/manual_postbrainstem_roi_template.nii.gz"

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

need_cmd awk
need_cmd basename
need_cmd date
need_cmd dirname
need_cmd mkdir
need_cmd rm
need_cmd sed
need_cmd tr

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
need_file "$CC_MEDIAL_NII"
need_file "$PLIC_LEFT_NII"
need_file "$PLIC_RIGHT_NII"
need_file "$PEDUNCLE_LEFT_NII"
need_file "$PEDUNCLE_RIGHT_NII"
need_file "$POSTERIOR_BRAINSTEM_NII"

# -----------------------------
# HELPERS
# -----------------------------
sanitize_token() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

strip_nii_ext() {
    local name="$1"
    name="${name%.nii.gz}"
    name="${name%.nii}"
    printf '%s\n' "$name"
}

make_atlas_group_roi() {
    local atlas_mif="$1"
    local label_group_csv="$2"
    local out_roi="$3"

    local group_clean
    local first_label
    local label
    local tmp_roi
    local tmp_combined
    local idx=0

    group_clean="$(printf '%s' "$label_group_csv" | tr -d '[:space:]')"

    if [[ -z "$group_clean" ]]; then
        echo "ERROR: empty atlas group encountered." >&2
        exit 1
    fi

    IFS=',' read -r -a labels <<< "$group_clean"

    if [[ "${#labels[@]}" -eq 0 ]]; then
        echo "ERROR: failed to parse atlas group '$label_group_csv'." >&2
        exit 1
    fi

    first_label="${labels[0]}"
    mrtrix mrcalc "$atlas_mif" "$first_label" -eq "$out_roi" -force

    for label in "${labels[@]:1}"; do
        idx=$((idx + 1))
        tmp_roi="${out_roi%.mif}_label_${idx}.mif"
        tmp_combined="${out_roi%.mif}_combined_${idx}.mif"

        mrtrix mrcalc "$atlas_mif" "$label" -eq "$tmp_roi" -force
        mrtrix mrcalc "$out_roi" "$tmp_roi" -add 0 -gt "$tmp_combined" -force
        mv -f "$tmp_combined" "$out_roi"

        if [[ "$KEEP_INTERMEDIATES" != "1" ]]; then
            rm -f "$tmp_roi"
        fi
    done
}

extract_tract() {
    local tract_name="$1"
    local include_atlas_groups="$2"
    local exclude_atlas_groups="$3"
    local include_manual_rois="$4"
    local exclude_manual_rois="$5"

    local tract_dir
    local roi_dir
    local tmp_dir
    local summary_txt
    local tract_tck
    local density_mif
    local density_nii
    local mask_mif
    local mask_nii
    local atlas_mif

    tract_dir="$OUT_ROOT/$tract_name"
    roi_dir="$tract_dir/rois"
    tmp_dir="$tract_dir/tmp"

    summary_txt="$tract_dir/${tract_name}_summary.txt"
    tract_tck="$tract_dir/${tract_name}.tck"
    density_mif="$tract_dir/${tract_name}_density.mif"
    density_nii="$tract_dir/${tract_name}_density.nii.gz"
    mask_mif="$tract_dir/${tract_name}_mask.mif"
    mask_nii="$tract_dir/${tract_name}_mask.nii.gz"
    atlas_mif="$tmp_dir/atlas.mif"

    mkdir -p "$tract_dir" "$roi_dir" "$tmp_dir"

    local include_flags=()
    local exclude_flags=()

    local group
    local roi
    local roi_mif
    local token
    local base_name

    echo "=== ${tract_name} ==="

    mrtrix mrconvert "$ATLAS_NII" "$atlas_mif" -force

    # Include atlas ROI groups
    IFS=';' read -r -a include_groups <<< "$include_atlas_groups"
    for group in "${include_groups[@]}"; do
        group="$(printf '%s' "$group" | tr -d '[:space:]')"
        [[ -z "$group" ]] && continue

        token="$(sanitize_token "$group")"
        roi_mif="$roi_dir/${tract_name}_atlas_include_group_${token}.mif"
        make_atlas_group_roi "$atlas_mif" "$group" "$roi_mif"
        include_flags+=("-include" "$roi_mif")
    done

    # Exclude atlas ROI groups
    IFS=';' read -r -a exclude_groups <<< "$exclude_atlas_groups"
    for group in "${exclude_groups[@]}"; do
        group="$(printf '%s' "$group" | tr -d '[:space:]')"
        [[ -z "$group" ]] && continue

        token="$(sanitize_token "$group")"
        roi_mif="$roi_dir/${tract_name}_atlas_exclude_group_${token}.mif"
        make_atlas_group_roi "$atlas_mif" "$group" "$roi_mif"
        exclude_flags+=("-exclude" "$roi_mif")
    done

    # Include manual ROIs
    for roi in $include_manual_rois; do
        need_file "$roi"
        base_name="$(strip_nii_ext "$(basename "$roi")")"
        token="$(sanitize_token "$base_name")"
        roi_mif="$roi_dir/${tract_name}_manual_include_${token}.mif"
        mrtrix mrconvert "$roi" "$roi_mif" -force
        include_flags+=("-include" "$roi_mif")
    done

    # Exclude manual ROIs
    for roi in $exclude_manual_rois; do
        need_file "$roi"
        base_name="$(strip_nii_ext "$(basename "$roi")")"
        token="$(sanitize_token "$base_name")"
        roi_mif="$roi_dir/${tract_name}_manual_exclude_${token}.mif"
        mrtrix mrconvert "$roi" "$roi_mif" -force
        exclude_flags+=("-exclude" "$roi_mif")
    done

    if [[ "${#include_flags[@]}" -eq 0 && "${#exclude_flags[@]}" -eq 0 ]]; then
        echo "ERROR: tract '${tract_name}' has no include or exclude ROIs." >&2
        exit 1
    fi

    # Select streamlines
    mrtrix tckedit "$TRACTOGRAM" "$tract_tck" \
        "${include_flags[@]}" \
        "${exclude_flags[@]}" \
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
        mrtrix mrstats "$mask_mif" -output sum 2>/dev/null | awk 'NR==1 {print $1}'
    )"

    {
        echo "tract_name: ${tract_name}"
        echo "date: $(date)"
        echo "tractogram: ${TRACTOGRAM}"
        echo "template_image: ${TEMPLATE_IMAGE}"
        echo "atlas: ${ATLAS_NII}"
        echo "include_atlas_groups: ${include_atlas_groups}"
        echo "exclude_atlas_groups: ${exclude_atlas_groups}"
        echo "include_manual_rois: ${include_manual_rois}"
        echo "exclude_manual_rois: ${exclude_manual_rois}"
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
# CST - Defined by precentral gyrus in atlas, PLIC, cerebral peduncle
# exclude medial CC, contralateral peduncle, posterior brainstem
extract_tract \
    "cst_left" \
    "1" \
    "" \
    "$PLIC_LEFT_NII $PEDUNCLE_LEFT_NII" \
    "$CC_MEDIAL_NII $PEDUNCLE_RIGHT_NII $POSTERIOR_BRAINSTEM_NII"

extract_tract \
    "cst_right" \
    "2" \
    "" \
    "$PLIC_RIGHT_NII $PEDUNCLE_RIGHT_NII" \
    "$CC_MEDIAL_NII $PEDUNCLE_LEFT_NII $POSTERIOR_BRAINSTEM_NII"

echo "Done."
