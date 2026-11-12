#!/usr/bin/env bash
set -euo pipefail

# Compute FD, FC and FDC for sessions with a successful FOD registration.
# Subject fixels are matched to the common healthy-control template fixels.
# Permanent outputs: derivatives/fixel_analysis/{fd,fc,fdc}/
# Disposable intermediates: derivatives/fixel_analysis_temp/

DATA_MASTER_DIR="${DATA_MASTER_DIR:-/home/chris/projects/mld_data_master_2026}"
INVENTORY="${INVENTORY:-$DATA_MASTER_DIR/imaging_file_manifest.csv}"
DIFFUSION_DIR="$DATA_MASTER_DIR/derivatives/diffusion"
TEMPLATE_DIR="$DATA_MASTER_DIR/derivatives/fod_template_controls"
REGISTRATION_DIR="$DATA_MASTER_DIR/derivatives/fod_registration"
OUTPUT_DIR="$DATA_MASTER_DIR/derivatives/fixel_analysis"
TEMP_DIR="$DATA_MASTER_DIR/derivatives/fixel_analysis_temp"
TEMPLATE_FIXELS="$OUTPUT_DIR/template_fixels"
TEMPLATE_MASK="$TEMPLATE_DIR/template_mask_2.0mm.mif"
WARP_DIR="$REGISTRATION_DIR/warps"
STATUS="$OUTPUT_DIR/qc/fixel_metrics_status.tsv"
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"
MAX_SESSIONS="${MAX_SESSIONS:-0}"  # 0 = all inventory sessions

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -s "$INVENTORY" ]] || fail "Missing inventory: $INVENTORY"
[[ -s "$TEMPLATE_MASK" ]] || fail "Missing template mask: $TEMPLATE_MASK"
[[ -s "$TEMPLATE_FIXELS/index.mif" ]] || fail 'Missing template fixel index'
[[ -s "$TEMPLATE_FIXELS/directions.mif" ]] || fail 'Missing template fixel directions'
[[ "$MAX_SESSIONS" =~ ^[0-9]+$ ]] || fail 'MAX_SESSIONS must be a non-negative integer'
[[ "$MRTRIX_NTHREADS" =~ ^[1-9][0-9]*$ ]] || fail 'MRTRIX_NTHREADS must be positive'
command -v python3 >/dev/null || fail 'python3 unavailable'
command -v conda >/dev/null || fail 'conda unavailable'

# Multiple MRtrix commands per subject: activate once rather than using conda run repeatedly.
eval "$(conda shell.bash hook)"
conda activate "$MRTRIX_CONDA_ENV"
for cmd in mrtransform fod2fixel fixelreorient fixelcorrespondence warp2metric mrcalc; do
    command -v "$cmd" >/dev/null || fail "MRtrix command unavailable: $cmd"
done
export MRTRIX_NTHREADS

mkdir -p "$OUTPUT_DIR/qc" "$TEMP_DIR"

# These three metric directories must all refer to exactly the same fixel ordering.
for metric in fd fc fdc; do
    destination="$OUTPUT_DIR/$metric"
    mkdir -p "$destination"
    for reference in index.mif directions.mif; do
        if [[ -e "$destination/$reference" ]]; then
            cmp -s "$TEMPLATE_FIXELS/$reference" "$destination/$reference" || \
                fail "Reference fixel mismatch: $destination/$reference"
        else
            cp "$TEMPLATE_FIXELS/$reference" "$destination/$reference"
        fi
    done
done

[[ -f "$STATUS" ]] || printf 'SubjectID\tSessionID\tStatus\tDetail\n' > "$STATUS"

# Parse quoted CSV correctly; no Excluded flag (inventory has already been filtered).
SESSION_LIST="$TEMP_DIR/sessions.tsv"
python3 - "$INVENTORY" "$SESSION_LIST" <<'PY'
import csv
import re
import sys

source, destination = sys.argv[1:]
with open(source, newline="", encoding="utf-8-sig") as stream:
    reader = csv.DictReader(stream)
    if not {"SubjectID", "SessionID"}.issubset(reader.fieldnames or []):
        sys.exit("ERROR: inventory needs SubjectID and SessionID")
    sessions = []
    seen = set()
    for row in reader:
        sub = (row.get("SubjectID") or "").strip()
        ses = (row.get("SessionID") or "").strip()
        if not re.fullmatch(r"[A-Za-z0-9]+", sub) or not re.fullmatch(r"[A-Za-z0-9]+", ses):
            sys.exit(f"ERROR: invalid subject/session: {sub!r} {ses!r}")
        if (sub, ses) in seen:
            sys.exit(f"ERROR: duplicate session {sub}/{ses}")
        seen.add((sub, ses))
        sessions.append((sub, ses))
with open(destination, "w", encoding="utf-8", newline="\n") as stream:
    for sub, ses in sorted(sessions):
        stream.write(f"{sub}\t{ses}\n")
print(f"Inventory sessions: {len(sessions)}")
PY

printf 'Fixel reference : %s\n' "$TEMPLATE_FIXELS"
printf 'Output          : %s\n' "$OUTPUT_DIR"
printf 'Temporary       : %s\n' "$TEMP_DIR"
printf 'Threads         : %s\n' "$MRTRIX_NTHREADS"

processed=0
skipped=0
missing=0
failed=0
seen=0

while IFS=$'\t' read -r sub ses; do
    if (( MAX_SESSIONS > 0 && seen >= MAX_SESSIONS )); then
        break
    fi
    ((seen += 1))
    stem="sub-${sub}_ses-${ses}"
    input_fod="$DIFFUSION_DIR/sub-${sub}/ses-${ses}/fod/FOD_wm_norm.mif"
    warp="$WARP_DIR/${stem}_subject2template.mif"
    fd_out="$OUTPUT_DIR/fd/${stem}.mif"
    fc_out="$OUTPUT_DIR/fc/${stem}.mif"
    fdc_out="$OUTPUT_DIR/fdc/${stem}.mif"

    if [[ -s "$fd_out" && -s "$fc_out" && -s "$fdc_out" ]]; then
        printf 'SKIP (complete): %s\n' "$stem"
        ((skipped += 1))
        continue
    fi
    if [[ ! -s "$input_fod" || ! -s "$warp" ]]; then
        printf 'SKIP (missing FOD or accepted warp): %s\n' "$stem"
        printf '%s\t%s\tSKIPPED\tMissing FOD or subject2template warp\n' "$sub" "$ses" >> "$STATUS"
        ((missing += 1))
        continue
    fi

    printf '\n=== %s ===\n' "$stem"
    session_temp="$TEMP_DIR/$stem"
    # A failed or interrupted run leaves this folder for inspection.
    [[ ! -e "$session_temp" ]] || fail "Existing temporary folder: $session_temp (inspect/remove before retry)"
    mkdir -p "$session_temp"
    log="$session_temp/processing.log"
    printf '%s\t%s\tSTARTED\tProcessing\n' "$sub" "$ses" >> "$STATUS"

    if (
        set -e
        warped="$session_temp/fod_in_template_NOT_reoriented.mif"
        fixels_unrotated="$session_temp/fixels_unreoriented"
        fixels_rotated="$session_temp/fixels_reoriented"
        metric_fd="$session_temp/fd"
        metric_fc="$session_temp/fc"
        mkdir -p "$metric_fd" "$metric_fc"

        # Standard MRtrix FBA order: warp FOD without reorientation,
        # segment fixels, then reorient the fixels using the same warp.
        mrtransform "$input_fod" "$warped" \
            -warp "$warp" -reorient_fod no -template "$TEMPLATE_MASK"
        fod2fixel "$warped" "$fixels_unrotated" \
            -mask "$TEMPLATE_MASK" -afd fd.mif
        fixelreorient "$fixels_unrotated" "$warp" "$fixels_rotated"
        fixelcorrespondence "$fixels_rotated/fd.mif" \
            "$TEMPLATE_FIXELS" "$metric_fd" "$stem.mif"

        # FC is derived from the original subject-to-template deformation.
        warp2metric "$warp" -fc "$TEMPLATE_FIXELS" "$metric_fc" "$stem.mif"
        mrcalc "$metric_fd/$stem.mif" "$metric_fc/$stem.mif" -mult \
            "$session_temp/fdc.mif"

        for item in "$metric_fd/$stem.mif" "$metric_fc/$stem.mif" "$session_temp/fdc.mif"; do
            [[ -s "$item" ]] || exit 1
        done
    ) > "$log" 2>&1; then
        mv "$session_temp/fd/$stem.mif" "$fd_out"
        mv "$session_temp/fc/$stem.mif" "$fc_out"
        mv "$session_temp/fdc.mif" "$fdc_out"
        printf '%s\t%s\tOK\tFD FC FDC generated\n' "$sub" "$ses" >> "$STATUS"
        rm -rf -- "$session_temp"
        ((processed += 1))
        printf 'OK: %s\n' "$stem"
    else
        printf 'FAILED: %s (log: %s)\n' "$stem" "$log" >&2
        printf '%s\t%s\tFAILED\tSee temporary processing.log\n' "$sub" "$ses" >> "$STATUS"
        ((failed += 1))
    fi
done < "$SESSION_LIST"

printf '\nSummary: processed=%d already_complete=%d missing=%d failed=%d\n' \
    "$processed" "$skipped" "$missing" "$failed"
printf 'Temporary folder can be deleted after inspecting failures: %s\n' "$TEMP_DIR"
(( failed == 0 )) || exit 1
