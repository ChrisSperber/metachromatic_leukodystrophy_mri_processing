#!/usr/bin/env bash
set -euo pipefail

# Build a control-only WM FOD population template, followed by GM/CSF
# template-space averages and an AFD QC map.
#
# Input: mld_data_master_2026/imaging_file_manifest.csv
# Controls: SubjectID begins with "MLD" (all listed sessions included).
# Required inventory columns: SubjectID, SessionID, PathMaskMIF.
# FOD inputs: derivatives/diffusion/sub-<ID>/ses-<ID>/fod/FOD_{wm,gm,csf}_norm.mif
#
# Persistent outputs: derivatives/fod_template_controls/
# Temporary processing: derivatives/fod_template_temp/
#
# The existing template is never overwritten automatically. Set a different
# TEMPLATE_DIR to create a new version; do not mix warps from different templates.

DATA_MASTER_DIR="${DATA_MASTER_DIR:-/home/chris/projects/mld_data_master_2026}"
INVENTORY="${INVENTORY:-$DATA_MASTER_DIR/imaging_file_manifest.csv}"
DIFFUSION_DIR="$DATA_MASTER_DIR/derivatives/diffusion"
TEMPLATE_DIR="${TEMPLATE_DIR:-$DATA_MASTER_DIR/derivatives/fod_template_controls}"
TEMP_DIR="${TEMP_DIR:-$DATA_MASTER_DIR/derivatives/fod_template_temp}"

MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"
TEMPLATE_VOXEL_SIZE="${TEMPLATE_VOXEL_SIZE:-2.0}"
INITIAL_ALIGNMENT="${INITIAL_ALIGNMENT:-robust_mass}"
MIN_CONTROLS="${MIN_CONTROLS:-3}"
TISSUE_INTERP="${TISSUE_INTERP:-linear}"

TEMPLATE_WM="$TEMPLATE_DIR/wm_fod_template_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_MASK="$TEMPLATE_DIR/template_mask_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_GM="$TEMPLATE_DIR/template_GM_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_CSF="$TEMPLATE_DIR/template_CSF_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_AFD="$TEMPLATE_DIR/template_AFD_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_AFD_NII="$TEMPLATE_DIR/template_AFD_${TEMPLATE_VOXEL_SIZE}mm.nii.gz"
WARP_DIR="$TEMPLATE_DIR/warps"
LOG_PATH="$TEMPLATE_DIR/population_template.log"
CONTROLS_USED="$TEMPLATE_DIR/controls_used.tsv"

INPUT_WM_DIR="$TEMP_DIR/input_controls_wm"
INPUT_MASK_DIR="$TEMP_DIR/input_controls_masks"
TRANSFORMED_GM_DIR="$TEMP_DIR/transformed_controls_gm"
TRANSFORMED_CSF_DIR="$TEMP_DIR/transformed_controls_csf"
FIXEL_DIR="$TEMP_DIR/template_fixels"
SCRATCH_DIR="$TEMP_DIR/scratch"

# Check inputs and dependencies before creating any outputs.
[[ -f "$INVENTORY" ]] || { echo "ERROR: inventory not found: $INVENTORY" >&2; exit 1; }
command -v python3 >/dev/null || { echo 'ERROR: python3 not found' >&2; exit 1; }
command -v conda >/dev/null || { echo 'ERROR: conda not found' >&2; exit 1; }
if [[ "$TEMPLATE_DIR" == "$TEMP_DIR" ]]; then
    echo 'ERROR: TEMPLATE_DIR and TEMP_DIR must differ' >&2
    exit 1
fi
if [[ -e "$TEMPLATE_WM" || -e "$TEMPLATE_MASK" || -d "$WARP_DIR" ]]; then
    echo "ERROR: template or warps already exist in $TEMPLATE_DIR" >&2
    echo 'Choose a new TEMPLATE_DIR for another template version.' >&2
    exit 1
fi

# Validate all control inputs. Never silently omit controls or sessions.
mkdir -p "$TEMPLATE_DIR"
python3 - "$INVENTORY" "$DATA_MASTER_DIR" "$DIFFUSION_DIR" "$CONTROLS_USED" "$MIN_CONTROLS" <<'PY'
import csv
import re
import sys
from pathlib import Path

inventory, data_root, diffusion_root, out, min_controls = sys.argv[1:]
data_root = Path(data_root).resolve()
diffusion_root = Path(diffusion_root).resolve()
required_columns = {"SubjectID", "SessionID", "PathMaskMIF"}
records = []
errors = []
seen = set()

with open(inventory, newline="", encoding="utf-8-sig") as stream:
    reader = csv.DictReader(stream)
    missing_columns = required_columns - set(reader.fieldnames or ())
    if missing_columns:
        sys.exit(f"ERROR: Missing inventory columns: {sorted(missing_columns)}")
    for row_number, row in enumerate(reader, start=2):
        subject = (row.get("SubjectID") or "").strip()
        if not subject.startswith("MLD"):
            continue
        session = (row.get("SessionID") or "").strip()
        if not re.fullmatch(r"[A-Za-z0-9]+", subject) or not re.fullmatch(r"[A-Za-z0-9]+", session):
            errors.append(f"row {row_number}: invalid subject/session identifier: {subject!r}, {session!r}")
            continue
        key = (subject, session)
        if key in seen:
            errors.append(f"row {row_number}: duplicate control session: {subject}/{session}")
            continue
        seen.add(key)
        stem = f"sub-{subject}_ses-{session}"
        fod_dir = diffusion_root / f"sub-{subject}" / f"ses-{session}" / "fod"
        wm = fod_dir / "FOD_wm_norm.mif"
        gm = fod_dir / "FOD_gm_norm.mif"
        csf = fod_dir / "FOD_csf_norm.mif"
        mask_value = (row.get("PathMaskMIF") or "").strip()
        mask = Path(mask_value) if mask_value else None
        if mask is not None and not mask.is_absolute():
            mask = data_root / mask
        for label, path in (("WM", wm), ("GM", gm), ("CSF", csf), ("mask", mask)):
            if path is None or not path.is_file():
                errors.append(f"row {row_number} ({stem}): missing {label}: {path}")
        records.append((subject, session, stem, wm, gm, csf, mask))

if len(records) < int(min_controls):
    errors.append(f"Found only {len(records)} control sessions (minimum: {min_controls})")
if errors:
    sys.stderr.write("ERROR: control input validation failed:\n" + "\n".join(errors) + "\n")
    sys.exit(1)

records.sort(key=lambda r: (r[0], r[1]))
with open(out, "w", newline="", encoding="utf-8") as stream:
    writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
    writer.writerow(["SubjectID", "SessionID", "Stem", "WM_FOD", "GM_FOD", "CSF_FOD", "Mask"])
    for record in records:
        writer.writerow([str(value) for value in record])
print(f"Validated {len(records)} control sessions. Manifest: {out}")
PY

# Create an empty staging area (do not overwrite an unfinished previous run).
if [[ -e "$TEMP_DIR" ]]; then
    echo "ERROR: temporary directory already exists: $TEMP_DIR" >&2
    echo 'Inspect/remove it after a failed run, or set TEMP_DIR to a fresh directory.' >&2
    exit 1
fi
mkdir -p "$INPUT_WM_DIR" "$INPUT_MASK_DIR" "$TRANSFORMED_GM_DIR" \
    "$TRANSFORMED_CSF_DIR" "$FIXEL_DIR" "$SCRATCH_DIR"

# Activate once, so commands use the same MRtrix installation.
eval "$(conda shell.bash hook)"
conda activate "$MRTRIX_CONDA_ENV"
for cmd in population_template mrtransform mrcat mrmath fod2fixel fixel2voxel mrcalc mrconvert; do
    command -v "$cmd" >/dev/null || { echo "ERROR: MRtrix command missing: $cmd" >&2; exit 1; }
done
export MRTRIX_NTHREADS

# Direct terminal output and errors into a persistent run log as well.
exec > >(tee -a "$LOG_PATH") 2>&1
printf 'Started: %s\nData: %s\nTemplate: %s\nTemporary: %s\n' \
    "$(date -Is)" "$DATA_MASTER_DIR" "$TEMPLATE_DIR" "$TEMP_DIR"
printf 'MRtrix threads: %s | voxel size: %s mm | alignment: %s\n' \
    "$MRTRIX_NTHREADS" "$TEMPLATE_VOXEL_SIZE" "$INITIAL_ALIGNMENT"

# population_template matches image/mask files by prefix. Keep same names.
while IFS=$'\t' read -r subject session stem wm gm csf mask; do
    [[ "$subject" == "SubjectID" ]] && continue
    ln -s "$wm" "$INPUT_WM_DIR/${stem}_FOD_wm_norm.mif"
    ln -s "$mask" "$INPUT_MASK_DIR/${stem}_FOD_wm_norm.mif"
    if [[ ! -e "$INPUT_MASK_DIR/${stem}_FOD_wm_norm.mif" ]]; then
        echo "ERROR: broken mask symlink for $stem" >&2
        exit 1
    fi
done < "$CONTROLS_USED"

printf '\n=== WM population template ===\n'
population_template \
    "$INPUT_WM_DIR" "$TEMPLATE_WM" \
    -voxel_size "$TEMPLATE_VOXEL_SIZE" \
    -initial_alignment "$INITIAL_ALIGNMENT" \
    -mask_dir "$INPUT_MASK_DIR" \
    -template_mask "$TEMPLATE_MASK" \
    -warp_dir "$WARP_DIR" \
    -scratch "$SCRATCH_DIR"

printf '\n=== Warp individual GM and CSF into template space ===\n'
gm_files=()
csf_files=()
# shellcheck disable=SC2034
while IFS=$'\t' read -r subject session stem wm gm csf mask; do
    [[ "$subject" == "SubjectID" ]] && continue
    warp="$WARP_DIR/${stem}_FOD_wm_norm.mif"
    if [[ ! -f "$warp" ]]; then
        echo "ERROR: population_template did not create expected warp: $warp" >&2
        exit 1
    fi
    gm_out="$TRANSFORMED_GM_DIR/${stem}_GM_in_template.mif"
    csf_out="$TRANSFORMED_CSF_DIR/${stem}_CSF_in_template.mif"
    mrtransform "$gm" "$gm_out" -warp_full "$warp" -template "$TEMPLATE_WM" \
        -interp "$TISSUE_INTERP"
    mrtransform "$csf" "$csf_out" -warp_full "$warp" -template "$TEMPLATE_WM" \
        -interp "$TISSUE_INTERP"
    gm_files+=("$gm_out")
    csf_files+=("$csf_out")
done < "$CONTROLS_USED"

printf '\n=== Mean GM and CSF templates ===\n'
mrcat "${gm_files[@]}" -axis 3 "$TEMP_DIR/GM_stack_4d.mif"
mrmath "$TEMP_DIR/GM_stack_4d.mif" mean -axis 3 "$TEMPLATE_GM"
mrcat "${csf_files[@]}" -axis 3 "$TEMP_DIR/CSF_stack_4d.mif"
mrmath "$TEMP_DIR/CSF_stack_4d.mif" mean -axis 3 "$TEMPLATE_CSF"

printf '\n=== Template AFD QC ===\n'
fod2fixel "$TEMPLATE_WM" "$FIXEL_DIR" -afd template_AFD_fixel.mif -force
fixel2voxel "$FIXEL_DIR/template_AFD_fixel.mif" mean "$TEMP_DIR/AFD_unmasked.mif"
mrcalc "$TEMP_DIR/AFD_unmasked.mif" "$TEMPLATE_MASK" -mult "$TEMPLATE_AFD"
mrconvert "$TEMPLATE_AFD" "$TEMPLATE_AFD_NII" -datatype float32

# Verify persistent outputs before deleting disposable data.
for path in "$TEMPLATE_WM" "$TEMPLATE_MASK" "$TEMPLATE_GM" "$TEMPLATE_CSF" \
    "$TEMPLATE_AFD" "$TEMPLATE_AFD_NII"; do
    [[ -s "$path" ]] || { echo "ERROR: missing or empty output: $path" >&2; exit 1; }
done
printf '\nAll persistent outputs verified. Removing temporary intermediates.\n'
rm -rf -- "$TEMP_DIR"
printf 'Finished successfully: %s\n' "$(date -Is)"
