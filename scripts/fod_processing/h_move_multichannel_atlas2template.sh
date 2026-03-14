#!/usr/bin/env bash
# Register SRI24 FA to the project mean FA template and move selected SRI24
# atlas label maps into template space using ANTs.
#
# Inputs:
#   - temp_images/FA_template/template_FA_2.0mm.nii.gz
#   - temp_images/sri_atlas_source/fa.nii
#   - temp_images/sri_atlas_source/labels/lpba40.nii
#   - temp_images/sri_atlas_source/labels/tzo116plus.nii
#   - temp_images/sri_atlas_source/labels/suptent.nii
#
# Outputs:
#   - temp_images/sri_atlas_template/sri24_FA_in_template.nii.gz
#   - temp_images/sri_atlas_template/sri24_to_template_0GenericAffine.mat
#   - temp_images/sri_atlas_template/sri24_to_template_1Warp.nii.gz
#   - temp_images/sri_atlas_template/lpba40_in_template.nii.gz
#   - temp_images/sri_atlas_template/tzo116plus_in_template.nii.gz
#   - temp_images/sri_atlas_template/suptent_in_template.nii.gz

set -eEuo pipefail
trap 'echo "ERROR (line $LINENO): $BASH_COMMAND" >&2' ERR

# -----------------------------
# PATHS
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"
DATA_DIR="$PROJECT_DIR/temp_images"

FA_TEMPLATE_DIR="$DATA_DIR/FA_template"
ATLAS_SRC_DIR="$DATA_DIR/sri_atlas_source"
ATLAS_LABELS_DIR="$ATLAS_SRC_DIR/labels"

OUTPUT_DIR="$DATA_DIR/sri_atlas_template"
mkdir -p "$OUTPUT_DIR"

TEMPLATE_FA="$FA_TEMPLATE_DIR/template_FA_2.0mm.nii.gz"
SRI_FA="$ATLAS_SRC_DIR/fa.nii"

LPBA40_ATLAS="$ATLAS_LABELS_DIR/lpba40.nii"
TZO116PLUS_ATLAS="$ATLAS_LABELS_DIR/tzo116plus.nii"
SUPTENT_ATLAS="$ATLAS_LABELS_DIR/suptent.nii"

# Output prefix for ANTs
OUT_PREFIX="$OUTPUT_DIR/sri24_to_template_"

# Main outputs
WARPED_SRI_FA="${OUTPUT_DIR}/sri24_FA_in_template.nii.gz"
LPBA40_OUT="${OUTPUT_DIR}/lpba40_in_template.nii.gz"
TZO116PLUS_OUT="${OUTPUT_DIR}/tzo116plus_in_template.nii.gz"
SUPTENT_OUT="${OUTPUT_DIR}/suptent_in_template.nii.gz"

echo "Project dir      : $PROJECT_DIR"
echo "Data dir         : $DATA_DIR"
echo "Template FA      : $TEMPLATE_FA"
echo "SRI24 FA         : $SRI_FA"
echo "Atlas labels dir : $ATLAS_LABELS_DIR"
echo "Output dir       : $OUTPUT_DIR"
echo "LPBA40 atlas     : $LPBA40_ATLAS"
echo "TZO116PLUS atlas : $TZO116PLUS_ATLAS"
echo "SUPTENT mask     : $SUPTENT_ATLAS"
echo

# -----------------------------
# THREADS
# -----------------------------
num_threads=$(nproc)
if (( num_threads > 1 )); then
  num_threads=$((num_threads - 1))
fi
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$num_threads"

# -----------------------------
# TOOL CHECKS
# -----------------------------
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Required tool '$1' not found in PATH" >&2
        exit 1
    }
}

need_cmd antsRegistration
need_cmd antsApplyTransforms

# -----------------------------
# INPUT CHECKS
# -----------------------------
[[ -f "$TEMPLATE_FA" ]] || { echo "Missing template FA: $TEMPLATE_FA" >&2; exit 1; }
[[ -f "$SRI_FA" ]] || { echo "Missing SRI24 FA: $SRI_FA" >&2; exit 1; }
[[ -f "$LPBA40_ATLAS" ]] || { echo "Missing LPBA40 atlas: $LPBA40_ATLAS" >&2; exit 1; }
[[ -f "$TZO116PLUS_ATLAS" ]] || { echo "Missing TZO116PLUS atlas: $TZO116PLUS_ATLAS" >&2; exit 1; }
[[ -f "$SUPTENT_ATLAS" ]] || { echo "Missing supratentorial mask: $SUPTENT_ATLAS" >&2; exit 1; }

# -----------------------------
# 1) REGISTER SRI24 FA -> TEMPLATE FA
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
# 2) APPLY TRANSFORM TO LABEL MAPS
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
