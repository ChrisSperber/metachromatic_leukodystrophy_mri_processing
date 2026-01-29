#!/usr/bin/env bash
set -euo pipefail

# SUBJECT SELECTION
# Set to:
#   "all"      → controls + patients
#   "patients" → patients only (IDs without MLD prefix)
SUBJECT_SET="patients"

MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"

TEMPLATE_VOXEL_SIZE="${TEMPLATE_VOXEL_SIZE:-2.0}"

# -----------------------------
# MULTI-CONTRAST REGISTRATION SETTINGS
# Order: WM, GM, CSF, e.g. "1,1,1" for equal weighting
MC_WEIGHTS="1,1,1"

script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"

SRC_DIR="$PROJECT_DIR/temp_images"
FOD_DIR="$SRC_DIR/FOD_images"

TPL_DIR="$SRC_DIR/fod_template"
TEMPLATE_WM_FOD="$TPL_DIR/wm_fod_template_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_GM="$TPL_DIR/template_GM_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_CSF="$TPL_DIR/template_CSF_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_MASK="$TPL_DIR/template_mask_${TEMPLATE_VOXEL_SIZE}mm.mif"

# verify templates exist
[[ -f "$TEMPLATE_WM_FOD" ]] || { echo "ERROR: WM template not found: $TEMPLATE_WM_FOD" >&2; exit 1; }
[[ -f "$TEMPLATE_GM"     ]] || { echo "ERROR: GM template not found: $TEMPLATE_GM" >&2; exit 1; }
[[ -f "$TEMPLATE_CSF"    ]] || { echo "ERROR: CSF template not found: $TEMPLATE_CSF" >&2; exit 1; }
[[ -f "$TEMPLATE_MASK"   ]] || { echo "ERROR: Template mask not found: $TEMPLATE_MASK" >&2; exit 1; }

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
LOG_DIR="$OUT_DIR/logs"

# images have to converted to unified number of dimensions, these are created in a scratch folder
SCRATCH_DIR="$OUT_DIR/scratch_reg_contrasts"
mkdir -p "$SCRATCH_DIR"

# mrtrix sh2amp is later used to convert 4D FODs to 3D scalar images. This requires a direction.txt file,
# for which the content is not relevant for GM/CSF. It still needs a single arbitrary direction. Hence, a
# single direction is provided here for this hacky solution.
ONE_DIR="$OUT_DIR/one_direction.txt"
echo "1 0 0" > "$ONE_DIR"

mkdir -p "$WARP_DIR" "$FOD_TPL_DIR" "$LOG_DIR"

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

echo "Templates:"
echo "  WM   : $TEMPLATE_WM_FOD"
echo "  GM   : $TEMPLATE_GM"
echo "  CSF  : $TEMPLATE_CSF"
echo "  Mask : $TEMPLATE_MASK"
echo "MC weights (WM GM CSF): $MC_WEIGHTS"
echo
echo "Inputs  : $FOD_DIR / $SUBJECT_GLOB"
echo "Out dir : $OUT_DIR"
echo

mapfile -t inputs < <(find "$FOD_DIR" -type f -name "$SUBJECT_GLOB" | sort)
if [[ "${#inputs[@]}" -eq 0 ]]; then
  echo "ERROR: No subjects matched SUBJECT_GLOB='$SUBJECT_GLOB'" >&2
  exit 1
fi
echo "Found ${#inputs[@]} inputs."
echo

# -----------------------------
# SUBJECT SIDE-CAR FILE PATTERNS
# -----------------------------
# Derive per-subject GM/CSF/mask paths from the WM filename.
derive_subject_paths() {
  local wm_path="$1"

  # GM/CSF images (assumed to live alongside WM in same folder)
  local gm_path="${wm_path/_FOD_wm_norm.mif/_FOD_gm_norm.mif}"
  local csf_path="${wm_path/_FOD_wm_norm.mif/_FOD_csf_norm.mif}"

  # Whole-brain mask from prior step (assumption: same base + suffix)
  local mask_path="${wm_path/_FOD_wm_norm.mif/_dwi_mask.mif}"

  echo "$gm_path" "$csf_path" "$mask_path"
}

for subj_wm in "${inputs[@]}"; do
  base="$(basename "$subj_wm" .mif)"
  log="$LOG_DIR/${base}_to_template.log"

  read -r subj_gm subj_csf subj_mask < <(derive_subject_paths "$subj_wm")

  # validate required subject side-cars exist
  [[ -f "$subj_gm"   ]] || { echo "ERROR: Missing subject GM: $subj_gm (derived from $subj_wm)" >&2; exit 1; }
  [[ -f "$subj_csf"  ]] || { echo "ERROR: Missing subject CSF: $subj_csf (derived from $subj_wm)" >&2; exit 1; }
  [[ -f "$subj_mask" ]] || { echo "ERROR: Missing subject mask: $subj_mask (derived from $subj_wm)" >&2; exit 1; }

  subj2tpl="$WARP_DIR/${base}_subj2tpl_warp.mif"
  tpl2subj="$WARP_DIR/${base}_tpl2subj_warp.mif"

  wm_in_tpl="$FOD_TPL_DIR/${base}_in_template.mif"

  gm_reg="$SCRATCH_DIR/${base}_gm_l0.mif"
  csf_reg="$SCRATCH_DIR/${base}_csf_l0.mif"

  echo "=== $base ==="
  echo "WM   : $subj_wm"
  echo "GM   : $subj_gm"
  echo "CSF  : $subj_csf"
  echo "Mask : $subj_mask"
  echo "Logging to $log"

  # Derive 3D isotropic maps for registration contrasts (GM / CSF)
  gm_reg="$SCRATCH_DIR/${base}_gm_l0.mif"
  csf_reg="$SCRATCH_DIR/${base}_csf_l0.mif"
  gm_tmp="$SCRATCH_DIR/${base}_gm_l0_3d_tmp.mif"
  csf_tmp="$SCRATCH_DIR/${base}_csf_l0_3d_tmp.mif"

  # 1) Sample SH at exactly one direction -> 4D with singleton 4th dim
  # shellcheck disable=SC2129
  mrtrix sh2amp -force "$subj_gm"  "$ONE_DIR" "$gm_reg"  >>"$log" 2>&1
  mrtrix sh2amp -force "$subj_csf" "$ONE_DIR" "$csf_reg" >>"$log" 2>&1

  # 2) Collapse singleton 4th dimension -> true 3D (must write to a new file)
  mrtrix mrconvert -coord 3 0 -axes 0,1,2 -force "$gm_reg"  "$gm_tmp"  >>"$log" 2>&1
  mrtrix mrconvert -coord 3 0 -axes 0,1,2 -force "$csf_reg" "$csf_tmp" >>"$log" 2>&1
  mv -f "$gm_tmp" "$gm_reg"
  mv -f "$csf_tmp" "$csf_reg"

  # 1) Multi-contrast registration (estimate warps)
  mrtrix mrregister \
  -mask1 "$subj_mask" \
  -mask2 "$TEMPLATE_MASK" \
  -mc_weights "$MC_WEIGHTS" \
  -nl_warp "$subj2tpl" "$tpl2subj" \
  -force \
  "$subj_wm"  "$TEMPLATE_WM_FOD" \
  "$gm_reg"   "$TEMPLATE_GM" \
  "$csf_reg"  "$TEMPLATE_CSF" \
  >"$log" 2>&1

  # 2) Apply warp to WM FOD (with reorientation) using the 5D non-linear warp
  mrtrix mrtransform \
    "$subj_wm" \
    "$wm_in_tpl" \
    -warp "$subj2tpl" \
    -template "$TEMPLATE_WM_FOD" \
    -reorient_fod yes \
    -force >>"$log" 2>&1


  echo "  Warp subj→tpl   : $subj2tpl"
  echo "  WM in template  : $wm_in_tpl"
  echo
done

echo "Done."
