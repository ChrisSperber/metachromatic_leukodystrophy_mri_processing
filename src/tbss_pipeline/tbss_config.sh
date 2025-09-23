#!/usr/bin/env bash
set -euo pipefail

# ---------- Paths ----------
# If FSLDIR is not already set, try to detect it
if [ -z "${FSLDIR:-}" ]; then
    FSLBIN="$(which fsl 2>/dev/null || true)"
    if [ -n "$FSLBIN" ]; then
        export FSLDIR="$(dirname "$(dirname "$FSLBIN")")"
    else
        echo "ERROR: FSL not found in PATH and FSLDIR not set."
        exit 1
    fi
fi

# prepend FSLDIR to PATH
export PATH="$FSLDIR/bin:$PATH"

# Project root (this file’s dir)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT_DIR
REPO_ROOT="$(dirname "$(dirname "$ROOT_DIR")")"

# Inputs
DATA_DIR="$REPO_ROOT/temp_images"
export FA_DIR="$DATA_DIR/FA_images"
export MD_DIR="$DATA_DIR/MD_images"
export MO_DIR="$DATA_DIR/MO_images"

# Working / outputs (TBSS will create tbss directories here)
export OUTPUTS_DIR="$ROOT_DIR/outputs"

# Templates (younger cohort)
TEMPLATE_DIR="$DATA_DIR/templates"
TEMPLATE_6_12_PATH="$TEMPLATE_DIR/SACT_06_12_DT_fa.nii.gz"
TEMPLATE_11_12_PATH="$TEMPLATE_DIR/SACT_11_12_DT_fa.nii.gz"

# ---------- TBSS template choice ----------
# One of: fmrib58 | sact_6_12 | sact_11_12
export TEMPLATE_CHOICE="sact_6_12"

case "$TEMPLATE_CHOICE" in
  fmrib58)
    # Standard 1mm FMRIB58 template (-T)
    export TBSS_REG_FLAG="-T"
    export TEMPLATE_PATH=""
    ;;
  sact_6_12)
    export TBSS_REG_FLAG="-t"
    export TEMPLATE_PATH="$TEMPLATE_6_12_PATH"
    ;;
  sact_11_12)
    export TBSS_REG_FLAG="-t"
    export TEMPLATE_PATH="$TEMPLATE_11_12_PATH"
    ;;
  *)
    echo "ERROR: Unknown TEMPLATE_CHOICE '$TEMPLATE_CHOICE' (use fmrib58|sact_6_12|sact_11_12)"; exit 1;;
esac

# ---------- TBSS settings ----------
# Skeleton threshold (common default: 0.2; can be reduced to account for pathology)
export SKELETON_THR="0.15"