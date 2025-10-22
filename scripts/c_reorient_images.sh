#!/usr/bin/env bash
# re-orient and clean all images across all sessions
set -euo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR
export LC_NUMERIC=C

# --- config ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
SRC_DIR="$PROJECT_DIR/temp_images"     # image folder

OVERWRITE_IN_PLACE=true    # set false to write .reoriented.nii.gz alongside originals
CLEAN_NAN_INF=true         # set false to skip NaN/Inf cleanup

# ---- tool checks ----
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Required tool '$1' not found in PATH"; exit 1; }; }
need_cmd fslreorient2std
need_cmd fslmaths

shopt -s nullglob
mapfile -t NIFTIS < <(find "$SRC_DIR" -type f -iname '*.nii.gz' -print | sort)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
rename_in_place() {
  local src="$1" tmp="$2"
  if [[ "$OVERWRITE_IN_PLACE" == true ]]; then
    mv -f -- "$tmp" "$src"
  else
    local out="${src%.*}"
    out="${out%.*}.reoriented.nii.gz"
    mv -f -- "$tmp" "$out"
  fi
}

process_one() {
  local in="$1"
  local tmp tmp2
  log "Reorient: $in"

  tmp="$(mktemp --suffix=.nii.gz)"

  # 1) Reorient to std (pure axis/header permute)
  fslreorient2std "$in" "$tmp"

  # 2) Optional: Clean NaN/Inf -> 0 (safe for all modalities)
  if [[ "$CLEAN_NAN_INF" == true ]]; then
    tmp2="$(mktemp --suffix=.nii.gz)"
    fslmaths "$tmp" -nan "$tmp2"
    mv -f -- "$tmp2" "$tmp"
  fi

  # 3) Replace or write alongside
  rename_in_place "$in" "$tmp"
}

if ((${#NIFTIS[@]}==0)); then
  log "No NIfTI files found in $SRC_DIR"
  exit 0
fi

log "Found ${#NIFTIS[@]} NIfTI file(s)"
for f in "${NIFTIS[@]}"; do
  process_one "$f"
done

log "Done."
