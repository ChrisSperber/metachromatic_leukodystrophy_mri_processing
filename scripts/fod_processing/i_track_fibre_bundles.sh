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
#                 "<include_manual_rois>" "<exclude_manual_rois>" "<binary_min_density>"
#
# Arguments:
#   tract_name            Output name, e.g. "cst_left"
#   include_atlas_groups  Quoted string describing include atlas ROI groups
#   exclude_atlas_groups  Quoted string describing exclude atlas ROI groups
#   include_manual_rois   Quoted, space-separated paths to manual include ROIs
#   exclude_manual_rois   Quoted, space-separated paths to manual exclude ROIs
#   binary_min_density    Density threshold for binary mask creation:
#                         0 -> mask voxels with density > 0
#                         N>0 -> mask voxels with density >= N
#
# Atlas group syntax:
#   - ';' separates groups
#   - ',' separates labels within one group
#   - labels within a group are merged by OR into one ROI
#   - different include groups are passed separately to tckedit, i.e. AND logic across groups
#   - for label assignment see the SRI24-tzo116plus.txt file downloaded with the atlas
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
DORSAL_WM_SLFI_NII="$ROI_DIR/manual_dorsal_wm_SLFI_roi_template.nii.gz"
CAPSULA_INT_EXT_NII="$ROI_DIR/manual_capsula_int_ext_roi_template.nii.gz"
INFERIOR_Z40_NII="$ROI_DIR/manual_inferior_z40_roi_template.nii.gz"
CAPSULA_EXTERNA_NII="$ROI_DIR/manual_capsula_ext_roi_template.nii.gz"
SAGITTAL_MIDLINE_NII="$ROI_DIR/manual_sagittal_midline_roi_template.nii.gz"

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
need_file "$DORSAL_WM_SLFI_NII"
need_file "$CAPSULA_INT_EXT_NII"
need_file "$INFERIOR_Z40_NII"
need_file "$CAPSULA_EXTERNA_NII"
need_file "$SAGITTAL_MIDLINE_NII"

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
    local tract_name=""
    local include_atlas_groups=""
    local exclude_atlas_groups=""
    local include_manual_rois=""
    local exclude_manual_rois=""
    local binary_min_density="0"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tract_name)
                tract_name="$2"
                shift 2
                ;;
            --include_atlas_groups)
                include_atlas_groups="$2"
                shift 2
                ;;
            --exclude_atlas_groups)
                exclude_atlas_groups="$2"
                shift 2
                ;;
            --include_manual_rois)
                include_manual_rois="$2"
                shift 2
                ;;
            --exclude_manual_rois)
                exclude_manual_rois="$2"
                shift 2
                ;;
            --binary_min_density)
                binary_min_density="$2"
                shift 2
                ;;
            *)
                echo "ERROR: unknown argument to extract_tract: $1" >&2
                return 1
                ;;
        esac
    done

    if [[ -z "$tract_name" ]]; then
        echo "ERROR: --tract_name is required" >&2
        return 1
    fi

    if ! [[ "$binary_min_density" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --binary_min_density must be a non-negative integer, got: '$binary_min_density'" >&2
        return 1
    fi

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
    local include_groups=()
    local exclude_groups=()

    local group
    local roi
    local roi_mif
    local token
    local base_name

    echo "=== ${tract_name} ==="
    echo "  binary min density: ${binary_min_density}"

    mrtrix mrconvert "$ATLAS_NII" "$atlas_mif" -force

    IFS=';' read -r -a include_groups <<< "$include_atlas_groups"
    for group in "${include_groups[@]}"; do
        group="$(printf '%s' "$group" | tr -d '[:space:]')"
        [[ -z "$group" ]] && continue

        token="$(sanitize_token "$group")"
        roi_mif="$roi_dir/${tract_name}_atlas_include_group_${token}.mif"
        make_atlas_group_roi "$atlas_mif" "$group" "$roi_mif"
        include_flags+=("-include" "$roi_mif")
    done

    IFS=';' read -r -a exclude_groups <<< "$exclude_atlas_groups"
    for group in "${exclude_groups[@]}"; do
        group="$(printf '%s' "$group" | tr -d '[:space:]')"
        [[ -z "$group" ]] && continue

        token="$(sanitize_token "$group")"
        roi_mif="$roi_dir/${tract_name}_atlas_exclude_group_${token}.mif"
        make_atlas_group_roi "$atlas_mif" "$group" "$roi_mif"
        exclude_flags+=("-exclude" "$roi_mif")
    done

    for roi in $include_manual_rois; do
        need_file "$roi"
        base_name="$(strip_nii_ext "$(basename "$roi")")"
        token="$(sanitize_token "$base_name")"
        roi_mif="$roi_dir/${tract_name}_manual_include_${token}.mif"
        mrtrix mrconvert "$roi" "$roi_mif" -force
        include_flags+=("-include" "$roi_mif")
    done

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
        return 1
    fi

    mrtrix tckedit "$TRACTOGRAM" "$tract_tck" \
        "${include_flags[@]}" \
        "${exclude_flags[@]}" \
        -force

    mrtrix tckmap "$tract_tck" "$density_mif" \
        -template "$TEMPLATE_IMAGE" \
        -datatype uint32 \
        -force

    mrtrix mrconvert "$density_mif" "$density_nii" -force

    if [[ "$binary_min_density" == "0" ]]; then
        mrtrix mrcalc "$density_mif" 0 -gt "$mask_mif" -force
    else
        mrtrix mrcalc "$density_mif" "$binary_min_density" -ge "$mask_mif" -force
    fi

    mrtrix mrconvert "$mask_mif" "$mask_nii" -datatype uint8 -force

    local n_streamlines
    local n_mask_voxels

    n_streamlines="$(
        { mrtrix tckinfo "$tract_tck" 2>/dev/null || true; } \
        | awk -F: '/count/ {gsub(/^[ \t]+/, "", $2); value=$2} END {print (value==""?"NA":value)}'
    )"

    n_mask_voxels="$(
        { mrtrix mrstats "$mask_mif" -output sum 2>/dev/null || true; } \
        | awk 'NR==1 {print $1}'
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
        echo "binary_min_density: ${binary_min_density}"
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

# # CST - Defined by precentral gyrus in atlas, PLIC, cerebral peduncle
# # exclude medial CC, contralateral peduncle, posterior brainstem
# extract_tract \
#     --tract_name "CST_left" \
#     --include_atlas_groups "1" \
#     --exclude_atlas_groups "" \
#     --include_manual_rois "$PLIC_LEFT_NII $PEDUNCLE_LEFT_NII" \
#     --exclude_manual_rois "$CC_MEDIAL_NII $PEDUNCLE_RIGHT_NII $POSTERIOR_BRAINSTEM_NII" \
#     --binary_min_density "20"

# extract_tract \
#     --tract_name "CST_right" \
#     --include_atlas_groups "2" \
#     --exclude_atlas_groups "" \
#     --include_manual_rois "$PLIC_RIGHT_NII $PEDUNCLE_RIGHT_NII" \
#     --exclude_manual_rois "$CC_MEDIAL_NII $PEDUNCLE_LEFT_NII $POSTERIOR_BRAINSTEM_NII" \
#     --binary_min_density "20"

# # SLFI, see supplementary Pretzel et al. 2023 (10.3389/fneur.2023.1241387)
# extract_tract \
#     --tract_name "SLFI_left" \
#     --include_atlas_groups "59,67;1,3,7,11,13,19,23" \
#     --exclude_atlas_groups "" \
#     --include_manual_rois "$DORSAL_WM_SLFI_NII" \
#     --exclude_manual_rois "$CC_MEDIAL_NII $CAPSULA_INT_EXT_NII $INFERIOR_Z40_NII" \
#     --binary_min_density "35"

# extract_tract \
#     --tract_name "SLFI_right" \
#     --include_atlas_groups "60,68;2,4,8,12,14,20,24" \
#     --exclude_atlas_groups "" \
#     --include_manual_rois "$DORSAL_WM_SLFI_NII" \
#     --exclude_manual_rois "$CC_MEDIAL_NII $CAPSULA_INT_EXT_NII $INFERIOR_Z40_NII" \
#     --binary_min_density "35"

# # SLFII, see supplementary Pretzel et al. 2023 (10.3389/fneur.2023.1241387)
# extract_tract \
#     --tract_name "SLFII_left" \
#     --include_atlas_groups "65; 1,3,7,11,13,19,23" \
#     --exclude_atlas_groups "" \
#     --include_manual_rois "" \
#     --exclude_manual_rois "$CC_MEDIAL_NII $CAPSULA_INT_EXT_NII" \
#     --binary_min_density "20"

# extract_tract \
#     --tract_name "SLFII_right" \
#     --include_atlas_groups "66;2,4,8,12,14,20,24" \
#     --exclude_atlas_groups "" \
#     --include_manual_rois "" \
#     --exclude_manual_rois "$CC_MEDIAL_NII $CAPSULA_INT_EXT_NII" \
#     --binary_min_density "20"

# # SLFIII, see supplementary Pretzel et al. 2023 (10.3389/fneur.2023.1241387)
# extract_tract \
#     --tract_name "SLFIII_left" \
#     --include_atlas_groups "63; 1,3,7,11,13,19,23" \
#     --exclude_atlas_groups "" \
#     --include_manual_rois "" \
#     --exclude_manual_rois "$CC_MEDIAL_NII" \
#     --binary_min_density "20"

# extract_tract \
#     --tract_name "SLFIII_right" \
#     --include_atlas_groups "64;2,4,8,12,14,20,24" \
#     --exclude_atlas_groups "" \
#     --include_manual_rois "" \
#     --exclude_manual_rois "$CC_MEDIAL_NII" \
#     --binary_min_density "20"

# # ILF, see Catani etl al. 2002., Neuroimage
# # Temporal lobe (Temp Inf/Mid/Sup + Pole, Fusiform) to lateral Occipital lobe
# # exclude frontal areas to exclude IFOF contamination
# extract_tract \
#     --tract_name "ILF_left" \
#     --include_atlas_groups "55,81,83,85,87,89;45,47,49,51,53" \
#     --exclude_atlas_groups "1,3,7,11,13,19,23" \
#     --include_manual_rois "" \
#     --exclude_manual_rois "$CAPSULA_EXTERNA_NII $SAGITTAL_MIDLINE_NII" \
#     --binary_min_density "35"

# extract_tract \
#     --tract_name "ILF_right" \
#     --include_atlas_groups "56,82,84,86,88,90;46,48,50,52,54" \
#     --exclude_atlas_groups "2,4,8,12,14,20,24" \
#     --include_manual_rois "" \
#     --exclude_manual_rois "$CAPSULA_EXTERNA_NII $SAGITTAL_MIDLINE_NII" \
#     --binary_min_density "35"

# # IFOF, see Catani etl al. 2002., Neuroimage
# # Lateral Frontal to posterior mid/inf temporal / lingula & fusiform occipital lobe
# extract_tract \
#     --tract_name "IFOF_left" \
#     --include_atlas_groups "3,7,11,13,15; 47,55,85,89" \
#     --exclude_atlas_groups "1,3,5,7,9,11,13,19,23" \
#     --include_manual_rois "$CAPSULA_EXTERNA_NII" \
#     --exclude_manual_rois "$CC_MEDIAL_NII" \
#     --binary_min_density "20"

# extract_tract \
#     --tract_name "IFOF_right" \
#     --include_atlas_groups "4,8,12,14,16;48,56,86,90" \
#     --exclude_atlas_groups "2,4,6,8,10,12,14,20,24" \
#     --include_manual_rois "$CAPSULA_EXTERNA_NII" \
#     --exclude_manual_rois "$CC_MEDIAL_NII" \
#     --binary_min_density "20"

#################
# Corpus Callosum
#################
# subdivision of the CC according to Hofer & Frahm 10.1016/j.neuroimage.2006.05.044
# NOTE: The AAL atlas did not provide labels to exactly define the relevant regions (e.g. premotor cortex)
#       For a practical solution, ROIs were chosen mutually exclusive, thereby slightly deviating from the Hofer & Frahm definitions
# I) prefrontal
# NOTE: Frontal mid and frontal sup were excluded here and used in CC II
extract_tract \
    --tract_name "CCI" \
    --include_atlas_groups "7,9,13,15;4,6,8,10,14,16" \
    --exclude_atlas_groups "" \
    --include_manual_rois "$CC_MEDIAL_NII" \
    --exclude_manual_rois "" \
    --binary_min_density "30"

# II) premotor and supplementary motor
# exclude region from CCI and CCIII
extract_tract \
    --tract_name "CCII" \
    --include_atlas_groups "3,7,19;4,8,20" \
    --exclude_atlas_groups "7,9,13,15;4,6,8,10,14,16;1;2" \
    --include_manual_rois "$CC_MEDIAL_NII" \
    --exclude_manual_rois "" \
    --binary_min_density "15"

# III) motor
extract_tract \
    --tract_name "CCIII" \
    --include_atlas_groups "1;2" \
    --exclude_atlas_groups "3,7,19;4,8,20;57;58" \
    --include_manual_rois "$CC_MEDIAL_NII" \
    --exclude_manual_rois "" \
    --binary_min_density "20"

# IV) sensory
extract_tract \
    --tract_name "CCIV" \
    --include_atlas_groups "57;58" \
    --exclude_atlas_groups "1;2" \
    --include_manual_rois "$CC_MEDIAL_NII" \
    --exclude_manual_rois "" \
    --binary_min_density "20"
# V) parietal, temporal, and occipital
# this is an extremely widely defined ROI. Regions were not indiscriminately included, but only the likely relevant ones
# parietal: Sup, Inf, Cuneus, Supramarginal, Angular
# temporal: Sup, Mid, Inf
# occipital: Calcarine, Cuneus, Lingual, Sup, Mid, Inf
extract_tract \
    --tract_name "CCV" \
    --include_atlas_groups "59,61,63,65,67,43,45,47,49,51,53,81,85,89;60,62,64,66,68,44,46,48,50,52,54,82,86,90" \
    --exclude_atlas_groups "57;58" \
    --include_manual_rois "$CC_MEDIAL_NII" \
    --exclude_manual_rois "" \
    --binary_min_density "20"


echo "Done."
