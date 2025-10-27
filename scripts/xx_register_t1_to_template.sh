#!/usr/bin/env bash
# transform skull-stripped T1 MP2RAGE images to template space and store transformation matrix
# a pediatric T1 template (https://nist.mni.mcgill.ca/pediatric-atlases-4-5-18-5y/) is used
# the template is downloaded autoamtically if not found locally
set -eEuo pipefail
trap 'echo "ERROR (line $LINENO): $BASH_COMMAND" >&2' ERR

# --------- config ---------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
DATA_DIR="$PROJECT_DIR/temp_images"

T1_SEGMENTATION_DIR="$DATA_DIR/T1_images_segm"   # folder containing skull-stripped MP2RAGE
T1_NORM_OUT_DIR="$DATA_DIR/T1_images_norm"

T1_SKULLSTRIPPED_TAG="_brain.nii.gz" # tag identifying skullstripped T1 images

TEMPLATE_URL="http://www.bic.mni.mcgill.ca/~vfonov/nihpd/obj1/nihpd_asym_04.5-18.5_nifti.zip"
TEMPLATE_DIR="${DATA_DIR}/templates/NIHPD_04.5-18.5"
TEMPLATE_ZIP="${TEMPLATE_DIR}/nihpd_asym_04.5-18.5_nifti.zip"
TEMPLATE_T1_NAME="nihpd_asym_04.5-18.5_t1w.nii"  # the file we want from the zip

# antsRegistrationSyN.sh parameters:
ANTS_DIM=3
ANTS_TRANSFORM="s"       # (s = SyN, a = affine, r = rigid, so = SyN-Only)
INTERP="Linear"          # interpolation for antsApplyTransforms

# set number of cores for ANTs
num_threads=$(nproc)
if (( num_threads > 1 )); then
  num_threads=$((num_threads - 1))
fi
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$num_threads"

# --------
mkdir -p "${TEMPLATE_DIR}"
mkdir -p "${T1_NORM_OUT_DIR}"
shopt -s nullglob

# ---- tool checks ----
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Required tool '$1' not found in PATH"; exit 1; }; }
need_cmd unzip
need_cmd curl
need_cmd antsRegistrationSyN.sh
need_cmd antsApplyTransforms
need_cmd ImageMath

# -------- Ensure template T1 exists ----------
TEMPLATE_T1="${TEMPLATE_DIR}/${TEMPLATE_T1_NAME%.nii}.nii.gz"

if [[ ! -f "${TEMPLATE_T1}" ]]; then
  echo "[Template] Not found at ${TEMPLATE_T1}. Downloading…"
  # Download zip
  if [[ ! -f "${TEMPLATE_ZIP}" ]]; then
    curl -L --fail -o "${TEMPLATE_ZIP}" "${TEMPLATE_URL}"
  fi

  echo "[Template] Extracting only ${TEMPLATE_T1_NAME}…"
  # Try to extract only the T1 file directly
  if unzip -l "${TEMPLATE_ZIP}" | grep -q "${TEMPLATE_T1_NAME}"; then
    # extract that file only
    unzip -j -o "${TEMPLATE_ZIP}" "${TEMPLATE_T1_NAME}" -d "${TEMPLATE_DIR}"
  else
    # fallback: extract all, then keep only the T1
    unzip -o "${TEMPLATE_ZIP}" -d "${TEMPLATE_DIR}"
  fi

  # If we got an uncompressed .nii, compress for consistency
  if [[ -f "${TEMPLATE_DIR}/${TEMPLATE_T1_NAME}" && ! -f "${TEMPLATE_T1}" ]]; then
    echo "[Template] Gzipping ${TEMPLATE_T1_NAME}…"
    gzip -f "${TEMPLATE_DIR}/${TEMPLATE_T1_NAME}"
  fi

  # Clean other files to save space (keep only the T1 template)
  echo "[Template] Cleaning files…"
  find "${TEMPLATE_DIR}" -maxdepth 1 -type f \
    ! -name "$(basename "${TEMPLATE_T1}")" -delete
fi

[[ -f "${TEMPLATE_T1}" ]] || { echo "Template T1 not found after extraction: ${TEMPLATE_T1}" >&2; exit 4; }
echo "[Template] Using: ${TEMPLATE_T1}"

# -------- Run ANTs normalization ----------
echo "[Normalize] Scanning ${T1_SEGMENTATION_DIR} for *${T1_SKULLSTRIPPED_TAG}"

found_any=0
for in_img in "${T1_SEGMENTATION_DIR}"/*"${T1_SKULLSTRIPPED_TAG}"; do
  [[ -e "$in_img" ]] || continue
  found_any=1

  in_base="$(basename "$in_img")"
  # remove the skull-stripped tag from the tail to form a stem
  stem="${in_base%"${T1_SKULLSTRIPPED_TAG}"}"

  # outputs: transform prefix and normalized image path
  out_prefix="${T1_NORM_OUT_DIR}/${stem}_norm_"
  in_norm="${T1_NORM_OUT_DIR}/${stem}_intensity_norm_input.nii.gz" # image with additional intensity normalisation
  out_norm="${T1_NORM_OUT_DIR}/${stem}_T1warped.nii.gz"

  # transform files that antsRegistrationSyN.sh will produce
  aff_mat="${out_prefix}0GenericAffine.mat"
  warp_field="${out_prefix}1Warp.nii.gz"

  echo "[Normalize] Subject: ${stem}"
  echo "  - Moving img:   ${in_img}"

  # add quick Normalize
  ImageMath 3 "${in_norm}" Normalize "${in_img}"

  # Skip registration if transforms exist and normalized output already present
  if [[ -f "${out_norm}" && -f "${aff_mat}" && -f "${warp_field}" ]]; then
    echo "  -> Outputs already exist. Skipping registration/apply."
  else
    echo "  -> Running antsRegistrationSyN.sh"
    antsRegistrationSyN.sh \
      -d "${ANTS_DIM}" \
      -f "${TEMPLATE_T1}" \
      -m "${in_norm}" \
      -o "${out_prefix}" \
      -t "${ANTS_TRANSFORM}"

    # antsRegistrationSyN.sh writes:
    #   ${out_prefix}Warped.nii.gz (moving warped to fixed)
    #   ${out_prefix}1Warp.nii.gz, ${out_prefix}0GenericAffine.mat, ${out_prefix}InverseWarped.nii.gz, etc.

    # Apply transforms explicitly to have a consistent final name
    echo "  -> Applying transforms to produce ${out_norm}"
    antsApplyTransforms \
      -d "${ANTS_DIM}" \
      -i "${in_norm}" \
      -r "${TEMPLATE_T1}" \
      -o "${out_norm}" \
      -n "${INTERP}" \
      -t "${warp_field}" \
      -t "${aff_mat}"
  fi

  # Quick sanity check
  if [[ ! -f "${out_norm}" ]]; then
    echo "  !! Expected output not found: ${out_norm}" >&2
    exit 10
  fi

  echo "  -> Done."
done
shopt -u nullglob

if [[ "${found_any}" -eq 0 ]]; then
  echo "[Normalize] No files matching *${T1_SKULLSTRIPPED_TAG} in ${T1_SEGMENTATION_DIR}" >&2
  exit 11
fi
