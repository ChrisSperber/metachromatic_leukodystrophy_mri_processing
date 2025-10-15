#!/usr/bin/env bash
# preprocess all T1 that were copied into /temp_images/t1, creating preprocessed images in /temp_images/T1_images_preproc
# steps: denoise -> N4 bias correction -> skull stripping -> within-brain [0,1] intensity normalization
# NOTE: FSL and ANTs are required. FSL installation is straightforward with apt. ANTs can be installed according to
# https://github.com/ANTsX/ANTs/wiki/Compiling-ANTs-on-Linux-and-Mac-OS (requiring also cmake and a c++ compiler) and adding 
# it to the PATH e.g. via echo 'export PATH="'${workingDir}'/install/bin:$PATH"' >> ~/.bashrc
set -eEuo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR
export LC_NUMERIC=C

# --------- config ---------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_ROOT/temp_images"

SRC_DIR="$DATA_DIR/T1_images"           # input folder
OUT_DIR="$DATA_DIR/T1_images_preproc"   # output folder

# Skull-strip (FSL BET) parameters
FRAC=0.5   # 0.25–0.45 typical; higher = tighter/more aggressive
GRAD=0      # vertical gradient tweak (usually 0)

ncores=$(nproc)
threads=$(( ncores > 1 ? ncores - 1 : 1 ))
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$threads"

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
  local in="$1" out_brain="$2"
  bet "$in" "$out_brain" -R -f "$FRAC" -g "$GRAD" -m
}

robust_norm_01() {
  local in="$1" mask="$2" out="$3"

  # Get percentiles and strip whitespace; format as plain decimals
  local P2 P98 rng
  P2=$(fslstats "$in" -k "$mask" -P 2  | awk '{printf "%.9f",$1}')
  P98=$(fslstats "$in" -k "$mask" -P 98 | awk '{printf "%.9f",$1}')

  # rng = P98 - P2
  rng=$(awk -v a="$P98" -v b="$P2" 'BEGIN{printf "%.9f", a-b}')

  # Guard against degenerate range
  if [[ $(awk -v r="$rng" 'BEGIN{print (r<=0)?1:0}') -eq 1 ]]; then
    echo "Warning: non-positive dynamic range (P98<=P2). Writing zero image."
    fslmaths "$in" -mul 0 -mas "$mask" "$out"
    return
  fi

  # Scale to [0,1] within brain; pass numeric literals (no quotes)
  # shellcheck disable=SC2086
  fslmaths "$in" -sub $P2 -div $rng -thr 0 -uthr 1 -mas "$mask" "$out"
}

process_one() {
  local in="$1"
  local fname base
  fname="$(basename "$in")"
  base="${fname%.nii.gz}"; base="${base%.nii}"

  local den="${OUT_DIR}/${base}_den.nii.gz"
  local bc="${OUT_DIR}/${base}_bc.nii.gz"
  local brain="${OUT_DIR}/${base}_brain.nii.gz"
  local norm="${OUT_DIR}/${base}_norm.nii.gz"

  echo ">>> $fname"
  echo "  - denoise"
  denoise "$in" "$den"
  [[ -s "$den" ]]

  echo "  - N4 bias correction"
  n4corr "$den" "$bc"
  [[ -s "$bc" ]]

  echo "  - skull strip (BET)"
  bet_brain "$bc" "$brain"
  [[ -s "$brain" ]]

# derive mask path that BET produced next to $brain
local mask
if [[ "$brain" == *.nii.gz ]]; then
  mask="${brain%.nii.gz}_mask.nii.gz"
else
  mask="${brain%.nii}_mask.nii.gz"
fi
[[ -s "$mask" ]]

  # optional: sanity check mask size
  local vox
  vox=$(fslstats "$mask" -V | awk '{print $1}')
  if [[ -z "$vox" || "$vox" -lt 10000 ]]; then
    echo "BET produced a suspiciously small mask ($vox voxels)." >&2
    return 1
  fi

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
