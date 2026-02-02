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

# -----------------------------
# REGISTRATION QC (catastrophic failure filter)
# -----------------------------
REGISTRATION_QC_THRES="${REGISTRATION_QC_THRES:-0.80}"   # Dice on brain masks in template space

# -----------------------------
# MULTI-START / FALLBACK LADDER
# -----------------------------
# Attempts are tried in order until one passes QC.
# Format: "mode|wm,gm,csf"
# mode:
#   mc  → multi-contrast (WM+GM+CSF) using -mc_weights
#   wm  → WM-only registration (no -mc_weights, no GM/CSF inputs)
ATTEMPTS=(
  "mc|1.2,0.8,1.0"
  "mc|1.5,0.75,0.75"
  "mc|2.2,0.4,0.4"
  "mc|2.6,0.4,0"
  "wm|"
)

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

OUT_DIR="$SRC_DIR/fod_to_template"
WARP_DIR="$OUT_DIR/warps"
FOD_TPL_DIR="$OUT_DIR/fod_in_template"
LOG_DIR="$OUT_DIR/logs"

# scratch for derived 3D contrasts (GM/CSF l0)
SCRATCH_DIR="$OUT_DIR/scratch_reg_contrasts"
mkdir -p "$SCRATCH_DIR"

# attempt scratch (per-subject temporary outputs; deleted on failure)
ATTEMPT_ROOT="$OUT_DIR/scratch_attempts"
mkdir -p "$ATTEMPT_ROOT"

# One arbitrary direction for sh2amp hack
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

# Log helper:
# - appends to per-subject log file
# - prints to terminal (stderr), even when stdout is captured via $(...)
log_msg() {
  local log="$1"; shift
  printf '%s\n' "$*" | tee -a "$log" >&2
}

export MRTRIX_NTHREADS

# Quick tool sanity checks
mrtrix mrregister -help >/dev/null 2>&1
mrtrix mrtransform -help >/dev/null 2>&1
mrtrix mrstats -help >/dev/null 2>&1
mrtrix mrcalc -help >/dev/null 2>&1

echo "Subject selection mode : $SUBJECT_SET"
echo "Resolved subject glob  : $SUBJECT_GLOB"
echo
echo "Templates:"
echo "  WM   : $TEMPLATE_WM_FOD"
echo "  GM   : $TEMPLATE_GM"
echo "  CSF  : $TEMPLATE_CSF"
echo "  Mask : $TEMPLATE_MASK"
echo
echo "QC:"
echo "  Dice threshold (brain mask): $REGISTRATION_QC_THRES"
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
derive_subject_paths() {
  local wm_path="$1"
  local gm_path="${wm_path/_FOD_wm_norm.mif/_FOD_gm_norm.mif}"
  local csf_path="${wm_path/_FOD_wm_norm.mif/_FOD_csf_norm.mif}"
  local mask_path="${wm_path/_FOD_wm_norm.mif/_dwi_mask.mif}"
  echo "$gm_path" "$csf_path" "$mask_path"
}

# -----------------------------
# DICE helper
# Computes Dice(A,B) = 2|A∩B| / (|A| + |B|)
# Assumes masks are in same space; will binarise with >0.
# -----------------------------
compute_dice() {
  local mask_a="$1"
  local mask_b="$2"
  local tmp_dir="$3"
  local log="$4"

  local a_bin="$tmp_dir/a_bin.mif"
  local b_bin="$tmp_dir/b_bin.mif"
  local inter="$tmp_dir/inter.mif"

  {
    mrtrix mrcalc "$mask_a" 0 -gt -force "$a_bin"
    mrtrix mrcalc "$mask_b" 0 -gt -force "$b_bin"
    mrtrix mrcalc "$a_bin" "$b_bin" -mult -force "$inter"
  } >>"$log" 2>&1

  # Count NONZERO voxels by using the image itself as mask
  local a_n b_n i_n
  a_n="$(mrtrix mrstats "$a_bin"  -mask "$a_bin"  -output count 2>>"$log" | tr -d '[:space:]' || true)"
  b_n="$(mrtrix mrstats "$b_bin"  -mask "$b_bin"  -output count 2>>"$log" | tr -d '[:space:]' || true)"
  i_n="$(mrtrix mrstats "$inter"  -mask "$inter"  -output count 2>>"$log" | tr -d '[:space:]' || true)"

  # If something went wrong, fail safe to 0
  if [[ -z "$a_n" || -z "$b_n" || -z "$i_n" || "$a_n" == "0" || "$b_n" == "0" ]]; then
    echo "0"
    return 0
  fi

  awk -v i="$i_n" -v a="$a_n" -v b="$b_n" 'BEGIN{printf "%.6f", (2.0*i)/(a+b)}'
}


# -----------------------------
# One attempt runner
# - Writes all outputs into attempt_dir
# - Returns success (0) iff registration ran AND Dice >= threshold
# - On success, prints *only* "attempt_dir|dice" to stdout for the caller
#   (all progress messages go to stderr via log_msg so terminal output doesn't "go quiet")
# -----------------------------
run_attempt() {
  local mode="$1"           # "mc" or "wm"
  local weights="$2"        # e.g. "1.5,0.75,0.75" (only for mc)
  local attempt_idx="$3"    # 1-based
  local base="$4"
  local log="$5"

  local subj_wm="$6"
  local subj_gm_l0="$7"     # precomputed 3D
  local subj_csf_l0="$8"    # precomputed 3D
  local subj_mask="$9"

  local attempt_dir="${ATTEMPT_ROOT}/${base}/attempt_${attempt_idx}"
  rm -rf "$attempt_dir"
  mkdir -p "$attempt_dir"

  local subj2tpl="$attempt_dir/${base}_subj2tpl_warp.mif"
  local tpl2subj="$attempt_dir/${base}_tpl2subj_warp.mif"
  local wm_in_tpl="$attempt_dir/${base}_in_template.mif"

  # warp subject brain mask into template space for Dice QC
  local mask_in_tpl="$attempt_dir/${base}_mask_in_template.mif"

  log_msg "$log" "  [Attempt $attempt_idx] mode=$mode weights=${weights:-NA}"
  log_msg "$log" "    -> running mrregister..."

  # Registration (do not abort script on failure)
  local rc=0
  if [[ "$mode" == "mc" ]]; then
    if mrtrix mrregister \
        -mask1 "$subj_mask" \
        -mask2 "$TEMPLATE_MASK" \
        -mc_weights "$weights" \
        -nl_warp "$subj2tpl" "$tpl2subj" \
        -force \
        "$subj_wm"      "$TEMPLATE_WM_FOD" \
        "$subj_gm_l0"   "$TEMPLATE_GM" \
        "$subj_csf_l0"  "$TEMPLATE_CSF" \
        >>"$log" 2>&1
    then
      rc=0
    else
      rc=$?
    fi
  else
    # WM-only
    if mrtrix mrregister \
        -mask1 "$subj_mask" \
        -mask2 "$TEMPLATE_MASK" \
        -nl_warp "$subj2tpl" "$tpl2subj" \
        -force \
        "$subj_wm"  "$TEMPLATE_WM_FOD" \
        >>"$log" 2>&1
    then
      rc=0
    else
      rc=$?
    fi
  fi

  if [[ "$rc" -ne 0 ]]; then
    log_msg "$log" "    -> mrregister FAILED (exit=$rc). Deleting attempt outputs."
    rm -rf "$attempt_dir"
    return 1
  fi
  log_msg "$log" "    -> mrregister finished OK."

  # Apply warp to WM FOD
  log_msg "$log" "    -> running mrtransform (WM FOD)..."
  if mrtrix mrtransform \
      "$subj_wm" \
      "$wm_in_tpl" \
      -warp "$subj2tpl" \
      -template "$TEMPLATE_WM_FOD" \
      -reorient_fod yes \
      -force >>"$log" 2>&1
  then
    :
  else
    rc=$?
    log_msg "$log" "    -> mrtransform FAILED (exit=$rc). Deleting attempt outputs."
    rm -rf "$attempt_dir"
    return 1
  fi

  # Warp subject brain mask into template space (nearest)
  log_msg "$log" "    -> warping subject brain mask to template space..."
  if mrtrix mrtransform \
      "$subj_mask" \
      "$mask_in_tpl" \
      -warp "$subj2tpl" \
      -template "$TEMPLATE_MASK" \
      -interp nearest \
      -force >>"$log" 2>&1
  then
    :
  else
    rc=$?
    log_msg "$log" "    -> mask mrtransform FAILED (exit=$rc). Deleting attempt outputs."
    rm -rf "$attempt_dir"
    return 1
  fi

  # Dice QC
  log_msg "$log" "    -> computing Dice QC..."
  local dice
  dice="$(compute_dice "$mask_in_tpl" "$TEMPLATE_MASK" "$attempt_dir" "$log")"
  log_msg "$log" "    -> QC Dice(mask) = $dice (threshold=$REGISTRATION_QC_THRES)"

  # Compare float with awk
  local pass
  pass="$(awk -v d="$dice" -v t="$REGISTRATION_QC_THRES" 'BEGIN{print (d>=t) ? 1 : 0}')"
  if [[ "$pass" -ne 1 ]]; then
    log_msg "$log" "    -> QC FAILED. Deleting attempt outputs."
    rm -rf "$attempt_dir"
    return 1
  fi

  log_msg "$log" "    -> QC PASSED."

  # Success: stdout must be machine-readable only (caller captures it)
  printf '%s|%s\n' "$attempt_dir" "$dice"
  return 0
}

for subj_wm in "${inputs[@]}"; do
  base="$(basename "$subj_wm" .mif)"
  log="$LOG_DIR/${base}_to_template.log"

  # NOTE: this truncates the per-subject log for each script run (intended).
  # Remove this line if you want to append across multiple runs.
  : >"$log"

  read -r subj_gm subj_csf subj_mask < <(derive_subject_paths "$subj_wm")

  # validate required subject side-cars exist
  [[ -f "$subj_gm"   ]] || { echo "ERROR: Missing subject GM: $subj_gm (derived from $subj_wm)" >&2; exit 1; }
  [[ -f "$subj_csf"  ]] || { echo "ERROR: Missing subject CSF: $subj_csf (derived from $subj_wm)" >&2; exit 1; }
  [[ -f "$subj_mask" ]] || { echo "ERROR: Missing subject mask: $subj_mask (derived from $subj_wm)" >&2; exit 1; }

  # These are "header" messages; keep them visible in terminal too
  log_msg "$log" "=== $base ==="
  log_msg "$log" "WM   : $subj_wm"
  log_msg "$log" "GM   : $subj_gm"
  log_msg "$log" "CSF  : $subj_csf"
  log_msg "$log" "Mask : $subj_mask"
  log_msg "$log" "QC   : Dice >= $REGISTRATION_QC_THRES"
  log_msg "$log" ""

  # -----------------------------
  # Prepare 3D scalar maps for GM/CSF once per subject (for mc attempts)
  # -----------------------------
  gm_l0="$SCRATCH_DIR/${base}_gm_l0.mif"
  csf_l0="$SCRATCH_DIR/${base}_csf_l0.mif"
  gm_tmp="$SCRATCH_DIR/${base}_gm_l0_3d_tmp.mif"
  csf_tmp="$SCRATCH_DIR/${base}_csf_l0_3d_tmp.mif"

  log_msg "$log" "  -> deriving GM/CSF l0 scalars for registration..."
  {
    mrtrix sh2amp -force "$subj_gm"  "$ONE_DIR" "$gm_l0"
    mrtrix sh2amp -force "$subj_csf" "$ONE_DIR" "$csf_l0"
    mrtrix mrconvert -coord 3 0 -axes 0,1,2 -force "$gm_l0"  "$gm_tmp"
    mrtrix mrconvert -coord 3 0 -axes 0,1,2 -force "$csf_l0" "$csf_tmp"
  } >>"$log" 2>&1

  mv -f "$gm_tmp" "$gm_l0"
  mv -f "$csf_tmp" "$csf_l0"

  # -----------------------------
  # Try attempts in order; accept first passing QC
  # -----------------------------
  accepted="0"
  accepted_attempt_dir=""
  accepted_dice=""
  accepted_mode=""
  accepted_weights=""

  attempt_idx=0
  for spec in "${ATTEMPTS[@]}"; do
    attempt_idx=$((attempt_idx + 1))
    mode="${spec%%|*}"
    weights="${spec#*|}"

    # Run attempt (stdout from run_attempt is machine-readable only)
    if out="$(run_attempt "$mode" "$weights" "$attempt_idx" "$base" "$log" \
                "$subj_wm" "$gm_l0" "$csf_l0" "$subj_mask")"; then
      accepted="1"
      accepted_attempt_dir="${out%%|*}"
      accepted_dice="${out#*|}"
      accepted_mode="$mode"
      accepted_weights="$weights"
      break
    fi
  done

  if [[ "$accepted" != "1" ]]; then
    log_msg "$log" "  => FINAL: FAILED all attempts. No output created."
    log_msg "$log" ""
    rm -rf "${ATTEMPT_ROOT:?}/${base}"
    continue
  fi

  # -----------------------------
  # Promote accepted outputs to final locations
  # -----------------------------
  final_subj2tpl="$WARP_DIR/${base}_subj2tpl_warp.mif"
  final_tpl2subj="$WARP_DIR/${base}_tpl2subj_warp.mif"
  final_wm_in_tpl="$FOD_TPL_DIR/${base}_in_template.mif"

  mv -f "$accepted_attempt_dir/${base}_subj2tpl_warp.mif" "$final_subj2tpl"
  mv -f "$accepted_attempt_dir/${base}_tpl2subj_warp.mif"  "$final_tpl2subj"
  mv -f "$accepted_attempt_dir/${base}_in_template.mif"    "$final_wm_in_tpl"

  log_msg "$log" "  => FINAL: ACCEPTED (attempt=$attempt_idx mode=$accepted_mode weights=${accepted_weights:-NA} dice=$accepted_dice)"
  log_msg "$log" "     Warp subj→tpl  : $final_subj2tpl"
  log_msg "$log" "     WM in template : $final_wm_in_tpl"
  log_msg "$log" ""

  # delete all attempt scratch for this subject to save disk
  rm -rf "${ATTEMPT_ROOT:?}/${base}"
done

echo "Done."
