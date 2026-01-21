#!/usr/bin/env bash
set -euo pipefail

# SUBJECT SELECTION
# Set to:
#   "all"      → controls + patients
#   "patients" → patients only (IDs without MLD prefix)
SUBJECT_SET="all"

MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"

TEMPLATE_VOXEL_SIZE="${TEMPLATE_VOXEL_SIZE:-2.0}"

script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"

SRC_DIR="$PROJECT_DIR/temp_images"
FOD_DIR="$SRC_DIR/FOD_images"

TPL_DIR="$SRC_DIR/fod_template"
TEMPLATE_FOD="$TPL_DIR/wm_fod_template_${TEMPLATE_VOXEL_SIZE}mm.mif"

# verify template exists
[[ -f "$TEMPLATE_FOD" ]] || { echo "ERROR: Template not found: $TEMPLATE_FOD" >&2; exit 1; }

# fetch sample patients only/all
case "$SUBJECT_SET" in
  all)
    SUBJECT_GLOB="subject_*_FOD_wm_norm.mif"
    ;;
  patients)
    SUBJECT_GLOB="subject_[0-9]*_FOD_wm_norm.mif"
    ;;
  *)
    echo "ERROR: Invalid SUBJECT_SET='$SUBJECT_SET'" >&2
    exit 1
    ;;
esac
echo "Subject selection mode : $SUBJECT_SET"
echo "Resolved subject glob  : $SUBJECT_GLOB"
echo

OUT_DIR="$SRC_DIR/fod_to_template"
WARP_DIR="$OUT_DIR/warps"
FOD_TPL_DIR="$OUT_DIR/fod_in_template"
QC_DIR="$OUT_DIR/qc_afd_nifti"
LOG_DIR="$OUT_DIR/logs"

mkdir -p "$WARP_DIR" "$FOD_TPL_DIR" "$QC_DIR" "$LOG_DIR"

mrtrix() {
  if [[ -n "$MRTRIX_CONDA_ENV" ]]; then
    if [[ "$USE_CONDA_RUN" == "1" ]]; then
      conda run -n "$MRTRIX_CONDA_ENV" "$@"
    else
      "$@"
    fi
  else
    "$@"
  fi
}

export MRTRIX_NTHREADS

# Quick tool sanity checks
mrtrix mrregister -help >/dev/null 2>&1
mrtrix mrtransform -help >/dev/null 2>&1
mrtrix fod2fixel -help >/dev/null 2>&1
mrtrix fixel2voxel -help >/dev/null 2>&1
mrtrix mrconvert -help >/dev/null 2>&1

echo "Template: $TEMPLATE_FOD"
echo "Inputs  : $FOD_DIR / $SUBJECT_GLOB"
echo "Out dir : $OUT_DIR"
echo

mapfile -t inputs < <(find "$FOD_DIR" -type f -name "$SUBJECT_GLOB" | sort)
# verify that inputs were found
if [[ "${#inputs[@]}" -eq 0 ]]; then
  echo "ERROR: No subjects matched SUBJECT_GLOB='$SUBJECT_GLOB'" >&2
  exit 1
fi
echo "Found ${#inputs[@]} inputs."

for subj_fod in "${inputs[@]}"; do
  base="$(basename "$subj_fod" .mif)"
  log="$LOG_DIR/${base}_to_template.log"

  subj2tpl="$WARP_DIR/${base}_subj2tpl_warp.mif"
  tpl2subj="$WARP_DIR/${base}_tpl2subj_warp.mif"

  fod_in_tpl="$FOD_TPL_DIR/${base}_in_template.mif"

  qc_fixel_dir="$QC_DIR/${base}_fixel"
  qc_vox_mif="$QC_DIR/${base}_AFD_voxel.mif"
  qc_nii="$QC_DIR/${base}_AFD_voxel.nii.gz"

  echo "=== $base ==="
  echo "Logging to $log"

  # 1) Registration (estimate warps)
  mrtrix mrregister \
    "$subj_fod" "$TEMPLATE_FOD" \
    -nl_warp "$subj2tpl" "$tpl2subj" \
    -force >"$log" 2>&1

  # 2) Apply warp to FOD (with reorientation)
  mrtrix mrtransform \
    "$subj_fod" \
    -warp "$subj2tpl" \
    -reorient_fod yes \
    "$fod_in_tpl" \
    -force >>"$log" 2>&1

  # 3) QC AFD in template space -> NIfTI
  rm -rf "$qc_fixel_dir"
  mkdir -p "$qc_fixel_dir"

  {
  mrtrix fod2fixel "$fod_in_tpl" "$qc_fixel_dir" -afd afd.mif -force
  mrtrix fixel2voxel "$qc_fixel_dir/afd.mif" mean "$qc_vox_mif" -force
  mrtrix mrconvert "$qc_vox_mif" "$qc_nii" -datatype float32 -force
  } >>"$log" 2>&1

  echo "  FOD in template: $fod_in_tpl"
  echo "  QC AFD NIfTI    : $qc_nii"
  echo
done

echo "Done."
