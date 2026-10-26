#!/usr/bin/env bash
# Match b=0 signal intensities between separately acquired DWI shells.
# Source paths come from imaging_file_manifest.csv (relative to DATA_MASTER_DIR).
# Default: inspect only. Use --process to write corrected MIFs.
# Original files are never overwritten or deleted.
set -euo pipefail

# -----------------------------
# USER SETTINGS / PATHS
# -----------------------------
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_DIR="$(realpath "$SCRIPT_DIR/../..")"
DATA_MASTER_DIR="$PROJECTS_DIR/mld_data_master_2026"
INVENTORY_CSV="$DATA_MASTER_DIR/imaging_file_manifest.csv"
TEMP_PARENT_DIR="$PROJECTS_DIR/dwi_processing_tmp"
REPORT_CSV="$DATA_MASTER_DIR/dwi_b0_matching_report.csv"

# Explicitly approved layouts from inspection of the 85-session dataset:
# A: b0 x2, b2000 x64, b700 x30, b0 x1; 64 sessions
# B: b0 x1, b700 x30, b0 x1, b2000 x64; 19 sessions
# C: interspersed b0; 2 sessions -> skip unchanged
# Output files are named <original-stem>_b0matched.mif
QC_WARN_PERCENT="${QC_WARN_PERCENT:-3.0}"

MODE="${1:---inspect}"
if [[ "$MODE" != "--inspect" && "$MODE" != "--process" ]]; then
    echo "Usage: $0 [--inspect|--process]" >&2
    exit 2
fi

# -----------------------------
# ENVIRONMENT
# -----------------------------
command -v conda >/dev/null || { echo "Conda is not on PATH" >&2; exit 1; }
eval "$(conda shell.bash hook)"
conda activate "$MRTRIX_CONDA_ENV"
for cmd in mrinfo mrconvert mrmath mrstats dwicat python3; do
    command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done
[[ -f "$INVENTORY_CSV" ]] || { echo "Manifest not found: $INVENTORY_CSV" >&2; exit 1; }
mkdir -p "$TEMP_PARENT_DIR"

# Whole-run scratch area for a compact log and safe CSV parsing.
RUN_TMP="$(mktemp -d "$TEMP_PARENT_DIR/b0_run_XXXXXXXX")"
trap 'rm -rf -- "$RUN_TMP"' EXIT
ROWS_TSV="$RUN_TMP/manifest_rows.tsv"
REPORT_TSV="$RUN_TMP/report.tsv"
printf 'SubjectID\tSessionID\tPattern\tStatus\tInputMIF\tOutputMIF\tB0RatioBefore\tB0RatioAfter\tNotes\n' > "$REPORT_TSV"

# Parse real CSV with Python, rejecting tabs/newlines so TSV transfer stays safe.
python3 - "$INVENTORY_CSV" "$ROWS_TSV" <<'PY'
import csv
import sys
from pathlib import Path
src, dest = map(Path, sys.argv[1:])
with src.open(newline='', encoding='utf-8-sig') as f:
    rows = list(csv.DictReader(f))
required = ('SubjectID', 'SessionID', 'PathDWIMIF', 'PathMaskMIF')
if rows and any(x not in rows[0] for x in required):
    raise ValueError(f'Missing required manifest column: {required}')
with dest.open('w', encoding='utf-8') as out:
    for r in rows:
        fields = [(r.get(col) or '').strip() for col in required]
        if any('\t' in x or '\r' in x or '\n' in x for x in fields):
            raise ValueError('Tabs/newlines in manifest fields are not supported')
        out.write('\t'.join(fields) + '\n')
PY

# Shell classification is tolerant of small floating-point b-value deviations.
# Match the COMPLETE run-length pattern, never only the volume count.
classify_gradients() {
    python3 - "$1" <<'PY'
import itertools
import sys
from pathlib import Path
p = Path(sys.argv[1])
bvals = []
for line in p.read_text().splitlines():
    parts = line.split()
    if len(parts) != 4:
        raise ValueError('Invalid gradient row')
    b = float(parts[3])
    if abs(b) < 100:
        bvals.append(0)
    elif abs(b - 700) < 100:
        bvals.append(700)
    elif abs(b - 2000) < 200:
        bvals.append(2000)
    else:
        bvals.append(-1)
pattern = [(shell, sum(1 for _ in group)) for shell, group in itertools.groupby(bvals)]
A = [(0,2),(2000,64),(700,30),(0,1)]
B = [(0,1),(700,30),(0,1),(2000,64)]
C = [(0,2),(2000,10),(0,1),(2000,10),(0,1),(2000,11),(0,1),
     (2000,11),(0,1),(2000,11),(0,1),(2000,11),(0,1),
     (700,10),(0,1),(700,11),(0,1),(700,9),(0,1)]
print('A' if pattern == A else 'B' if pattern == B else 'C' if pattern == C else 'UNKNOWN')
PY
}

# Mean of masked voxel means from reference b0 volumes (same mask for both scans).
# Reports b2000 / b700; independent of acquisition ordering.
b0_ratio() {
    local dwi="$1" mask="$2" pattern="$3" work="$4"
    local -a high low
    case "$pattern" in
        A) high=(0 1); low=(96) ;;
        B) high=(31); low=(0) ;;
        *) return 1 ;;
    esac
    # Each QC pass uses its own scratch folder to avoid stale extracted b0 volumes.
    mkdir -p -- "$work"
    local idx m
    local -a means_high=() means_low=()
    for idx in "${high[@]}"; do
        mrconvert "$dwi" "$work/b0_h_${idx}.mif" -coord 3 "$idx" -quiet
        m="$(mrstats "$work/b0_h_${idx}.mif" -mask "$mask" -output mean -quiet)"
        means_high+=("$m")
    done
    for idx in "${low[@]}"; do
        mrconvert "$dwi" "$work/b0_l_${idx}.mif" -coord 3 "$idx" -quiet
        m="$(mrstats "$work/b0_l_${idx}.mif" -mask "$mask" -output mean -quiet)"
        means_low+=("$m")
    done
    python3 - "${#means_high[@]}" "${means_high[@]}" "${#means_low[@]}" "${means_low[@]}" <<'PY'
import sys
xs = list(map(float, sys.argv[1:]))
n_h = int(xs[0]); high = xs[1:1+n_h]
rest = xs[1+n_h:]; n_l = int(rest[0]); low = rest[1:1+n_l]
if len(low) != n_l or min(high + low) <= 0:
    raise ValueError('Invalid/nonpositive mean b0 intensities')
print(f'{(sum(high)/len(high))/(sum(low)/len(low)):.8f}')
PY
}

# Format rows with a TSV intermediate; convert to properly quoted CSV at end.
add_report() {
    local s="$1" t="$2" p="$3" status="$4" inp="$5" out="$6" before="$7" after="$8" note="$9"
    note="${note//$'\t'/ }"; note="${note//$'\n'/ }"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$s" "$t" "$p" "$status" "$inp" "$out" "$before" "$after" "$note" >> "$REPORT_TSV"
}

# Run each session in its own subshell to guarantee per-session cleanup.
process_one() (
    local subject="$1" session="$2" rel_dwi="$3" rel_mask="$4"
    local input="$DATA_MASTER_DIR/$rel_dwi" mask="$DATA_MASTER_DIR/$rel_mask"
    local base output pattern before='' after='' status='' notes=''
    base="${input%.mif}"
    output="${base}_b0matched.mif"

    if [[ -z "$rel_dwi" || "$rel_dwi" == "NA" || "$rel_dwi" == "N/A" || ! -f "$input" ]]; then
        add_report "$subject" "$session" '' 'MISSING_DWI' "$rel_dwi" '' '' '' 'Missing input MIF'
        echo "  MISSING DWI"
        exit 0
    fi
    if [[ -z "$rel_mask" || "$rel_mask" == "NA" || "$rel_mask" == "N/A" || ! -f "$mask" ]]; then
        add_report "$subject" "$session" '' 'MISSING_MASK' "$rel_dwi" '' '' '' 'Missing mask MIF'
        echo "  MISSING MASK"
        exit 0
    fi

    local work
    work="$(mktemp -d "$TEMP_PARENT_DIR/session_XXXXXXXX")"
    trap 'rm -rf -- "$work"' EXIT
    if ! mrinfo "$input" -dwgrad > "$work/grad.txt"; then
        add_report "$subject" "$session" '' 'ERROR' "$rel_dwi" '' '' '' 'Could not read embedded gradients'
        exit 0
    fi
    if ! pattern="$(classify_gradients "$work/grad.txt")"; then
        add_report "$subject" "$session" '' 'ERROR' "$rel_dwi" '' '' '' 'Could not classify gradient pattern'
        exit 0
    fi
    echo "  Pattern: $pattern"
    if [[ "$pattern" == 'UNKNOWN' ]]; then
        add_report "$subject" "$session" "$pattern" 'SKIPPED_UNKNOWN_PATTERN' "$rel_dwi" '' '' '' 'Manual review needed'
        exit 0
    fi
    if [[ "$pattern" == 'C' ]]; then
        add_report "$subject" "$session" "$pattern" 'SKIPPED_PATTERN_C' "$rel_dwi" '' '' '' 'Retain original unchanged; low b0 difference previously assessed'
        exit 0
    fi

    # QC before matching; read-only in --inspect mode.
    if ! before="$(b0_ratio "$input" "$mask" "$pattern" "$work/qc_before")"; then
        add_report "$subject" "$session" "$pattern" 'ERROR' "$rel_dwi" '' '' '' 'Pre-correction b0 QC failed'
        exit 0
    fi
    echo "  b0 ratio before (high/low): $before"
    if [[ "$MODE" == '--inspect' ]]; then
        add_report "$subject" "$session" "$pattern" 'INSPECTED' "$rel_dwi" '' "$before" '' 'No output written'
        exit 0
    fi
    if [[ -e "$output" ]]; then
        add_report "$subject" "$session" "$pattern" 'SKIPPED_OUTPUT_EXISTS' "$rel_dwi" "${output#"$DATA_MASTER_DIR/"}" "$before" '' 'Existing output not overwritten'
        exit 0
    fi

    local first_end second_start second_end
    case "$pattern" in
        A) first_end=65; second_start=66; second_end=96 ;;
        B) first_end=30; second_start=31; second_end=95 ;;
    esac
    if ! mrconvert "$input" "$work/series1.mif" -coord 3 "0:$first_end" -quiet \
        || ! mrconvert "$input" "$work/series2.mif" -coord 3 "$second_start:$second_end" -quiet; then
        add_report "$subject" "$session" "$pattern" 'ERROR' "$rel_dwi" '' "$before" '' 'Splitting failed'
        exit 0
    fi

    # Partial output is on the destination filesystem, enabling atomic final rename.
    local partial="${output%.mif}.partial.mif"
    if [[ -e "$partial" ]]; then
        add_report "$subject" "$session" "$pattern" 'ERROR' "$rel_dwi" '' "$before" '' 'Stale partial output exists; inspect manually'
        exit 0
    fi
    # Do not remove partial output on unsuccessful runs? Remove it safely if newly created.
    trap 'rm -rf -- "$work"; rm -f -- "$partial"' EXIT
    if ! dwicat "$work/series1.mif" "$work/series2.mif" "$partial" \
        -mask "$mask" -scratch "$work"; then
        add_report "$subject" "$session" "$pattern" 'ERROR' "$rel_dwi" '' "$before" '' 'dwicat failed'
        exit 0
    fi
    # Validate the gradient table (including original volume order).
    if ! mrinfo "$partial" -dwgrad > "$work/grad_corrected.txt"; then
        add_report "$subject" "$session" "$pattern" 'ERROR' "$rel_dwi" '' "$before" '' 'Could not read output gradients'
        exit 0
    fi
    if ! python3 - "$work/grad.txt" "$work/grad_corrected.txt" <<'PY'
import sys

def read_gradients(path):
    with open(path, encoding="utf-8") as stream:
        return [[float(v) for v in line.split()] for line in stream if line.strip()]

original, corrected = [read_gradients(p) for p in sys.argv[1:]]
assert len(original) == len(corrected), "Gradient table size differs"
assert all(len(a) == len(b) == 4 for a, b in zip(original, corrected)), "Invalid gradient table"
assert all(abs(a - b) <= 1e-5 for x, y in zip(original, corrected) for a, b in zip(x, y)), "Gradient directions/b-values differ"
PY
    then
        add_report "$subject" "$session" "$pattern" 'ERROR' "$rel_dwi" '' "$before" '' 'Gradient validation failed'
        exit 0
    fi
    if ! after="$(b0_ratio "$partial" "$mask" "$pattern" "$work/qc_after")"; then
        add_report "$subject" "$session" "$pattern" 'ERROR' "$rel_dwi" '' "$before" '' 'Post-correction b0 QC failed'
        exit 0
    fi
    echo "  b0 ratio after  (high/low): $after"
    status="CORRECTED"
    if python3 - "$after" "$QC_WARN_PERCENT" <<'PY'
import sys
ratio, threshold = map(float, sys.argv[1:])
sys.exit(0 if abs(ratio - 1.0) * 100 > threshold else 1)
PY
    then
        status='REVIEW_B0_RATIO'
        notes="Residual mean b0 ratio exceeds ${QC_WARN_PERCENT}%"
    fi
    mv -- "$partial" "$output"
    add_report "$subject" "$session" "$pattern" "$status" "$rel_dwi" "${output#"$DATA_MASTER_DIR/"}" "$before" "$after" "$notes"
)

echo "Mode: $MODE"
echo "Manifest: $INVENTORY_CSV"
echo "Temporary parent: $TEMP_PARENT_DIR"
echo "Report: $REPORT_CSV"
count=0
while IFS=$'\t' read -r subject session rel_dwi rel_mask; do
    ((count+=1))
    echo "[$count] $subject / $session"
    if ! process_one "$subject" "$session" "$rel_dwi" "$rel_mask"; then
        echo "  Unexpected failure for $subject / $session" >&2
        add_report "$subject" "$session" '' 'ERROR' "$rel_dwi" '' '' '' 'Unexpected script failure'
    fi
done < "$ROWS_TSV"

python3 - "$REPORT_TSV" "$REPORT_CSV" <<'PY'
import csv
import sys
with open(sys.argv[1], newline='', encoding='utf-8') as source:
    rows = csv.reader(source, delimiter='\t')
    with open(sys.argv[2], 'w', newline='', encoding='utf-8') as target:
        csv.writer(target).writerows(rows)
PY

echo "Finished $count sessions. Report: $REPORT_CSV"
