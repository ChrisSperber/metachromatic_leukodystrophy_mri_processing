#!/usr/bin/env bash
# MSMT-CSD FOD processing with group-averaged response functions.
# All inventory rows are included; run with MAX_SUBJECTS=1 or 2 for a quick test.
set -Eeuo pipefail

# -------- USER SETTINGS --------
DATA_MASTER_DIR="${DATA_MASTER_DIR:-/home/chris/projects/mld_data_master_2026}"
INVENTORY="${INVENTORY:-$DATA_MASTER_DIR/imaging_file_manifest.csv}"
MAX_SUBJECTS="${MAX_SUBJECTS:-0}"  # 0 = all; otherwise first N inventory rows
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"  # Same default as original GitHub script
NTHREADS="${NTHREADS:-6}"
MASK_MIN_VOXELS="${MASK_MIN_VOXELS:-50000}"
MASK_MAX_VOXELS="${MASK_MAX_VOXELS:-300000}"
FAIL_ON_MASK_OUTLIER="${FAIL_ON_MASK_OUTLIER:-1}"
# --------------------------------

DERIV="$DATA_MASTER_DIR/derivatives"
QC_ROOT="$DERIV/fod_qc"                 # Entire QC tree can be moved/deleted
GROUP_ROOT="$DERIV/fod_group_responses"  # Scientific outputs; keep these
mkdir -p "$QC_ROOT" "$GROUP_ROOT"
[[ -f "$INVENTORY" ]] || { echo "Missing inventory: $INVENTORY" >&2; exit 1; }
[[ "$MAX_SUBJECTS" =~ ^[0-9]+$ ]] || { echo "MAX_SUBJECTS must be nonnegative integer" >&2; exit 1; }

mrtrix() {
    if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" == 1 ]]; then
        conda run --no-capture-output -n "$MRTRIX_CONDA_ENV" "$@"
    else
        "$@"
    fi
}
if [[ -n "$MRTRIX_CONDA_ENV" ]]; then
    command -v conda >/dev/null || { echo "conda not found" >&2; exit 1; }
    if [[ "$USE_CONDA_RUN" != 1 ]]; then
        eval "$(conda shell.bash hook)"
        conda activate "$MRTRIX_CONDA_ENV"
    fi
fi
for cmd in dwi2response responsemean dwi2fod mtnormalise mrstats mrinfo; do
    mrtrix "$cmd" -help >/dev/null 2>&1 || { echo "MRtrix tool unavailable: $cmd" >&2; exit 1; }
done

# Parse CSV correctly, normalize IDs, resolve relative paths, check duplicates.
# Select the first MAX_SUBJECTS rows in inventory order; don't use Excluded.
RUN_META="$(python3 - "$INVENTORY" "$DATA_MASTER_DIR" "$MAX_SUBJECTS" <<'PY'
import csv, hashlib, json, os, pathlib, re, sys
inventory, root, limit = sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3])
with open(inventory, newline='', encoding='utf-8-sig') as file:
    reader = csv.DictReader(file)
    required = {'SubjectID', 'SessionID', 'PathDWIMIF', 'PathMaskMIF'}
    if not required.issubset(reader.fieldnames or []):
        sys.exit('Missing inventory columns: ' + ', '.join(sorted(required - set(reader.fieldnames or []))))
    rows = list(reader)
if limit:
    rows = rows[:limit]
if not rows:
    sys.exit('No inventory rows selected')
seen = set()
selected = []
for row in rows:
    subject = str(row['SubjectID']).strip()
    session = str(row['SessionID']).strip()
    # Avoid doubled sub-/ses- prefixes.
    subject = re.sub(r'^sub-', '', subject, flags=re.I)
    session = re.sub(r'^ses-', '', session, flags=re.I)
    if not re.fullmatch(r'[A-Za-z0-9_-]+', subject) or not re.fullmatch(r'[A-Za-z0-9_-]+', session):
        sys.exit(f'Invalid SubjectID/SessionID: {subject!r}/{session!r}')
    key = (subject, session)
    if key in seen:
        sys.exit(f'Duplicate session in inventory: {key}')
    seen.add(key)
    paths = []
    for col in ('PathDWIMIF', 'PathMaskMIF'):
        val = str(row[col] or '').strip()
        if not val:
            sys.exit(f'Empty {col} for {key}')
        p = pathlib.Path(os.path.expanduser(val))
        if not p.is_absolute():
            p = root / p
        paths.append(str(p.resolve()))
    selected.append((subject, session, *paths))
identity = json.dumps(selected, separators=(',', ':'), ensure_ascii=True)
short_hash = hashlib.sha256(identity.encode()).hexdigest()[:12]
label = ('all' if not limit else f'test_{len(selected)}') + '_' + short_hash
# Rows supplied to Bash via a temporary TSV under the QC directory, no extra dependencies.
qc = root / 'derivatives' / 'fod_qc' / 'runs' / label
qc.mkdir(parents=True, exist_ok=True)
with open(qc / 'selected_sessions.tsv', 'w', encoding='utf-8') as file:
    for vals in selected:
        if any('\t' in v or '\n' in v for v in vals):
            sys.exit('Tabs/newlines in paths are unsupported')
        file.write('\t'.join(vals) + '\n')
print(label)
PY
)"
RUN_QC="$QC_ROOT/runs/$RUN_META"
GROUP_DIR="$GROUP_ROOT/$RUN_META"
mkdir -p "$RUN_QC/logs" "$GROUP_DIR"
ROWS="$RUN_QC/selected_sessions.tsv"
STATUS_TSV="$RUN_QC/status.tsv"
QC_TSV="$RUN_QC/qc_metrics.tsv"
# Rebuilt each invocation; per-session logs accumulate/overwrite as relevant.
printf 'SubjectID\tSessionID\tStage\tStatus\tDetail\n' > "$STATUS_TSV"
printf 'SubjectID\tSessionID\tMaskVoxels\tMaskStatus\n' > "$QC_TSV"
record() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$STATUS_TSV"; }
log_run() {
    local log="$1"; shift
    # shellcheck disable=SC2129
    printf 'COMMAND:' >> "$log"; printf ' %q' "$@" >> "$log"; printf '\n' >> "$log"
    mrtrix "$@" >> "$log" 2>&1
}
valid_file() { [[ -s "$1" ]]; }

# Stage 1: response estimation and input QC.
echo "RUN: $RUN_META | conda: $MRTRIX_CONDA_ENV | selected sessions: $(wc -l < "$ROWS")"
echo "QC: $RUN_QC"
echo "Group response outputs: $GROUP_DIR"
READY="$RUN_QC/response_ready.tsv"
: > "$READY"
while IFS=$'\t' read -r sub ses dwi mask; do
    base="sub-${sub}_ses-${ses}"
    out="$DERIV/diffusion/sub-${sub}/ses-${ses}/fod"
    mkdir -p "$out"
    log="$RUN_QC/logs/${base}_response.log"
    : > "$log"
    echo "[response] $base"
    if [[ ! -s "$dwi" || ! -s "$mask" ]]; then
        record "$sub" "$ses" response FAILED MISSING_INPUT
        continue
    fi
    # Check DWI and mask spatial dimensions (first three axes).
    if ! dwidims="$(mrtrix mrinfo "$dwi" -size 2>>"$log")" || \
          ! maskdims="$(mrtrix mrinfo "$mask" -size 2>>"$log")"; then
        record "$sub" "$ses" response FAILED MRINFO_FAILED; continue
    fi
    read -r dx dy dz _ <<< "$dwidims"
    read -r mx my mz _ <<< "$maskdims"
    if [[ "$dx $dy $dz" != "$mx $my $mz" ]]; then
        record "$sub" "$ses" response FAILED DIMENSION_MISMATCH; continue
    fi
    if ! voxels_raw="$(mrtrix mrstats "$mask" -mask "$mask" -output count -quiet 2>>"$log")"; then
        record "$sub" "$ses" response FAILED MASK_COUNT_FAILED; continue
    fi
    # Preserve the raw output for diagnosing unexpected formatting.
    printf 'Raw mask count output: %q\n' "$voxels_raw" >> "$log"
    # Trim leading and trailing whitespace, but do not accept arbitrary extra text.
    voxels="$(printf '%s' "$voxels_raw" | xargs)"
    if ! [[ "$voxels" =~ ^[0-9]+$ ]]; then
        record "$sub" "$ses" response FAILED INVALID_MASK_COUNT; continue
    fi
    maskstatus=OK
    if (( voxels < MASK_MIN_VOXELS )); then maskstatus=TOO_SMALL; fi
    if (( voxels > MASK_MAX_VOXELS )); then maskstatus=TOO_LARGE; fi
    printf '%s\t%s\t%s\t%s\n' "$sub" "$ses" "$voxels" "$maskstatus" >> "$QC_TSV"
    if [[ "$maskstatus" != OK && "$FAIL_ON_MASK_OUTLIER" == 1 ]]; then
        record "$sub" "$ses" response FAILED "MASK_${maskstatus}"; continue
    fi
    wm="$out/response_wm.txt"; gm="$out/response_gm.txt"; csf="$out/response_csf.txt"
    if ! valid_file "$wm" || ! valid_file "$gm" || ! valid_file "$csf"; then
        rm -f "$wm" "$gm" "$csf"
        if ! log_run "$log" dwi2response dhollander "$dwi" "$wm" "$gm" "$csf" -mask "$mask" -nthreads "$NTHREADS" -force || \
              ! valid_file "$wm" || ! valid_file "$gm" || ! valid_file "$csf"; then
            record "$sub" "$ses" response FAILED DWI2RESPONSE_FAILED
            continue
        fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$sub" "$ses" "$dwi" "$mask" >> "$READY"
    record "$sub" "$ses" response OK "$maskstatus"
done < "$ROWS"

# Do not silently estimate a group from fewer subjects than selected.
expected="$(wc -l < "$ROWS")"
actual="$(wc -l < "$READY")"
if [[ "$actual" != "$expected" ]]; then
    echo "STOP: Only $actual/$expected response estimates succeeded. Check $STATUS_TSV" >&2
    exit 1
fi

# Mean responses; group responses belong outside the removable QC folder.
for tissue in wm gm csf; do
    inputs=()
    while IFS=$'\t' read -r sub ses dwi mask; do
        inputs+=("$DERIV/diffusion/sub-${sub}/ses-${ses}/fod/response_${tissue}.txt")
    done < "$READY"
    dest="$GROUP_DIR/group_response_${tissue}.txt"
    if [[ "$actual" == 1 ]]; then
        cp "${inputs[0]}" "$dest"  # Single-subject test: mean = single response
    else
        log_run "$RUN_QC/group_response.log" responsemean "${inputs[@]}" "$dest" -force || exit 1
    fi
    valid_file "$dest" || { echo "Empty group response: $dest" >&2; exit 1; }
done

# Stage 2: MSMT-CSD and normalisation.
while IFS=$'\t' read -r sub ses dwi mask; do
    base="sub-${sub}_ses-${ses}"
    out="$DERIV/diffusion/sub-${sub}/ses-${ses}/fod"
    log="$RUN_QC/logs/${base}_fod.log"
    : > "$log"
    echo "[FOD] $base"
    # A different group reference must NEVER silently reuse old FOD products.
    marker="$out/group_response_run.txt"
    if [[ -f "$marker" && "$(cat "$marker")" == "$RUN_META" ]] && \
          valid_file "$out/FOD_wm_norm.mif" && valid_file "$out/FOD_gm_norm.mif" && valid_file "$out/FOD_csf_norm.mif"; then
        record "$sub" "$ses" fod SKIPPED ALREADY_COMPLETE
        continue
    fi
    rm -f "$marker"
    raw_wm="$out/FOD_wm.mif"; raw_gm="$out/FOD_gm.mif"; raw_csf="$out/FOD_csf.mif"
    norm_wm="$out/FOD_wm_norm.mif"; norm_gm="$out/FOD_gm_norm.mif"; norm_csf="$out/FOD_csf_norm.mif"
    rm -f "$raw_wm" "$raw_gm" "$raw_csf" "$norm_wm" "$norm_gm" "$norm_csf"
    if ! log_run "$log" dwi2fod msmt_csd "$dwi" \
              "$GROUP_DIR/group_response_wm.txt" "$raw_wm" \
              "$GROUP_DIR/group_response_gm.txt" "$raw_gm" \
              "$GROUP_DIR/group_response_csf.txt" "$raw_csf" \
              -mask "$mask" -nthreads "$NTHREADS" -force; then
        record "$sub" "$ses" fod FAILED DWI2FOD_FAILED; continue
    fi
    if ! log_run "$log" mtnormalise "$raw_wm" "$norm_wm" \
              "$raw_gm" "$norm_gm" "$raw_csf" "$norm_csf" \
              -mask "$mask" -nthreads "$NTHREADS" -force; then
        record "$sub" "$ses" fod FAILED MTNORMALISE_FAILED; continue
    fi
    if ! valid_file "$norm_wm" || ! valid_file "$norm_gm" || ! valid_file "$norm_csf"; then
        record "$sub" "$ses" fod FAILED MISSING_OUTPUT; continue
    fi
    # Keep normalized FODs; raw FODs are reproducible intermediates.
    rm -f "$raw_wm" "$raw_gm" "$raw_csf"
    printf '%s\n' "$RUN_META" > "$marker"
    record "$sub" "$ses" fod OK COMPLETE
done < "$READY"

# Convert TSV logs to interoperable CSV; keep TSV too for easy command-line inspection.
python3 - "$RUN_QC" <<'PY'
import csv, pathlib, sys
qc = pathlib.Path(sys.argv[1])
for name in ('status', 'qc_metrics'):
    with (qc / f'{name}.tsv').open(newline='') as f:
        data = list(csv.reader(f, delimiter='\t'))
    with (qc / f'{name}.csv').open('w', newline='') as f:
        csv.writer(f).writerows(data)
PY

echo "Done. QC reports: $RUN_QC/status.csv and $RUN_QC/qc_metrics.csv"
