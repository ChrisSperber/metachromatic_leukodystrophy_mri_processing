#!/usr/bin/env bash
set -euo pipefail

script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"

SRC_DIR="$PROJECT_DIR/temp_images"
OUT_DIR="$SRC_DIR/sri_atlas_source"

TMP_DIR="$OUT_DIR/tmp"
DTI_TMP="$TMP_DIR/dti"
LABELS_TMP="$TMP_DIR/labels"
LABELS_DIR="$OUT_DIR/labels"

DTI_URL="https://www.nitrc.org/frs/download.php/4505/sri24_dti_nifti.zip"
LABELS_URL="https://www.nitrc.org/frs/download.php/4508/sri24_labels_nifti.zip"

DTI_ZIP="$TMP_DIR/sri24_dti.zip"
LABELS_ZIP="$TMP_DIR/sri24_labels.zip"

mkdir -p "$DTI_TMP" "$LABELS_TMP" "$LABELS_DIR"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Required tool '$1' not found in PATH" >&2
        exit 1
    }
}

need_cmd curl
need_cmd unzip
need_cmd find
need_cmd cp
need_cmd rm

echo "Downloading SRI24 DTI archive..."
curl -L "$DTI_URL" -o "$DTI_ZIP"

echo "Downloading SRI24 labels archive..."
curl -L "$LABELS_URL" -o "$LABELS_ZIP"

echo "Extracting archives..."
unzip -q "$DTI_ZIP" -d "$DTI_TMP"
unzip -q "$LABELS_ZIP" -d "$LABELS_TMP"

FA_SRC="$(find "$DTI_TMP" -type f -path "*/sri24/fa.nii" | head -n 1)"

if [[ -z "$FA_SRC" ]]; then
    echo "ERROR: fa.nii not found in DTI archive." >&2
    exit 1
fi

cp -f "$FA_SRC" "$OUT_DIR/fa.nii"

echo "Copying label maps..."
find "$LABELS_TMP" -type f -path "*/sri24/*" \
    \( -name "*.nii" -o -name "*.nii.gz" -o -name "*.txt" \) \
    -exec cp -f {} "$LABELS_DIR/" \;

echo "Cleaning temporary files..."
rm -rf "$TMP_DIR"

echo "Done."
