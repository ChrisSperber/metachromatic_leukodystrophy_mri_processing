#!/usr/bin/env bash
# Collect versions of OS + key neuroimaging tools into text + JSON files.
set -euo pipefail

OUT_DIR="${1:-reports}"
mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$OUT_DIR/system_versions_${STAMP}.txt"
JSON="$OUT_DIR/system_versions_${STAMP}.json"

say() { printf '%s\n' "$1" | tee -a "$LOG" >/dev/null; }
val_or_na() { [ -n "${1:-}" ] && printf '%s' "$1" || printf 'N/A'; }

# --- OS / kernel ---
OS_NAME="N/A"; OS_VERSION="N/A"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_NAME="${NAME:-N/A}"
  OS_VERSION="${VERSION:-${VERSION_ID:-N/A}}"
fi
KERNEL="$(uname -srv || true)"

# --- FreeSurfer ---
FS_VERSION=""
if command -v recon-all >/dev/null 2>&1; then
  FS_VERSION="$(recon-all -version 2>&1 | head -n1 || true)"
elif [ -n "${FREESURFER_HOME:-}" ] && [ -r "$FREESURFER_HOME/build-stamp.txt" ]; then
  FS_VERSION="$(head -n1 "$FREESURFER_HOME/build-stamp.txt" || true)"
fi

# --- FSL ---
FSL_VERSION=""
if [ -n "${FSLDIR:-}" ] && [ -r "$FSLDIR/etc/fslversion" ]; then
  FSL_VERSION="$(cat "$FSLDIR/etc/fslversion" || true)"
elif command -v fslmaths >/dev/null 2>&1; then
  FSL_VERSION="$(fslmaths -version 2>&1 | head -n1 || true)"
fi

# --- ANTs ---
ANTS_VERSION=""
if command -v antsRegistration >/dev/null 2>&1; then
  ANTS_VERSION="$(antsRegistration --version 2>&1 | head -n1 || true)"
elif command -v ANTS >/dev/null 2>&1; then
  ANTS_VERSION="$(ANTS --version 2>&1 | head -n1 || true)"
fi

# --- GPU (optional) ---
GPU_INFO=""
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_INFO="$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
fi

# --- dump TXT ---
say "=== System & Tool Versions (${STAMP} UTC) ==="
say "OS:        ${OS_NAME} ${OS_VERSION}"
say "Kernel:    ${KERNEL}"
say "FreeSurfer: $(val_or_na "$FS_VERSION")"
say "FSL:        $(val_or_na "$FSL_VERSION")"
say "ANTs:       $(val_or_na "$ANTS_VERSION")"
say "GPU:        $(val_or_na "$GPU_INFO")"
say ""
say "FREESURFER_HOME: ${FREESURFER_HOME:-N/A}"
say "FSLDIR:          ${FSLDIR:-N/A}"

# --- dump JSON (minimal, no jq dependency) ---
cat >"$JSON" <<EOF
{
  "timestamp_utc": "$STAMP",
  "os": {
    "name": "$(printf '%s' "$OS_NAME")",
    "version": "$(printf '%s' "$OS_VERSION")",
    "kernel": "$(printf '%s' "$KERNEL")"
  },
  "tools": {
    "freesurfer": "$(val_or_na "$FS_VERSION")",
    "fsl": "$(val_or_na "$FSL_VERSION")",
    "ants": "$(val_or_na "$ANTS_VERSION")"
  },
  "env": {
    "FREESURFER_HOME": "$(printf '%s' "${FREESURFER_HOME:-N/A}")",
    "FSLDIR": "$(printf '%s' "${FSLDIR:-N/A}")"
  },
  "gpu": "$(val_or_na "$GPU_INFO")"
}
EOF

printf 'Wrote:\n- %s\n- %s\n' "$LOG" "$JSON"
