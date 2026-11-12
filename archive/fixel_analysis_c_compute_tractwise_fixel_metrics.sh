#!/usr/bin/env bash
set -euo pipefail

# Extract tract-wise FD, FC and FDC statistics using template fixel masks.
# All fixel measurements and masks must use the same template fixel ordering.
# Include zero FD values (no -ignorezero). Tract averages are unweighted.

DATA_MASTER_DIR="${DATA_MASTER_DIR:-/home/chris/projects/mld_data_master_2026}"
INVENTORY="$DATA_MASTER_DIR/imaging_file_manifest.csv"
OUTPUT_DIR="$DATA_MASTER_DIR/derivatives/fixel_analysis"
TRACT_FIXELS="$OUTPUT_DIR/tract_fixels"
TEMP_DIR="$DATA_MASTER_DIR/derivatives/fixel_analysis_temp"
OUTPUT_CSV="$OUTPUT_DIR/tract_metrics.csv"
STATUS="$OUTPUT_DIR/qc/tract_metrics_status.tsv"
MASK_THRESHOLD="${MASK_THRESHOLD:-10}"
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -s "$INVENTORY" ]] || fail "Missing inventory: $INVENTORY"
[[ -d "$TRACT_FIXELS" ]] || fail "Missing tract fixels: $TRACT_FIXELS"
for metric in fd fc fdc; do
    [[ -d "$OUTPUT_DIR/$metric" ]] || fail "Missing metric folder: $OUTPUT_DIR/$metric"
done
command -v python3 >/dev/null || fail 'python3 unavailable'
command -v conda >/dev/null || fail 'conda unavailable'

eval "$(conda shell.bash hook)"
conda activate "$MRTRIX_CONDA_ENV"
command -v mrstats >/dev/null || fail 'mrstats unavailable'

shopt -s nullglob
tract_dirs=("$TRACT_FIXELS"/*/)
(( ${#tract_dirs[@]} > 0 )) || fail 'No tract folders found'
for tract_dir in "${tract_dirs[@]}"; do
    [[ -s "${tract_dir}mask_min${MASK_THRESHOLD}.mif" ]] || \
        fail "Missing tract mask: ${tract_dir}mask_min${MASK_THRESHOLD}.mif"
done

mkdir -p "$TEMP_DIR" "$OUTPUT_DIR/qc"
WORK_DIR="$(mktemp -d "$TEMP_DIR/tract_metrics.XXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Inventory contains the final included sessions; use CSV parsing for quoting.
python3 - "$INVENTORY" "$WORK_DIR/sessions.tsv" <<'PY'
import csv
import sys

source, destination = sys.argv[1:]
with open(source, newline="", encoding="utf-8-sig") as handle:
    reader = csv.DictReader(handle)
    if not {"SubjectID", "SessionID"}.issubset(reader.fieldnames or []):
        sys.exit("ERROR: inventory needs SubjectID and SessionID")
    sessions = sorted({
        (row["SubjectID"].strip(), row["SessionID"].strip())
        for row in reader
    })
with open(destination, "w", encoding="utf-8", newline="\n") as handle:
    for subject, session in sessions:
        handle.write(f"{subject}\t{session}\n")
print(f"Inventory sessions: {len(sessions)}")
PY

# mrstats reports mean and median in that order.
stat_pair() {
    local result
    result="$(mrstats "$1" -mask "$2" -output mean -output median)"
    result="${result//$'\n'/ }"
    read -r mean median <<< "$result"
    [[ -n "${mean:-}" && -n "${median:-}" ]] || \
        fail "Unexpected mrstats output for $1"
    printf '%s %s\n' "$mean" "$median"
}

printf 'SubjectID,SessionID,Tract,n_fixels,FD_mean,FD_median,FC_mean,FC_median,FDC_mean,FDC_median\n' \
    > "$WORK_DIR/tract_metrics.csv"
printf 'SubjectID\tSessionID\tStatus\n' > "$WORK_DIR/status.tsv"

# Count selected fixels once per tract (identical across subjects).
for tract_dir in "${tract_dirs[@]}"; do
    tract="$(basename "$tract_dir")"
    mask="${tract_dir}mask_min${MASK_THRESHOLD}.mif"
    n_fixels="$(mrstats "$mask" -mask "$mask" -output count)"
    printf '%s\t%s\n' "$tract" "$n_fixels" >> "$WORK_DIR/tract_counts.tsv"
done

included=0
skipped=0
printf 'Tract mask threshold: %s\n' "$MASK_THRESHOLD"
while IFS=$'\t' read -r subject session; do
    stem="sub-${subject}_ses-${session}"
    fd="$OUTPUT_DIR/fd/$stem.mif"
    fc="$OUTPUT_DIR/fc/$stem.mif"
    fdc="$OUTPUT_DIR/fdc/$stem.mif"

    if [[ ! -s "$fd" || ! -s "$fc" || ! -s "$fdc" ]]; then
        printf 'SKIP (missing metrics): %s\n' "$stem"
        printf '%s\t%s\tMISSING_METRICS\n' "$subject" "$session" >> "$WORK_DIR/status.tsv"
        ((skipped += 1))
        continue
    fi

    printf 'Extracting: %s\n' "$stem"
    while IFS=$'\t' read -r tract n_fixels; do
        mask="$TRACT_FIXELS/$tract/mask_min${MASK_THRESHOLD}.mif"
        read -r fd_mean fd_median <<< "$(stat_pair "$fd" "$mask")"
        read -r fc_mean fc_median <<< "$(stat_pair "$fc" "$mask")"
        read -r fdc_mean fdc_median <<< "$(stat_pair "$fdc" "$mask")"
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$subject" "$session" "$tract" "$n_fixels" \
            "$fd_mean" "$fd_median" "$fc_mean" "$fc_median" \
            "$fdc_mean" "$fdc_median" >> "$WORK_DIR/tract_metrics.csv"
    done < "$WORK_DIR/tract_counts.tsv"
    printf '%s\t%s\tOK\n' "$subject" "$session" >> "$WORK_DIR/status.tsv"
    ((included += 1))
done < "$WORK_DIR/sessions.tsv"

(( included > 0 )) || fail 'No sessions with complete FD/FC/FDC metrics'
mv "$WORK_DIR/tract_metrics.csv" "$OUTPUT_CSV"
mv "$WORK_DIR/status.tsv" "$STATUS"
printf '\nCompleted: %s sessions, %s skipped, %s tracts\n' \
    "$included" "$skipped" "${#tract_dirs[@]}"
printf 'Output: %s\n' "$OUTPUT_CSV"
