#!/usr/bin/env bash
# align SSFP images and register to T1
set -eEuo pipefail
trap 'echo "ERROR (line $LINENO): $BASH_COMMAND" >&2' ERR

# --------- config ---------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"
DATA_DIR="$PROJECT_DIR/temp_images"

SSFP_INPUT_DIR="$DATA_DIR/SSFP_images"
OUTPUT_DIR="$DATA_DIR/SSFP_images_moved_to_T1"
T1_SEGMENTATION_DIR="$DATA_DIR/T1_images_segm" # folder containing skull-stripped MP2RAGE

T1_SKULLSTRIPPED_TAG="_MP2RAGE_brain.nii.gz" # tag identifying skullstripped T1 images
SSFP_200_TAG="_SSFP_200.nii.gz"
SSFP_1500_TAG="_SSFP_1500.nii.gz"
OUT_SUFFIX="toT1.nii.gz" # final output suffix

mkdir -p "${OUTPUT_DIR}"

# set number of cores for ANTs
num_threads=$(nproc)
if (( num_threads > 1 )); then
  num_threads=$((num_threads - 1))
fi
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$num_threads"

shopt -s nullglob

# ---- tool checks ----
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Required tool '$1' not found in PATH"; exit 1; }; }
need_cmd antsRegistration
need_cmd antsApplyTransforms

# -------- processing --------
count=0

for SSFP_200_PATH in "$SSFP_INPUT_DIR"/*"$SSFP_200_TAG"; do
    stem=$(basename "$SSFP_200_PATH" "$SSFP_200_TAG")

    T1_BRAIN="$T1_SEGMENTATION_DIR/${stem}${T1_SKULLSTRIPPED_TAG}"
    SSFP_1500_PATH="$SSFP_INPUT_DIR/${stem}${SSFP_1500_TAG}"

    if [[ ! -f "$T1_BRAIN" ]]; then
        echo "[Skip] No T1 for $stem"
        continue
    fi

    if [[ -f "$SSFP_1500_PATH" ]]; then
        echo "[${stem}] Found SSFP 200 and 1500 µs images"
    else
        echo "[${stem}] Only SSFP 200 µs image found (no 1500 µs)"
    fi

    # per-subject temp dir (all intermediate ANTs files live here)
    TMP_SUBDIR=$(mktemp -d "${OUTPUT_DIR}/${stem}_tmp_XXXXXX")

    # 1) Rigid: SSFP 1500 → SSFP 200
    if [[ -f "$SSFP_1500_PATH" ]]; then
        echo "[${stem}] Rigid registration SSFP 1500 → SSFP 200"

        OUT_PREFIX_1500="${TMP_SUBDIR}/${stem}_SSFP1500_to_SSFP200_"

        antsRegistration \
        --dimensionality 3 \
        --float 0 \
        --output "[${OUT_PREFIX_1500},${OUT_PREFIX_1500}Warped.nii.gz]" \
        --interpolation Linear \
        --use-histogram-matching 0 \
        --winsorize-image-intensities "[0.01,0.99]" \
        --initial-moving-transform "[${SSFP_200_PATH},${SSFP_1500_PATH},1]" \
        --transform "Rigid[0.1]" \
        --metric "MI[${SSFP_200_PATH},${SSFP_1500_PATH},1,32,Regular,0.25]" \
        --convergence "[1000x500x250x100,1e-6,10]" \
        --shrink-factors 8x4x2x1 \
        --smoothing-sigmas 3x2x1x0vox
    fi

    # 2) Rigid: SSFP 200 → T1
    echo "[${stem}] Rigid registration SSFP 200 → T1"

        OUT_PREFIX_200="${TMP_SUBDIR}/${stem}_SSFP200_to_T1_"

        antsRegistration \
        --dimensionality 3 \
        --float 0 \
        --output "[${OUT_PREFIX_200},${OUT_PREFIX_200}Warped.nii.gz]" \
        --interpolation Linear \
        --use-histogram-matching 0 \
        --winsorize-image-intensities "[0.01,0.99]" \
        --initial-moving-transform "[${T1_BRAIN},${SSFP_200_PATH},1]" \
        --transform "Rigid[0.1]" \
        --metric "MI[${T1_BRAIN},${SSFP_200_PATH},1,32,Regular,0.25]" \
        --convergence "[1000x500x250x100,1e-6,10]" \
        --shrink-factors 8x4x2x1 \
        --smoothing-sigmas 3x2x1x0vox
    # transform: ${OUT_PREFIX_200}0GenericAffine.mat

    # 3) Apply transform(s) to get final outputs in T1 space

    # 3a) SSFP 200 → T1 (single rigid transform)
    echo "[${stem}] Apply transform to SSFP 200 (to T1 space)"
    antsApplyTransforms \
        -d 3 \
        -i "$SSFP_200_PATH" \
        -r "$T1_BRAIN" \
        -n Linear \
        -t "${OUT_PREFIX_200}0GenericAffine.mat" \
        -o "${OUTPUT_DIR}/${stem}_SSFP_200_${OUT_SUFFIX}"

    # 3b) SSFP 1500 → T1 (compose 1500→200 and 200→T1)
    if [[ -f "$SSFP_1500_PATH" ]]; then
        echo "[${stem}] Apply composed transforms to SSFP 1500 (to T1 space)"
        # Note: antsApplyTransforms applies transforms in reverse order of listing:
        # here, 1500→200 is applied first, then 200→T1.
        antsApplyTransforms \
            -d 3 \
            -i "$SSFP_1500_PATH" \
            -r "$T1_BRAIN" \
            -n Linear \
            -t "${OUT_PREFIX_200}0GenericAffine.mat" \
            -t "${OUT_PREFIX_1500}0GenericAffine.mat" \
            -o "${OUTPUT_DIR}/${stem}_SSFP_1500_${OUT_SUFFIX}"
    fi

    # cleanup intermediate files
    rm -rf "$TMP_SUBDIR"

    count=$((count + 1))
done

echo "Done. Processed $count subjects."
