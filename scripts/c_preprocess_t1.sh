#!/usr/bin/env bash
# preprocess all T1 that were copied into /temp_images/t1, creating preprocessed images in /temp_images/T1_images_preproc
# steps: denoise -> N4 bias correction -> skull stripping -> within-brain [0,1] intensity normalization
# NOTE: FSL and ANTs are required. FSL installation is straightforward with apt. ANTs can be installed according to
# https://github.com/ANTsX/ANTs/wiki/Compiling-ANTs-on-Linux-and-Mac-OS (requiring also cmake and a c++ compiler) and adding 
# it to the PATH e.g. via echo 'export PATH="'${workingDir}'/install/bin:$PATH"' >> ~/.bashrc
set -euo pipefail

# --------- config ---------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_ROOT/temp_images"

SRC_DIR="$DATA_DIR/T1_images"           # input folder
OUT_DIR="$DATA_DIR/T1_images_preproc"   # output folder

# Skull-strip (FSL BET) parameters
FRAC=0.35   # 0.25–0.45 typical; higher = tighter/more aggressive
GRAD=0      # vertical gradient tweak (usually 0)

# -------------------------

mkdir -p "$OUT_DIR"
shopt -s nullglob

# ---- tool checks ----
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Required tool '$1' not found in PATH"; exit 1; }; }
need_cmd DenoiseImage
need_cmd N4BiasFieldCorrection
need_cmd bet
need_cmd fslstats
need_cmd fslmaths
need_cmd bc

# ---- helpers ----
denoise() {
  local in="$1" out="$2"
  # ANTs denoise (Rician-aware). No resampling, preserves header/orientation.
  DenoiseImage -d 3 -i "$in" -o "$out" -v 1
}

n4corr() {
  local in="$1" out="$2"
  # ANTs N4 bias correction
  N4BiasFieldCorrection -d 3 -i "$in" -o "$out" -v 1
}

bet_brain() {
  local in="$1" out_brain="$2" out_mask="$3"
  bet "$in" "$out_brain" -R -f "$FRAC" -g "$GRAD" -m
  # BET writes mask as ${out_brain%.*}_mask.nii.gz ; move to requested name if different
  local betmask="${out_brain%.*}_mask.nii.gz"
  [[ -f "$betmask" ]] && mv -f "$betmask" "$out_mask"
}

robust_norm_01() {
  local in="$1" mask="$2" out="$3"
  # Compute 2nd and 98th percentiles within brain
  local P2 P98 rng
  P2=$(fslstats "$in" -k "$mask" -P 2)
  P98=$(fslstats "$in" -k "$mask" -P 98)
  rng=$(echo "$P98 - $P2" | bc -l)
  # Guard against degenerate range
  if [[ $(echo "$rng <= 0" | bc -l) -eq 1 ]]; then
    echo "Warning: non-positive dynamic range (P98<=P2). Writing zero image."
    fslmaths "$in" -mul 0 -mas "$mask" "$out"
    return
  fi
  # Scale to [0,1] within brain; clamp and reapply mask to zero background
  fslmaths "$in" -sub "$P2" -div "$rng" -thr 0 -uthr 1 -mas "$mask" "$out"
}

process_one() {
  local in="$1"
  local fname base
  fname="$(basename "$in")"
  base="${fname%.nii.gz}"; base="${base%.nii}"

  local den="${OUT_DIR}/${base}_den.nii.gz"
  local bc="${OUT_DIR}/${base}_bc.nii.gz"
  local brain="${OUT_DIR}/${base}_brain.nii.gz"
  local mask="${OUT_DIR}/${base}_brain_mask.nii.gz"
  local norm="${OUT_DIR}/${base}_norm.nii.gz"

  echo ">>> $fname"
  echo "  - denoise"
  denoise "$in" "$den"
  [[ -s "$den" ]]

  echo "  - N4 bias correction"
  n4corr "$den" "$bc"
  [[ -s "$bc" ]]

  echo "  - skull strip (BET)"
  bet_brain "$bc" "$brain" "$mask"
  [[ -s "$brain" && -s "$mask" ]]

  echo "  - robust [0,1] intensity normalization (2–98% within brain)"
  robust_norm_01 "$brain" "$mask" "$norm"
  [[ -s "$norm" ]]

  echo "OK: ${norm} (mask: ${mask})"
}


# ---- main loop ----
n_found=0
for f in "$SRC_DIR"/*.nii "$SRC_DIR"/*.nii.gz; do
  [[ -e "$f" ]] || continue
  n_found=$((n_found+1))
  process_one "$f"
done

if [[ $n_found -eq 0 ]]; then
  echo "No NIfTI files found in $SRC_DIR"
else
  echo "Done. Results in: $OUT_DIR"
fi
