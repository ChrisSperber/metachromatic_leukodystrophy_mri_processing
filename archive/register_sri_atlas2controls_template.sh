#!/usr/bin/env bash
# Register SRI24 FA to the project mean FA template and move selected SRI24
# atlas label maps into template space using ANTs.
# Adapted from h_move_multichannel_atlas2template.sh (original registration unchanged).
set -eEuo pipefail
trap 'echo "ERROR (line $LINENO): $BASH_COMMAND" >&2' ERR

# -----------------------------
# PATHS
# -----------------------------
DATA_MASTER_DIR="/home/chris/projects/mld_data_master_2026"
DERIVATIVES_DIR="$DATA_MASTER_DIR/derivatives"

FA_TEMPLATE_DIR="$DERIVATIVES_DIR/fod_template_controls/fa_template"
ATLAS_SRC_DIR="$DERIVATIVES_DIR/sri24_atlas"
ATLAS_LABELS_DIR="$ATLAS_SRC_DIR/labels"
OUTPUT_DIR="$DERIVATIVES_DIR/sri24_in_fod_template"
mkdir -p "$OUTPUT_DIR"

TEMPLATE_FA="$FA_TEMPLATE_DIR/template_FA_2.0mm.nii.gz"
SRI_FA="$ATLAS_SRC_DIR/fa.nii"
LPBA40_ATLAS="$ATLAS_LABELS_DIR/lpba40.nii"
TZO116PLUS_ATLAS="$ATLAS_LABELS_DIR/tzo116plus.nii"
SUPTENT_ATLAS="$ATLAS_LABELS_DIR/suptent.nii"

OUT_PREFIX="$OUTPUT_DIR/sri24_to_template_"
WARPED_SRI_FA="${OUTPUT_DIR}/sri24_FA_in_template.nii.gz"
LPBA40_OUT="${OUTPUT_DIR}/lpba40_in_template.nii.gz"
TZO116PLUS_OUT="${OUTPUT_DIR}/tzo116plus_in_template.nii.gz"
SUPTENT_OUT="${OUTPUT_DIR}/suptent_in_template.nii.gz"

echo "Data master      : $DATA_MASTER_DIR"
echo "Template FA      : $TEMPLATE_FA"
echo "SRI24 FA         : $SRI_FA"
echo "Atlas labels dir : $ATLAS_LABELS_DIR"
echo "Output dir       : $OUTPUT_DIR"
echo "LPBA40 atlas     : $LPBA40_ATLAS"
echo "TZO116PLUS atlas : $TZO116PLUS_ATLAS"
echo "SUPTENT mask     : $SUPTENT_ATLAS"
echo

# -----------------------------
# THREADS (unchanged)
# -----------------------------
num_threads=$(nproc)
if (( num_threads > 1 )); then
    num_threads=$((num_threads - 1))
fi
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$num_threads"

# -----------------------------
# TOOL AND INPUT CHECKS (unchanged)
# -----------------------------
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Required tool '$1' not found in PATH" >&2
        exit 1
    }
}
need_cmd antsRegistration
need_cmd antsApplyTransforms

[[ -f "$TEMPLATE_FA" ]] || { echo "Missing template FA: $TEMPLATE_FA" >&2; exit 1; }
[[ -f "$SRI_FA" ]] || { echo "Missing SRI24 FA: $SRI_FA" >&2; exit 1; }
[[ -f "$LPBA40_ATLAS" ]] || { echo "Missing LPBA40 atlas: $LPBA40_ATLAS" >&2; exit 1; }
[[ -f "$TZO116PLUS_ATLAS" ]] || { echo "Missing TZO116PLUS atlas: $TZO116PLUS_ATLAS" >&2; exit 1; }
[[ -f "$SUPTENT_ATLAS" ]] || { echo "Missing supratentorial mask: $SUPTENT_ATLAS" >&2; exit 1; }

# -----------------------------
# 1) REGISTER SRI24 FA -> TEMPLATE FA (unchanged)
# -----------------------------
echo "Registering SRI24 FA to template FA..."
antsRegistration \
    --dimensionality 3 \
    --float 0 \
    --output "[${OUT_PREFIX},${WARPED_SRI_FA}]" \
    --interpolation Linear \
    --use-histogram-matching 1 \
    --winsorize-image-intensities "[0.01,0.99]" \
    --initial-moving-transform "[${TEMPLATE_FA},${SRI_FA},1]" \
    \
    --transform "Rigid[0.1]" \
    --metric "MI[${TEMPLATE_FA},${SRI_FA},1,32,Regular,0.25]" \
    --convergence "[1000x500x250x100,1e-6,10]" \
    --shrink-factors 8x4x2x1 \
    --smoothing-sigmas 3x2x1x0vox \
    \
    --transform "Affine[0.1]" \
    --metric "MI[${TEMPLATE_FA},${SRI_FA},1,32,Regular,0.25]" \
    --convergence "[1000x500x250x100,1e-6,10]" \
    --shrink-factors 8x4x2x1 \
    --smoothing-sigmas 3x2x1x0vox \
    \
    --transform "SyN[0.1,3,0]" \
    --metric "CC[${TEMPLATE_FA},${SRI_FA},1,4]" \
    --convergence "[100x70x50x20,1e-6,10]" \
    --shrink-factors 8x4x2x1 \
    --smoothing-sigmas 3x2x1x0vox

echo "Registration done."
echo "Warped SRI24 FA:"
echo "  $WARPED_SRI_FA"
echo "Transforms:"
echo "  ${OUT_PREFIX}0GenericAffine.mat"
echo "  ${OUT_PREFIX}1Warp.nii.gz"
echo

# -----------------------------
# 2) APPLY TRANSFORM TO LABEL MAPS (unchanged)
# -----------------------------
echo "Warping LPBA40 atlas to template space..."
antsApplyTransforms \
    -d 3 \
    -i "$LPBA40_ATLAS" \
    -r "$TEMPLATE_FA" \
    -n NearestNeighbor \
    -t "${OUT_PREFIX}1Warp.nii.gz" \
    -t "${OUT_PREFIX}0GenericAffine.mat" \
    -o "$LPBA40_OUT"

echo "Warping TZO116PLUS atlas to template space..."
antsApplyTransforms \
    -d 3 \
    -i "$TZO116PLUS_ATLAS" \
    -r "$TEMPLATE_FA" \
    -n NearestNeighbor \
    -t "${OUT_PREFIX}1Warp.nii.gz" \
    -t "${OUT_PREFIX}0GenericAffine.mat" \
    -o "$TZO116PLUS_OUT"

echo "Warping supratentorial mask to template space..."
antsApplyTransforms \
    -d 3 \
    -i "$SUPTENT_ATLAS" \
    -r "$TEMPLATE_FA" \
    -n NearestNeighbor \
    -t "${OUT_PREFIX}1Warp.nii.gz" \
    -t "${OUT_PREFIX}0GenericAffine.mat" \
    -o "$SUPTENT_OUT"

echo
echo "Done."
echo "Main outputs:"
echo "  $WARPED_SRI_FA"
echo "  ${OUT_PREFIX}0GenericAffine.mat"
echo "  ${OUT_PREFIX}1Warp.nii.gz"
echo "  $LPBA40_OUT"
echo "  $TZO116PLUS_OUT"
echo "  $SUPTENT_OUT"
