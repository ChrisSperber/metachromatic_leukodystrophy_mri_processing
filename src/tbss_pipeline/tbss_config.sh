#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

# ---------- Paths ----------
# If FSLDIR is not already set, try to detect it
if [ -z "${FSLDIR:-}" ]; then
    FSLBIN="$(command -v fsl || true)"
    if [ -n "$FSLBIN" ]; then
        FSLDIR="$(dirname "$(dirname "$FSLBIN")")"
    else
        echo "ERROR: FSL not found in PATH and FSLDIR not set."
        exit 1
    fi
fi
export FSLDIR

# prepend FSLDIR to PATH
export PATH="$FSLDIR/bin:$PATH"

# Project/file root
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$ROOT_DIR")")"

# Inputs
DATA_DIR="$REPO_ROOT/temp_images"
FA_DIR="$DATA_DIR/FA_images"
MD_DIR="$DATA_DIR/MD_images"
MO_DIR="$DATA_DIR/MO_images"

# Working / outputs (TBSS will create tbss directories here)
OUTPUTS_DIR="$ROOT_DIR/outputs"

# Templates (younger cohort)
TEMPLATE_DIR="$DATA_DIR/templates"
TEMPLATE_6_12_PATH="$TEMPLATE_DIR/SACT_06_12_DT_fa.nii.gz"
TEMPLATE_11_12_PATH="$TEMPLATE_DIR/SACT_11_12_DT_fa.nii.gz"

# ---------- TBSS template choice ----------
# One of: fmrib58 | sact_6_12 | sact_11_12
TEMPLATE_CHOICE="fmrib58"

case "$TEMPLATE_CHOICE" in
  fmrib58)
    # Standard 1mm FMRIB58 template (-T)
    TBSS_REG_FLAG="-T"
    TEMPLATE_PATH=""
    ;;
  sact_6_12)
    TBSS_REG_FLAG="-t"
    TEMPLATE_PATH="$TEMPLATE_6_12_PATH"
    ;;
  sact_11_12)
    TBSS_REG_FLAG="-t"
    TEMPLATE_PATH="$TEMPLATE_11_12_PATH"
    ;;
  *)
    echo "ERROR: Unknown TEMPLATE_CHOICE '$TEMPLATE_CHOICE' (use fmrib58|sact_6_12|sact_11_12)"; exit 1;;
esac

# verify existence of template file
if [ "$TBSS_REG_FLAG" = "-t" ]; then
  if [ -z "${TEMPLATE_PATH:-}" ] || [ ! -f "$TEMPLATE_PATH" ]; then
    echo "ERROR: Custom template file not found: '$TEMPLATE_PATH'"; exit 1
  fi
fi

# ---------- TBSS settings ----------
# Skeleton threshold (common default: 0.2; can be reduced to account for pathology)
SKELETON_THR="0.15"

# Optional extra thresholds (0 to n) for testing purposes; space-separated string
# e.g., "0.15 0.30" or empty ""
SKELETON_THR_TESTS="0.12 0.18 0.20"
