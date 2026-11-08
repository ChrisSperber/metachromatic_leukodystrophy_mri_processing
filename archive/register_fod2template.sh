#!/usr/bin/env bash
set -euo pipefail

# Register individual WM/GM/CSF FODs to the control population template.
# Based on scripts/fod_processing/d_register_fod2template.sh.
# Input sessions come from imaging_file_manifest.csv; all rows are included.
# Successful outputs are saved in derivatives/fod_registration/.
# The template is an immutable input: do not change it without rerunning registrations.

DATA_MASTER_DIR="${DATA_MASTER_DIR:-/home/chris/projects/mld_data_master_2026}"
INVENTORY="${INVENTORY:-$DATA_MASTER_DIR/imaging_file_manifest.csv}"
DIFFUSION_DIR="${DIFFUSION_DIR:-$DATA_MASTER_DIR/derivatives/diffusion}"
TEMPLATE_DIR="${TEMPLATE_DIR:-$DATA_MASTER_DIR/derivatives/fod_template_controls}"
OUT_DIR="${OUT_DIR:-$DATA_MASTER_DIR/derivatives/fod_registration}"
TEMP_DIR="${TEMP_DIR:-$DATA_MASTER_DIR/derivatives/fod_registration_temp}"
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"
TEMPLATE_VOXEL_SIZE="${TEMPLATE_VOXEL_SIZE:-2.0}"
REGISTRATION_QC_THRES="${REGISTRATION_QC_THRES:-0.80}"
SUBJECT_SET="${SUBJECT_SET:-all}"    # all | patients | controls
MAX_SESSIONS="${MAX_SESSIONS:-0}"    # 0 = all; positive integer for testing
SAVE_QC_FOD="${SAVE_QC_FOD:-0}"      # 1 = keep transformed WM FOD for visual QC

TEMPLATE_WM="$TEMPLATE_DIR/wm_fod_template_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_GM="$TEMPLATE_DIR/template_GM_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_CSF="$TEMPLATE_DIR/template_CSF_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_MASK="$TEMPLATE_DIR/template_mask_${TEMPLATE_VOXEL_SIZE}mm.mif"
WARP_DIR="$OUT_DIR/warps"
LOG_DIR="$OUT_DIR/logs"
QC_DIR="$OUT_DIR/qc"
QC_FOD_DIR="$QC_DIR/fod_in_template"
STATUS="$QC_DIR/registration_status.tsv"
INPUT_TSV="$QC_DIR/registration_inputs.tsv"
ONE_DIR="$TEMP_DIR/one_direction.txt"

# Original fallback ladder and order (mode|WM,GM,CSF weights).
ATTEMPTS=(
    'mc|1.2,0.8,1.0'
    'mc|1.5,0.75,0.75'
    'mc|2.2,0.4,0.4'
    'mc|2.6,0.4,0'
    'wm|'
)

fail() { echo "ERROR: $*" >&2; exit 1; }
log_msg() { local file="$1"; shift; printf '%s\n' "$*" | tee -a "$file" >&2; }
for file in "$INVENTORY" "$TEMPLATE_WM" "$TEMPLATE_GM" "$TEMPLATE_CSF" "$TEMPLATE_MASK"; do
    [[ -s "$file" ]] || fail "Missing or empty input: $file"
done
[[ "$SUBJECT_SET" =~ ^(all|patients|controls)$ ]] || fail 'SUBJECT_SET must be all, patients or controls'
[[ "$MAX_SESSIONS" =~ ^[0-9]+$ ]] || fail 'MAX_SESSIONS must be a nonnegative integer'
[[ "$SAVE_QC_FOD" =~ ^[01]$ ]] || fail 'SAVE_QC_FOD must be 0 or 1'
[[ "$OUT_DIR" != "$TEMP_DIR" ]] || fail 'OUT_DIR and TEMP_DIR must differ'
[[ ! -e "$TEMP_DIR" ]] || fail "Temporary directory exists: $TEMP_DIR. Check whether a previous run is active; remove stale contents manually."
command -v python3 >/dev/null || fail 'python3 not found'
command -v conda >/dev/null || fail 'conda not found'

mkdir -p "$WARP_DIR" "$LOG_DIR" "$QC_DIR" "$TEMP_DIR"
if [[ "$SAVE_QC_FOD" == 1 ]]; then mkdir -p "$QC_FOD_DIR"; fi

# Produce validated UNIX-line-ending TSV. Do not silently skip incomplete sessions.
python3 - "$INVENTORY" "$DATA_MASTER_DIR" "$DIFFUSION_DIR" "$INPUT_TSV" "$SUBJECT_SET" "$MAX_SESSIONS" <<'PY'
import csv
import re
import sys
from pathlib import Path

inventory, root, derivatives, out, subject_set, max_sessions = sys.argv[1:]
root, derivatives = Path(root).resolve(), Path(derivatives).resolve()
records, errors, seen = [], [], set()
with open(inventory, newline='', encoding='utf-8-sig') as stream:
    reader = csv.DictReader(stream)
    required = {'SubjectID', 'SessionID', 'PathMaskMIF'}
    missing = required - set(reader.fieldnames or [])
    if missing:
        sys.exit(f'ERROR: missing inventory columns: {sorted(missing)}')
    for line, row in enumerate(reader, 2):
        sub, ses = (row.get('SubjectID') or '').strip(), (row.get('SessionID') or '').strip()
        control = sub.startswith('MLD')
        if subject_set == 'controls' and not control:
            continue
        if subject_set == 'patients' and control:
            continue
        if not re.fullmatch(r'[A-Za-z0-9]+', sub) or not re.fullmatch(r'[A-Za-z0-9]+', ses):
            errors.append(f'row {line}: invalid subject/session: {sub!r}, {ses!r}')
            continue
        if (sub, ses) in seen:
            errors.append(f'row {line}: duplicate session {sub}/{ses}')
            continue
        seen.add((sub, ses))
        stem = f'sub-{sub}_ses-{ses}'
        fod = derivatives / f'sub-{sub}' / f'ses-{ses}' / 'fod'
        wm, gm, csf = (fod / f'FOD_{t}_norm.mif' for t in ('wm', 'gm', 'csf'))
        mask_str = (row.get('PathMaskMIF') or '').strip()
        mask = Path(mask_str) if mask_str else None
        if mask is not None and not mask.is_absolute():
            mask = root / mask
        records.append((sub, ses, stem, wm, gm, csf, mask))
records.sort(key=lambda r: (r[0], r[1]))
if int(max_sessions) > 0:
    records = records[:int(max_sessions)]
for sub, ses, stem, wm, gm, csf, mask in records:
    for name, path in (('WM', wm), ('GM', gm), ('CSF', csf), ('mask', mask)):
        if path is None or not path.is_file():
            errors.append(f'{stem}: missing {name}: {path}')
if not records:
    errors.append('No selected sessions found')
if errors:
    sys.exit('ERROR: validation failed:\n' + '\n'.join(errors))
with open(out, 'w', newline='', encoding='utf-8') as stream:
    writer = csv.writer(stream, delimiter='\t', lineterminator='\n')
    writer.writerow(['SubjectID', 'SessionID', 'Stem', 'WM', 'GM', 'CSF', 'Mask'])
    for rec in records:
        writer.writerow([str(v) for v in rec])
print(f'Validated {len(records)} sessions. Manifest: {out}')
PY

eval "$(conda shell.bash hook)"
conda activate "$MRTRIX_CONDA_ENV"
for cmd in mrregister mrtransform mrcalc mrstats sh2amp mrconvert; do
    command -v "$cmd" >/dev/null || fail "MRtrix command not found: $cmd"
done
export MRTRIX_NTHREADS
printf '1 0 0\n' > "$ONE_DIR"
if [[ ! -f "$STATUS" ]]; then
    printf 'SubjectID\tSessionID\tStatus\tAttempt\tMode\tWeights\tDice\tDetail\n' > "$STATUS"
fi

# Compute Dice using the same counting approach as the original, working
# d_register_fod2template.sh. In particular, strip whitespace from mrstats
# output and return Dice=0 for empty/non-overlapping masks.
compute_dice() {
    local mask_a="$1" mask_b="$2" tmp_dir="$3" log="$4"
    local a_bin="$tmp_dir/a_bin.mif"
    local b_bin="$tmp_dir/b_bin.mif"
    local inter="$tmp_dir/inter.mif"
    local a_n b_n i_n

    # Any genuine MRtrix command failure should be recorded and reported,
    # rather than treated as a registration failure deserving another attempt.
    if ! {
        mrcalc "$mask_a" 0 -gt -force "$a_bin" &&
        mrcalc "$mask_b" 0 -gt -force "$b_bin" &&
        mrcalc "$a_bin" "$b_bin" -mult -force "$inter"
    } >>"$log" 2>&1; then
        echo "ERROR: mrcalc failed during Dice QC" >>"$log"
        return 2
    fi

    # Original MRtrix behaviour: strip whitespace, tolerate empty counts,
    # and represent missing/zero mask coverage as Dice=0.
    a_n="$(mrstats "$a_bin" -mask "$a_bin" -output count 2>>"$log" | tr -d '[:space:]' || true)"
    b_n="$(mrstats "$b_bin" -mask "$b_bin" -output count 2>>"$log" | tr -d '[:space:]' || true)"
    i_n="$(mrstats "$inter" -mask "$inter" -output count 2>>"$log" | tr -d '[:space:]' || true)"

    printf 'Dice counts: A=%q B=%q intersection=%q\n' "$a_n" "$b_n" "$i_n" >>"$log"
    if [[ -z "$a_n" || -z "$b_n" || -z "$i_n" ||
          "$a_n" == 0 || "$b_n" == 0 ]]; then
        printf '0.000000\n'
        return 0
    fi

    # Avoid falsely accepting a malformed count as a real Dice value.
    local numeric='^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$'
    if [[ ! "$a_n" =~ $numeric || ! "$b_n" =~ $numeric || ! "$i_n" =~ $numeric ]]; then
        echo "ERROR: Unexpected mrstats count output" >>"$log"
        return 2
    fi
    awk -v i="$i_n" -v a="$a_n" -v b="$b_n" \
        'BEGIN {printf "%.6f\n", (2.0*i)/(a+b)}'
}

run_attempt() {
    local mode="$1" weights="$2" idx="$3" stem="$4" log="$5"
    local wm="$6" gm_l0="$7" csf_l0="$8" mask="$9" scratch="${10}"
    local dir="$scratch/attempt_$idx"
    mkdir -p "$dir"
    local subj2tpl="$dir/subject2template.mif"
    local tpl2subj="$dir/template2subject.mif"
    local mask_tpl="$dir/mask_in_template.mif"
    log_msg "$log" "  Attempt $idx: mode=$mode weights=${weights:-NA}"
    local rc=0
    if [[ "$mode" == mc ]]; then
        mrregister \
            -mask1 "$mask" -mask2 "$TEMPLATE_MASK" \
            -mc_weights "$weights" \
            -nl_warp "$subj2tpl" "$tpl2subj" -force \
            "$wm" "$TEMPLATE_WM" \
            "$gm_l0" "$TEMPLATE_GM" \
            "$csf_l0" "$TEMPLATE_CSF" >>"$log" 2>&1 || rc=$?
    else
        mrregister \
            -mask1 "$mask" -mask2 "$TEMPLATE_MASK" \
            -nl_warp "$subj2tpl" "$tpl2subj" -force \
            "$wm" "$TEMPLATE_WM" >>"$log" 2>&1 || rc=$?
    fi
    if (( rc != 0 )); then
        log_msg "$log" "    mrregister failed (exit=$rc)"
        rm -rf "$dir"
        return 1
    fi
    [[ -s "$subj2tpl" && -s "$tpl2subj" ]] || {
        log_msg "$log" '    Registration did not produce both warps'
        rm -rf "$dir"
        return 1
    }
    if ! mrtransform "$mask" "$mask_tpl" -warp "$subj2tpl" \
        -template "$TEMPLATE_MASK" -interp nearest -force >>"$log" 2>&1; then
        log_msg "$log" '    Could not transform mask for QC'
        rm -rf "$dir"
        return 1
    fi
    local dice rc=0
    dice="$(compute_dice "$mask_tpl" "$TEMPLATE_MASK" "$dir" "$log")" || rc=$?
    if (( rc != 0 )); then
        log_msg "$log" "    ERROR: Dice QC command failed (exit=$rc). See Dice counts/errors in log."
        log_msg "$log" "    Keeping attempt outputs for debugging: $dir"
        return 2
    fi
    log_msg "$log" "    Brain-mask Dice=$dice (minimum=$REGISTRATION_QC_THRES)"
    if ! awk -v d="$dice" -v t="$REGISTRATION_QC_THRES" 'BEGIN {exit !(d>=t)}'; then
        log_msg "$log" '    QC failed'
        rm -rf "$dir"
        return 1
    fi
    printf '%s|%s\n' "$dir" "$dice"
}

n_success=0
n_failed=0
n_skipped=0
while IFS=$'\t' read -r subject session stem wm gm csf mask; do
    [[ "$subject" == SubjectID ]] && continue
    subj2tpl="$WARP_DIR/${stem}_subject2template.mif"
    tpl2subj="$WARP_DIR/${stem}_template2subject.mif"
    log="$LOG_DIR/${stem}_registration.log"
    if [[ -s "$subj2tpl" && -s "$tpl2subj" ]]; then
        printf 'SKIP existing warps: %s\n' "$stem"
        n_skipped=$((n_skipped + 1))
        continue
    fi
    if [[ -e "$subj2tpl" || -e "$tpl2subj" ]]; then
        fail "Partial existing warp outputs for $stem. Inspect/remove before rerunning."
    fi
    scratch="$TEMP_DIR/$stem"
    [[ ! -e "$scratch" ]] || fail "Unexpected scratch directory for $stem: $scratch"
    mkdir -p "$scratch"
    : > "$log"
    log_msg "$log" "=== $stem ==="
    log_msg "$log" "WM: $wm"
    log_msg "$log" "GM: $gm"
    log_msg "$log" "CSF: $csf"
    log_msg "$log" "Mask: $mask"
    log_msg "$log" "Template: $TEMPLATE_WM"
    log_msg "$log" 'Deriving scalar GM/CSF contrasts...'
    # Preserve the original pipeline's GM/CSF conversion (sh2amp + 3D extraction).
    gm_l0="$scratch/gm_l0.mif"
    csf_l0="$scratch/csf_l0.mif"
    prep_ok=1
    if ! sh2amp "$gm" "$ONE_DIR" "$scratch/gm_sh2amp.mif" -force >>"$log" 2>&1 || \
       ! sh2amp "$csf" "$ONE_DIR" "$scratch/csf_sh2amp.mif" -force >>"$log" 2>&1 || \
       ! mrconvert "$scratch/gm_sh2amp.mif" "$gm_l0" -coord 3 0 -axes 0,1,2 -force >>"$log" 2>&1 || \
       ! mrconvert "$scratch/csf_sh2amp.mif" "$csf_l0" -coord 3 0 -axes 0,1,2 -force >>"$log" 2>&1; then
        prep_ok=0
    fi
    if [[ "$prep_ok" == 0 ]]; then
        log_msg "$log" 'FAILED: GM/CSF contrast preparation'
        printf '%s\t%s\tFAILED\t\t\t\t\tcontrast_preparation\n' "$subject" "$session" >> "$STATUS"
        n_failed=$((n_failed + 1))
        rm -rf "$scratch"
        continue
    fi
    accepted=0
    idx=0
    for spec in "${ATTEMPTS[@]}"; do
        idx=$((idx + 1))
        mode="${spec%%|*}"
        weights="${spec#*|}"
        attempt_rc=0
        result="$(run_attempt "$mode" "$weights" "$idx" "$stem" "$log" \
            "$wm" "$gm_l0" "$csf_l0" "$mask" "$scratch")" || attempt_rc=$?
        if (( attempt_rc == 0 )); then
            accepted=1
            break
        elif (( attempt_rc == 2 )); then
            log_msg "$log" 'FAILED: QC calculation error; not trying more registrations.'
            printf '%s\t%s\tERROR\t%s\t%s\t%s\t\tqc_calculation_error\n' \
                "$subject" "$session" "$idx" "$mode" "${weights:-NA}" >> "$STATUS"
            fail "QC calculation error for $stem. Attempt files retained: $scratch"
        fi
    done
    if [[ "$accepted" == 1 ]]; then
        accepted_dir="${result%%|*}"
        dice="${result#*|}"
        # Move BOTH warp fields. They are the primary products.
        mv "$accepted_dir/subject2template.mif" "$subj2tpl"
        mv "$accepted_dir/template2subject.mif" "$tpl2subj"
        if [[ "$SAVE_QC_FOD" == 1 ]]; then
            if ! mrtransform "$wm" "$QC_FOD_DIR/${stem}_wm_in_template.mif" \
                -warp "$subj2tpl" -template "$TEMPLATE_WM" -reorient_fod yes \
                -force >>"$log" 2>&1; then
                log_msg "$log" 'WARNING: could not write optional transformed WM FOD'
            fi
        fi
        printf '%s\t%s\tPASS\t%s\t%s\t%s\t%s\taccepted\n' \
            "$subject" "$session" "$idx" "$mode" "${weights:-NA}" "$dice" >> "$STATUS"
        log_msg "$log" "ACCEPTED: attempt=$idx mode=$mode weights=${weights:-NA} Dice=$dice"
        n_success=$((n_success + 1))
    else
        printf '%s\t%s\tFAILED\t%s\t\t\t\tall_attempts_failed\n' \
            "$subject" "$session" "$idx" >> "$STATUS"
        log_msg "$log" 'FAILED: all registration attempts'
        n_failed=$((n_failed + 1))
    fi
    rm -rf "$scratch"
done < "$INPUT_TSV"

rm -rf "$TEMP_DIR"
printf '\nFinished. PASS=%d FAILED=%d SKIPPED=%d\n' "$n_success" "$n_failed" "$n_skipped"
printf 'QC summary: %s\n' "$STATUS"
if (( n_failed > 0 )); then
    exit 1
fi
