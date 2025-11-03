#!/usr/bin/env bash
# Download skull-stripped Colin27 (ch2) and segment it with SynthSeg.
set -eEuo pipefail
trap 'echo "ERROR line $LINENO: $BASH_COMMAND" >&2' ERR

# --------- config ---------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
DATA_DIR="$PROJECT_DIR/temp_images"

OUTDIR="$DATA_DIR/ch2_pipeline_demo"
mkdir -p "$OUTDIR"

# set n threads; keep low to prevent RAM allocation errors
threads=1

# ---- tool checks ----
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Required tool '$1' not found in PATH"; exit 1; }; }
need_cmd mri_synthseg

# --- 1. Fetch ch2bet ---------------------------------------------------------
CH2="$OUTDIR/ch2.nii.gz"
URL="https://raw.githubusercontent.com/neurolabusc/MRIcron/master/Resources/templates/ch2.nii.gz"

if [[ ! -f "$CH2" ]]; then
    echo "[info] Downloading ch2.nii.gz..."
    curl -L "$URL" -o "$CH2"
else
    echo "[info] Using existing $CH2"
fi

# --- 2. Run SynthSeg ---------------------------------------------------------
# Works if either the Python entry point or the CLI is available.
OUTLABELS="$OUTDIR/ch2_synthseg_labels.nii.gz"

echo "[info] Running mri_synthseg (FreeSurfer)..."
mri_synthseg --i "$CH2" --o "$OUTLABELS" --threads "$threads" --keepgeom --parc --robust

echo "[ok] Segmentation saved to: $OUTLABELS"
