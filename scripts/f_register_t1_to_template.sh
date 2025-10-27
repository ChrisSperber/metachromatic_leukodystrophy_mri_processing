#!/usr/bin/env bash
# transform skull-stripped T1 MP2RAGE images to template space and store transformation matrix
# a pediatric T1 template (https://nist.mni.mcgill.ca/pediatric-atlases-4-5-18-5y/) is used
# the template is downloaded autoamtically if not found locally
set -eEuo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# --------- config ---------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
DATA_DIR="$PROJECT_DIR/temp_images"

#T1_SEGMENTATION_DIR="$DATA_DIR/T1_images_segm"   # folder containing skull-stripped MP2RAGE

TEMPLATE_URL="http://www.bic.mni.mcgill.ca/~vfonov/nihpd/obj1/nihpd_asym_04.5-18.5_nifti.zip"
TEMPLATE_DIR="${DATA_DIR}/templates/NIHPD_04.5-18.5"
TEMPLATE_ZIP="${TEMPLATE_DIR}/nihpd_asym_04.5-18.5_nifti.zip"
TEMPLATE_T1_NAME="nihpd_asym_04.5-18.5_t1w.nii"  # the file we want from the zip

# --------
mkdir -p "${TEMPLATE_DIR}"


# ---- tool checks ----
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Required tool '$1' not found in PATH"; exit 1; }; }
need_cmd unzip
need_cmd curl

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
