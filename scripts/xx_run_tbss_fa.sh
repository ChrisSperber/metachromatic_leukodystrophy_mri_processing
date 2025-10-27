#!/usr/bin/env bash
set -euo pipefail

# ── Helpers ────────────────────────────────────────────────────────────────────
log() { printf "[%s] %s\n" "$(date '+%F %T')" "$*"; }
die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }
SECONDS=0

# ── Locate & source config ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="$SCRIPT_DIR/../src/tbss_pipeline/tbss_config.sh"
[ -f "$CONFIG_PATH" ] || die "Config not found at $CONFIG_PATH"
# shellcheck source=/dev/null
source "$CONFIG_PATH"

# ── Sanity checks (FA inputs & FSL tools) ─────────────────────────────────────
for cmd in tbss_1_preproc tbss_2_reg; do
  command -v "$cmd" >/dev/null || die "$cmd not on PATH (is FSL installed?)"
done

[ -d "$FA_DIR" ] || die "FA_DIR does not exist: $FA_DIR"

# Collect FA inputs
mapfile -t FA_FILES < <(find "$FA_DIR" -type f -name '*.nii*' | sort)
((${#FA_FILES[@]} > 0)) || die "No FA files found under $FA_DIR"

# ── Prepare working directory for this run ────────────────────────────────────
# TBSS writes into the *current* directory. We keep a fixed dir (outputs/tbss)
# so that step B (non-FA) can reuse its contents reliably.
RUNSTAMP=$(date '+%Y%m%d_%H%M%S')
TBSS_DIR="$OUTPUTS_DIR/tbss_$RUNSTAMP"
mkdir -p "$TBSS_DIR"
cd "$TBSS_DIR"

# log to file
LOGFILE="$TBSS_DIR/tbss_fa_$RUNSTAMP.log"
exec > >(tee -a "$LOGFILE") 2>&1

log "Starting TBSS FA stage in $TBSS_DIR"
log "Using template choice: $TEMPLATE_CHOICE (flag: $TBSS_REG_FLAG)"
[ "${TBSS_REG_FLAG}" = "-t" ] && log "Custom template: $TEMPLATE_PATH"
log "Skeleton threshold: $SKELETON_THR"
log "Number of FA files: ${#FA_FILES[@]}"

# ── Provenance files to make outputs reusable later ────────────────────────────
# 1) Save the exact FA file list. Step B will rely on this list.
MANIFEST="$TBSS_DIR/FA_file_manifest.tsv"
{
  echo -e "basename\tabs_path"
  for f in "${FA_FILES[@]}"; do
    echo -e "$(basename "$f")\t$(readlink -f "$f")"
  done
} > "$MANIFEST"
log "Wrote manifest: $MANIFEST"

# 2) Save run parameters for reproducibility & for step B to echo back.
PARAMS="$TBSS_DIR/params.txt"
{
  echo "TEMPLATE_CHOICE=$TEMPLATE_CHOICE"
  echo "TBSS_REG_FLAG=$TBSS_REG_FLAG"
  echo "TEMPLATE_PATH=${TEMPLATE_PATH:-}"
  echo "SKELETON_THR=$SKELETON_THR"
  echo "RUN_STARTED=$(date -Iseconds)"
} > "$PARAMS"
log "Wrote params: $PARAMS"

# additional provenance
GIT_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'NA')"
FSL_VER="$(fslversion 2>/dev/null || echo 'NA')"
HOST="$(hostname 2>/dev/null || echo 'NA')"
{
  echo "GIT_COMMIT=$GIT_COMMIT"
  echo "FSL_VERSION=$FSL_VER"
  echo "HOSTNAME=$HOST"
} >> "$PARAMS"

# Stage inputs with plain basenames so tbss_1_preproc is happy
STAGING="$TBSS_DIR/incoming"
mkdir -p "$STAGING"
for f in "${FA_FILES[@]}"; do
  ln -s "$f" "$STAGING/$(basename "$f")"
done

# ── TBSS FA pipeline ──────────────────────────────────────────────────────────
# Preprocess: copies/normalizes inputs into FA/origdata keeping the filenames.
log "tbss_1_preproc ..."
( cd "$STAGING" && tbss_1_preproc ./*.nii* )

# bring FA/ back to the run dir so steps 2–4 can see it here
mv "$STAGING/FA" "$TBSS_DIR/"
rm -rf "$STAGING"

# Registration: built-in FMRIB58 (-T) or custom (-t <template>)
if [ "$TBSS_REG_FLAG" = "-T" ]; then
  log "tbss_2_reg -T ..."
  tbss_2_reg -T
else
  log "tbss_2_reg -t \"$TEMPLATE_PATH\" ..."
  tbss_2_reg -t "$TEMPLATE_PATH"
fi

# Post-registration + create mean FA, skeleton, and distance map
log "tbss_3_postreg -S ..."
tbss_3_postreg -S

# Create skeleton mask at your chosen threshold (REUSED by non-FA step)
log "tbss_4_prestats $SKELETON_THR ..."
tbss_4_prestats "$SKELETON_THR"

# OPTIONAL: Apply additional TBSS FA thresholds and generate outputs in a subfolder
if [ -n "${SKELETON_THR_TESTS:-}" ]; then
  EXTRA_DIR="$TBSS_DIR/extra_thresholds"
  mkdir -p "$EXTRA_DIR"

  # split the string into an array
  read -r -a TEST_THRS <<< "$SKELETON_THR_TESTS"

  SKELETON_SRC="stats/mean_FA_skeleton.nii.gz"
  [ -f "$SKELETON_SRC" ] || die "Expected skeleton at $SKELETON_SRC (run step 3/4 first)."

  for THR in "${TEST_THRS[@]}"; do
    # basic validation: 0 < thr < 1
    [[ "$THR" =~ ^0\.[0-9]+$|^1\.0+$ ]] || log "Warn: odd threshold '$THR'"
    tag="${THR/./}"  # 0.15 -> 015
    out="$EXTRA_DIR/mean_FA_skeleton_mask_thresh_${tag}.nii.gz"

    # New mask: skeleton voxels with FA >= THR
    fslmaths "$SKELETON_SRC" -thr "$THR" -bin "$out" \
      || die "Failed to make extra mask for THR=$THR"

    log "Extra mask: $out"
  done
fi

# ── Minimal integrity checks (files Step B depends on) ────────────────────────
REQUIRED=(
  "stats/mean_FA.nii.gz"
  "stats/mean_FA_skeleton.nii.gz"
  "stats/mean_FA_skeleton_mask.nii.gz"
  "stats/mean_FA_skeleton_mask_dst.nii.gz"
)
for p in "${REQUIRED[@]}"; do
  [ -e "$p" ] || die "Missing required TBSS output: $TBSS_DIR/$p"
done

# Mark completion time
echo "RUN_COMPLETED=$(date -Iseconds)" >> "$PARAMS"
DURATION=$SECONDS
printf -v DURATION_STR '%dh:%dm:%ds' \
  $((DURATION/3600)) $(( (DURATION%3600)/60 )) $((DURATION%60))
log "TBSS FA stage completed in $DURATION_STR"
log "QC: Please visually verify registration and skeleton!"
