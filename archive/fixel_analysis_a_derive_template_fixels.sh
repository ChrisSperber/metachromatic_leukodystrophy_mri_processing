#!/usr/bin/env bash
set -euo pipefail

# Create reference fixels in the healthy-control FOD template and identify
# tract-specific fixels from the previously selected streamline tractograms.
# Streamline contributions are unweighted; keep fixels with at least 5.
# This step does not use subject registrations or individual FOD images.

DATA_MASTER_DIR="${DATA_MASTER_DIR:-/home/chris/projects/mld_data_master_2026}"
TEMPLATE_DIR="$DATA_MASTER_DIR/derivatives/fod_template_controls"
TRACT_DIR="$DATA_MASTER_DIR/derivatives/fod_tracts_template"
OUTPUT_DIR="$DATA_MASTER_DIR/derivatives/fixel_analysis"
TEMPLATE_FOD="$TEMPLATE_DIR/wm_fod_template_2.0mm.mif"
TEMPLATE_MASK="$TEMPLATE_DIR/template_mask_2.0mm.mif"
TEMPLATE_FIXELS="$OUTPUT_DIR/template_fixels"
TRACT_FIXELS="$OUTPUT_DIR/tract_fixels"

MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"
FMLS_PEAK_VALUE="${FMLS_PEAK_VALUE:-0.06}"
MIN_STREAMLINES="${MIN_STREAMLINES:-10}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
mrtrix() { conda run -n "$MRTRIX_CONDA_ENV" "$@"; }

[[ -s "$TEMPLATE_FOD" ]] || fail "Missing FOD template: $TEMPLATE_FOD"
[[ -s "$TEMPLATE_MASK" ]] || fail "Missing template mask: $TEMPLATE_MASK"
[[ -d "$TRACT_DIR" ]] || fail "Missing tract directory: $TRACT_DIR"
command -v conda >/dev/null 2>&1 || fail "conda not found"
for command_name in fod2fixel tck2fixel mrthreshold mrinfo; do
    mrtrix "$command_name" -help >/dev/null 2>&1 || \
        fail "$command_name unavailable in Conda environment: $MRTRIX_CONDA_ENV"
done

[[ "$MIN_STREAMLINES" =~ ^[1-9][0-9]*$ ]] || fail 'MIN_STREAMLINES must be a positive integer'
[[ "$MRTRIX_NTHREADS" =~ ^[1-9][0-9]*$ ]] || fail 'MRTRIX_NTHREADS must be a positive integer'
export MRTRIX_NTHREADS

mkdir -p "$OUTPUT_DIR" "$TRACT_FIXELS"

printf 'FOD template       : %s\n' "$TEMPLATE_FOD"
printf 'Tractograms        : %s\n' "$TRACT_DIR"
printf 'Output             : %s\n' "$OUTPUT_DIR"
printf 'Min contributions  : %s (unweighted)\n' "$MIN_STREAMLINES"
printf 'FOD peak threshold : %s\n' "$FMLS_PEAK_VALUE"

# Template fixels: shared index and directions used by all subsequent FD/FC/FDC images.
if [[ -d "$TEMPLATE_FIXELS" ]]; then
    [[ -s "$TEMPLATE_FIXELS/index.mif" && -s "$TEMPLATE_FIXELS/directions.mif" ]] || \
        fail "Incomplete template fixel directory: $TEMPLATE_FIXELS"
    printf 'SKIP: template fixels already exist\n'
else
    printf '\n=== Generate template fixels ===\n'
    mrtrix fod2fixel \
        -mask "$TEMPLATE_MASK" \
        -fmls_peak_value "$FMLS_PEAK_VALUE" \
        "$TEMPLATE_FOD" "$TEMPLATE_FIXELS"
fi

printf '\nTemplate fixels:\n'
mrtrix mrinfo -size "$TEMPLATE_FIXELS/directions.mif"

# tck2fixel creates a fixel image for each tract using the shared reference fixels.
# Retain unthresholded counts so the threshold may be changed later without rerunning.
shopt -s nullglob
tract_dirs=("$TRACT_DIR"/*/)
(( ${#tract_dirs[@]} > 0 )) || fail "No tract folders found in $TRACT_DIR"
processed=0
skipped=0

for source_dir in "${tract_dirs[@]}"; do
    tract="$(basename "$source_dir")"
    tracks="${source_dir}${tract}.tck"
    [[ -s "$tracks" ]] || fail "Missing tractogram: $tracks"

    destination="$TRACT_FIXELS/$tract"
    counts="$destination/streamline_count.mif"
    mask="$destination/mask_min${MIN_STREAMLINES}.mif"
    printf '\n=== %s ===\n' "$tract"

    if [[ -d "$destination" ]]; then
        [[ -s "$destination/index.mif" && -s "$destination/directions.mif" && -s "$counts" ]] || \
            fail "Incomplete tract fixel directory: $destination"
        printf 'SKIP: streamline count already exists\n'
        ((skipped += 1))
    else
        mrtrix tck2fixel "$tracks" "$TEMPLATE_FIXELS" "$destination" \
            streamline_count.mif
        ((processed += 1))
    fi

    if [[ -s "$mask" ]]; then
        printf 'SKIP: threshold mask already exists\n'
    else
        mrtrix mrthreshold "$counts" "$mask" \
            -abs "$MIN_STREAMLINES" -comparison ge
    fi
done

printf '\nCompleted: %d tract counts created, %d reused; %d tract folders total.\n' \
    "$processed" "$skipped" "${#tract_dirs[@]}"
printf 'Reference fixels: %s\nTract fixels: %s\n' "$TEMPLATE_FIXELS" "$TRACT_FIXELS"
