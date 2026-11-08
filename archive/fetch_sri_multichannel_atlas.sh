#!/usr/bin/env bash
set -euo pipefail

# Download the SRI24 FA reference and anatomical label maps.
# Adapted from g_download_multichannel_atlas.sh; preserves its source URLs
# and the final fa.nii / labels/ layout.

DATA_MASTER_DIR="${DATA_MASTER_DIR:-/home/chris/projects/mld_data_master_2026}"
OUT_DIR="$DATA_MASTER_DIR/derivatives/sri24_atlas"
TMP_DIR="$OUT_DIR/tmp"
DTI_TMP="$TMP_DIR/dti"
LABELS_TMP="$TMP_DIR/labels"
LABELS_DIR="$OUT_DIR/labels"

DTI_URL="https://www.nitrc.org/frs/download.php/4505/sri24_dti_nifti.zip"
LABELS_URL="https://www.nitrc.org/frs/download.php/4508/sri24_labels_nifti.zip"
DTI_ZIP="$TMP_DIR/sri24_dti.zip"
LABELS_ZIP="$TMP_DIR/sri24_labels.zip"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: Required tool '$1' not found in PATH" >&2
        exit 1
    }
}

for cmd in curl unzip find cp rm mkdir; do
    need_cmd "$cmd"
done

# Do not accidentally replace an atlas already used in downstream analyses.
if [[ -e "$OUT_DIR/fa.nii" || -e "$LABELS_DIR" ]]; then
    echo "ERROR: Existing atlas outputs found in $OUT_DIR" >&2
    echo "Inspect or move these outputs before downloading again." >&2
    exit 1
fi
if [[ -e "$TMP_DIR" ]]; then
    echo "ERROR: Temporary directory already exists: $TMP_DIR" >&2
    echo "Inspect or remove it before retrying." >&2
    exit 1
fi

mkdir -p "$DTI_TMP" "$LABELS_TMP"

echo "Downloading SRI24 DTI archive..."
curl --fail --location --retry 3 --output "$DTI_ZIP" "$DTI_URL"

echo "Downloading SRI24 labels archive..."
curl --fail --location --retry 3 --output "$LABELS_ZIP" "$LABELS_URL"

# Catch common download problems (e.g. an HTML page instead of a ZIP).
unzip -tq "$DTI_ZIP" >/dev/null
unzip -tq "$LABELS_ZIP" >/dev/null

echo "Extracting archives..."
unzip -q "$DTI_ZIP" -d "$DTI_TMP"
unzip -q "$LABELS_ZIP" -d "$LABELS_TMP"

FA_SRC="$(find "$DTI_TMP" -type f -path '*/sri24/fa.nii' -print -quit)"
if [[ -z "$FA_SRC" ]]; then
    echo "ERROR: fa.nii not found in DTI archive." >&2
    exit 1
fi

# Check for label files before creating permanent outputs.
LABEL_SRC="$(find "$LABELS_TMP" -type f -path '*/sri24/*' \
    \( -name '*.nii' -o -name '*.nii.gz' -o -name '*.txt' \) -print -quit)"
if [[ -z "$LABEL_SRC" ]]; then
    echo "ERROR: No supported label files found in labels archive." >&2
    exit 1
fi

mkdir -p "$LABELS_DIR"
cp "$FA_SRC" "$OUT_DIR/fa.nii"

echo "Copying label maps..."
find "$LABELS_TMP" -type f -path '*/sri24/*' \
    \( -name '*.nii' -o -name '*.nii.gz' -o -name '*.txt' \) \
    -exec cp -t "$LABELS_DIR" -- {} +

echo "Cleaning temporary files..."
rm -rf -- "$TMP_DIR"

echo "Done. Atlas saved to: $OUT_DIR"
