#!/usr/bin/env bash
# rigid alignment of FA maps to skull-stripped T1 MP2RAGE images; also apply transforms to MD
set -eEuo pipefail
trap 'echo "ERROR (line $LINENO): $BASH_COMMAND" >&2' ERR

# --------- config ---------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
DATA_DIR="$PROJECT_DIR/temp_images"

FA_INPUT_DIR="$DATA_DIR/FA_images"           # input FA images
MD_INPUT_DIR="$DATA_DIR/MD_images"
OUTPUT_DIR="$DATA_DIR/DTI_images_moved_to_T1"
T1_SEGMENTATION_DIR="$DATA_DIR/T1_images_segm"   # folder containing skull-stripped MP2RAGE

T1_SKULLSTRIPPED_TAG="_MP2RAGE_brain.nii.gz" # tag identifying skullstripped T1 images
FA_TAG="_FA.nii.gz"
MD_TAG="_MD.nii.gz"
OUT_SUFFIX="toT1.nii.gz"

mkdir -p "${OUTPUT_DIR}"

# set number of cores for ANTs
num_threads=$(nproc)
if (( num_threads > 1 )); then
  num_threads=$((num_threads - 1))
fi
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$num_threads"


# ---- tool checks ----
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Required tool '$1' not found in PATH"; exit 1; }; }
need_cmd antsRegistration
need_cmd antsApplyTransforms

# -------- processing --------
count=0

for FA_PATH in "$FA_INPUT_DIR"/*"$FA_TAG"; do
    stem=$(basename "$FA_PATH" "$FA_TAG")
    T1_BRAIN="$T1_SEGMENTATION_DIR/${stem}${T1_SKULLSTRIPPED_TAG}"
    MD_PATH="$MD_INPUT_DIR/${stem}${MD_TAG}"

    [[ -f "$T1_BRAIN" ]] || { echo "[Skip] No T1 for $stem"; continue; }
    [[ -f "$MD_PATH"   ]] || { echo "[Warn] No MD for $stem — FA only"; MD_PATH=""; }

    echo "[${stem}] Rigid registration FA→T1"
    OUT_PREFIX="${OUTPUT_DIR}/${stem}_FA_"

    antsRegistration \
        --dimensionality 3 \
        --float 0 \
        --output ["${OUT_PREFIX}", "${OUT_PREFIX}${OUT_SUFFIX}"] \
        --interpolation Linear \
        --use-histogram-matching 0 \
        --winsorize-image-intensities "[0.01,0.99]" \
        --initial-moving-transform ["$T1_BRAIN","$FA_PATH",1] \
        --transform Rigid[0.1] \
        --metric MI["$T1_BRAIN","$FA_PATH",1,32,Regular,0.25] \
        --convergence "[1000x500x250x100,1e-6,10]" \
        --shrink-factors 8x4x2x1 \
        --smoothing-sigmas 3x2x1x0vox

    if [[ -n "$MD_PATH" ]]; then
        echo "[${stem}] Apply transform to MD"
        antsApplyTransforms \
        -d 3 \
        -i "$MD_PATH" \
        -r "$T1_BRAIN" \
        -n Linear \
        -t "${OUT_PREFIX}0GenericAffine.mat" \
        -o "${OUTPUT_DIR}/${stem}_MD_${OUT_SUFFIX}"
    fi

    count=$((count + 1))
done


echo "Done. Processed $count subjects."
