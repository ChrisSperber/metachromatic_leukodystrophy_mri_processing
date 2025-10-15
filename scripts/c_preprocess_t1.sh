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
FRAC_LOOSE=0.20   # for quick pre-mask (bigger mask, keeps skull)
FRAC_FINAL=0.35   # for final mask after N4
GRAD=0            # BET vertical gradient (usually 0)

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
  local in="$1" out="$2" wmask="${3:-}"
  if [[ -n "$wmask" && -s "$wmask" ]]; then
    N4BiasFieldCorrection -d 3 -i "$in" -w "$wmask" -o "$out" -v 1
  else
    N4BiasFieldCorrection -d 3 -i "$in" -o "$out" -v 1
  fi
}

bet_quick_mask() {
  local in="$1" # outputs: ${in%.nii*}_head_mask.nii.gz
  bet "$in" "${in%.*.*}_head" -R -f "$FRAC_LOOSE" -g "$GRAD" -m
}

bet_final() {
  local in="$1" out_brain="$2"
  # -B cleans bias inside BET; works better *after* N4 + crop
  bet "$in" "$out_brain" -R -B -f "$FRAC_FINAL" -g "$GRAD" -m
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

echo "  - quick loose BET pre-mask (guides N4)"
bet_quick_mask "$den"
quick_mask="${den%.*.*}_head_mask.nii.gz"
[[ -s "$quick_mask" ]]

echo "  - N4 bias correction (weighted by pre-mask)"
n4corr "$den" "$bc" "$quick_mask"
[[ -s "$bc" ]]

echo "  - crop neck (helps final BET)"
bc_crop="${OUT_DIR}/${base}_bc_crop.nii.gz"
robustfov -i "$bc" -r "$bc_crop"
[[ -s "$bc_crop" ]]

echo "  - final skull strip (BET on N4-corrected, cropped image)"
bet_final "$bc_crop" "$brain"
[[ -s "$brain" ]]

# derive mask next to $brain
if [[ "$brain" == *.nii.gz ]]; then
  mask="${brain%.nii.gz}_mask.nii.gz"
else
  mask="${brain%.nii}_mask.nii.gz"
fi
[[ -s "$mask" ]]

# optional tiny fixes to avoid cortical pinholes
fslmaths "$mask" -fillh -dilM "${mask%.nii.gz}_fix.nii.gz"
if [[ -s "${mask%.nii.gz}_fix.nii.gz" ]]; then
  mask="${mask%.nii.gz}_fix.nii.gz"
fi

# sanity check mask volume
vox=$(fslstats "$mask" -V | awk '{print $1}')
if [[ -z "$vox" || "$vox" -lt 10000 ]]; then
  echo "Final BET produced a small mask ($vox voxels). Consider tweaking FRAC_FINAL." >&2
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
