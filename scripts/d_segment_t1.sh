#!/usr/bin/env bash
# segment all T1 that were copied into /temp_images/T1 by SnythSeg to create a brain segmentation and a brain mask
# in /temp_images/T1_images_segm
# steps: denoise -> crop -> skull stripping -> within-brain [0,1] intensity normalization of the skull-stripped image
# NOTE: Freesurfer >v8.x, FSL, and ANTs are required. ANTs can be installed according to
# https://github.com/ANTsX/ANTs/wiki/Compiling-ANTs-on-Linux-and-Mac-OS (requiring also cmake and a c++ compiler) and adding
# it to the PATH
# Freesurfer 8.x currently (10/2025) does NOT run on Ubuntu 24
set -eEuo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR
export LC_NUMERIC=C

# --------- config ---------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
DATA_DIR="$PROJECT_DIR/temp_images"

SRC_DIR="$DATA_DIR/T1_images"           # input folder
OUT_DIR="$DATA_DIR/T1_images_segm"   # output folder

# set n threads; keep low to prevent RAM allocation errors
# threads=$(( ncores > 4 ? 2 : 1 ))
threads=1
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$threads"

# -------------------------

mkdir -p "$OUT_DIR"
shopt -s nullglob

# ---- tool checks ----
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Required tool '$1' not found in PATH"; exit 1; }; }
need_cmd DenoiseImage
need_cmd mri_synthseg
need_cmd fslmaths
need_cmd fslstats
need_cmd robustfov

# --------- helpers ----------
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

# Safe basename without double extension
base_noext() {
  local f="$1"
  f="${f##*/}"          # strip path
  f="${f%.nii.gz}"      # strip .nii.gz if present
  f="${f%.nii}"         # strip .nii if present
  printf "%s" "$f"
}

robust_norm_01() {
  local in="$1" mask="$2" out="$3"

  # Percentiles
  local P2 P98 rng
  P2=$(fslstats "$in" -k "$mask" -P 2  | awk '{printf "%.9f",$1}')
  P98=$(fslstats "$in" -k "$mask" -P 98 | awk '{printf "%.9f",$1}')
  rng=$(awk -v a="$P98" -v b="$P2" 'BEGIN{printf "%.9f", a-b}')

  if (( $(awk -v r="$rng" 'BEGIN{print (r<=0)}') )); then
    echo "Warning: non-positive dynamic range (P98<=P2). Writing zero image."
    fslmaths "$in" -mul 0 -mas "$mask" "$out"
    return
  fi

  # Normalize robustly to [0,1] inside mask
  fslmaths "$in" -sub "$P2" -div "$rng" -thr 0 -uthr 1 -mas "$mask" "$out"
}

# --------- core per-file pipeline ----------
process_one() {
  local in_t1="$1"
  local base out_den out_rob seg mask brain norm01

  base="$(base_noext "$in_t1")"

  out_den="$OUT_DIR/${base}_den.nii.gz"
  seg="$OUT_DIR/${base}_synthseg_labels.nii.gz"
  mask="$OUT_DIR/${base}_brain_mask.nii.gz"
  brain="$OUT_DIR/${base}_brain.nii.gz"
  norm01="$OUT_DIR/${base}_brain_norm01.nii.gz"

  echo "[$(timestamp)] >>> Start: $base"

  # 1) Denoise (Rician)
  if [[ ! -f "$out_den" ]]; then
    echo "[$(timestamp)]   - DenoiseImage"
    DenoiseImage -d 3 -n Rician -i "$in_t1" -o "$out_den" -v 1
  else
    echo "[$(timestamp)]   - skip denoise (exists)"
  fi

  # 2) crop neck to reduce overall image size
  out_rob="$OUT_DIR/${base}_den_rfov.nii.gz"
  robustfov -i "$out_den" -r "$out_rob"

  # 3) SynthSeg (labels). Output format is inferred from extension.
  if [[ ! -f "$seg" ]]; then
    echo "[$(timestamp)]   - SynthSeg (labels)"
    # flags: parc-cortex parcellation; keepgeom-output in original space; robust-slow but mroe robust model
    # WARNING: --robust is memory hungry and may lead to OOM; works with 10GB mem + 16GB swap
    mri_synthseg --i "$out_rob" --o "$seg" --threads "$threads" --keepgeom --parc --robust
  else
    echo "[$(timestamp)]   - skip SynthSeg (exists)"
  fi

  # 3b) Brain mask from labels (non-zero)
  if [[ ! -f "$mask" ]]; then
    echo "[$(timestamp)]   - Brain mask from labels"
    # Any label > 0 is brain; binarize
    fslmaths "$seg" -thr 1 -bin "$mask"
  else
    echo "[$(timestamp)]   - skip mask (exists)"
  fi

  # 4) Skull-strip
  if [[ ! -f "$brain" ]]; then
    echo "[$(timestamp)]   - Skull-strip"
    fslmaths "$out_rob" -mas "$mask" "$brain"
  else
    echo "[$(timestamp)]   - skip skull-strip (exists)"
  fi

  # 5) Robust [0,1] normalization within mask (2–98th pct)
  if [[ ! -f "$norm01" ]]; then
    robust_norm_01 "$out_rob" "$mask" "$norm01"
  else
    echo "[$(timestamp)]   - skip normalization (exists)"
  fi
}

# --------- main loop ----------
count=0
shopt -s nullglob
for f in "$SRC_DIR"/*.nii "$SRC_DIR"/*.nii.gz; do
  [[ -e "$f" ]] || continue
  process_one "$f"
  count=$((count+1))
done

echo "[$(timestamp)] Processed $count files into: $OUT_DIR"
