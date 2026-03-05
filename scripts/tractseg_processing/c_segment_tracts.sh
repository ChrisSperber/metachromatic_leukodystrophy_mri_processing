#!/usr/bin/env bash
# Run TractSeg on a folder of peak maps, and write per-subject outputs into one subfolder per subject.
#
# Requirements:
#   - TractSeg + torch are installed inside the Python venv.
#
# Input:
#   PROJECT_DIR/temp_images/Peak_images/*.nii.gz
#
# Output:
#   PROJECT_DIR/temp_images/TractSeg_outputs/<subject_base>/...
# where <subject_base> is derived from the peak filename, e.g.
#   subject_1234_date_20190724_peaks.nii.gz -> subject_1234_date_20190724
#
# Notes:
#   - Discarded TractSeg preprocessing to perform rigid alignment (FSL flirt must be on PATH) due to errors
#   - Writes multiple 3D NIfTIs (default behavior; no --single_output_file).
#   - Creates one output folder per subject.

set -euo pipefail

# -----------------------------
# USER SETTINGS
# -----------------------------

# Optional: pin GPU selection
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-}"
if [[ -n "$CUDA_VISIBLE_DEVICES" ]]; then
  export CUDA_VISIBLE_DEVICES
fi

# -----------------------------
# PATHS
# -----------------------------
script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"
SRC_DIR="$PROJECT_DIR/temp_images"

# Match your earlier folder name (case-sensitive!)
PEAK_DIR="$SRC_DIR/peak_images"
OUT_ROOT="$SRC_DIR/TractSeg_outputs"

mkdir -p "$OUT_ROOT"

echo "Project dir : $PROJECT_DIR"
echo "Peaks dir   : $PEAK_DIR"
echo "Output root : $OUT_ROOT"
if [[ -n "$CUDA_VISIBLE_DEVICES" ]]; then
  echo "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
fi
echo

# -----------------------------
# TOOL CHECKS
# -----------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required tool '$1' not found in PATH" >&2
    exit 1
  }
}

need_cmd TractSeg
need_cmd flirt

# -----------------------------
# MAIN
# -----------------------------
shopt -s nullglob

peak_files=("$PEAK_DIR"/*_peaks.nii.gz)
if [[ ${#peak_files[@]} -eq 0 ]]; then
  echo "No peak files found in: $PEAK_DIR (expected *_peaks.nii.gz)" >&2
  exit 1
fi

echo "Found ${#peak_files[@]} peak files."
echo

for peak_path in "${peak_files[@]}"; do
  fname="$(basename "$peak_path")"

  # Derive subject base name: strip trailing "_peaks.nii.gz"
  subject_base="${fname%_peaks.nii.gz}"
  subj_out="$OUT_ROOT/$subject_base"

  echo "=== ${subject_base} ==="
  echo "  Peaks : $peak_path"
  echo "  Out   : $subj_out"

  # Skip if results already exist (bundle_segmentations is a good sentinel)
  if [[ -d "$subj_out/bundle_segmentations" ]]; then
    echo "  Output already exists (bundle_segmentations present) -> skipping"
    echo
    continue
  fi

  mkdir -p "$subj_out"

  # Run TractSeg without preprocessing.
  if ! TractSeg \
      -i "$peak_path" \
      -o "$subj_out" ; then
    echo "  ERROR: TractSeg failed for $subject_base" >&2
    echo
    continue
  fi

  # Basic sanity: require bundle_segmentations output
  if [[ ! -d "$subj_out/bundle_segmentations" ]]; then
    echo "  ERROR: TractSeg finished but bundle_segmentations not found (version/flags?)" >&2
    echo
    continue
  fi

  echo "  Done."
  echo
done

echo "All done."
