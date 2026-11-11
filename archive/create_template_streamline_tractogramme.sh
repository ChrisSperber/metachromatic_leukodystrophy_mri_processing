#!/usr/bin/env bash
# Generate a whole-brain tractogram in the healthy-control FOD template space.
# Adapted from scripts/fod_processing/e_create_streamline_tractogram.sh.
# MRtrix processing commands and their parameters are retained.
set -euo pipefail

# -----------------------------
# USER SETTINGS
# -----------------------------
DATA_MASTER_DIR="${DATA_MASTER_DIR:-/home/chris/projects/mld_data_master_2026}"
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"

# Tracking parameters (unchanged from original)
N_STREAMLINES="${N_STREAMLINES:-2000000}"
TRACKING_ALGORITHM="${TRACKING_ALGORITHM:-iFOD2}"
CUTOFF="${CUTOFF:-0.06}"
MINLENGTH="${MINLENGTH:-10}"
MAXLENGTH="${MAXLENGTH:-250}"

# QC / derived outputs (unchanged from original)
QC_SUBSET_STREAMLINES="${QC_SUBSET_STREAMLINES:-200000}"
MAKE_TDI="${MAKE_TDI:-1}"
EXPORT_TDI_NIFTI="${EXPORT_TDI_NIFTI:-1}"
RUN_TCKSTATS="${RUN_TCKSTATS:-1}"
RUN_SIFT2="${RUN_SIFT2:-1}"
SIFT2_OUT_MU="${SIFT2_OUT_MU:-1}"
SIFT2_OUT_COEFFS="${SIFT2_OUT_COEFFS:-0}"

# Set to 1 only if you deliberately want to overwrite the tractogram
# and its derived files. Default: do not overwrite existing outputs.
OVERWRITE="${OVERWRITE:-0}"

# -----------------------------
# PATHS
# -----------------------------
TPL_DIR="$DATA_MASTER_DIR/derivatives/fod_template_controls"
TEMPLATE_FOD="$TPL_DIR/wm_fod_template_2.0mm.mif"
TEMPLATE_MASK="$TPL_DIR/template_mask_2.0mm.mif"
OUT_DIR="$TPL_DIR/tractography"
LOG_PATH="$OUT_DIR/template_tractography.log"
TRACKS_TCK="$OUT_DIR/template_tracks_${N_STREAMLINES}.tck"
SIFT2_WEIGHTS="$OUT_DIR/template_tracks_${N_STREAMLINES}_sift2_weights.txt"
QC_SUBSET_TCK="$OUT_DIR/template_tracks_${N_STREAMLINES}_qc_subset_${QC_SUBSET_STREAMLINES}.tck"
TDI_MIF="$OUT_DIR/template_tracks_${N_STREAMLINES}_tdi.mif"
TDI_NII="$OUT_DIR/template_tracks_${N_STREAMLINES}_tdi.nii.gz"
TCKSTATS_TXT="$OUT_DIR/template_tracks_${N_STREAMLINES}_tckstats.txt"
TCKSTATS_HIST="$OUT_DIR/template_tracks_${N_STREAMLINES}_tckstats_hist.txt"
SIFT2_MU_TXT="$OUT_DIR/template_tracks_${N_STREAMLINES}_sift2_mu.txt"
SIFT2_COEFFS_TXT="$OUT_DIR/template_tracks_${N_STREAMLINES}_sift2_coeffs.txt"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Required tool '$1' not found in PATH" >&2
        exit 1
    }
}

mrtrix() {
    if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" == "1" ]]; then
        conda run -n "$MRTRIX_CONDA_ENV" "$@"
    else
        "$@"
    fi
}

# -----------------------------
# VALIDATION
# -----------------------------
[[ -f "$TEMPLATE_FOD" ]] || { echo "Missing template FOD: $TEMPLATE_FOD" >&2; exit 1; }
[[ -f "$TEMPLATE_MASK" ]] || { echo "Missing template mask: $TEMPLATE_MASK" >&2; exit 1; }

if [[ -n "$MRTRIX_CONDA_ENV" ]]; then
    need_cmd conda
fi
if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" != "1" ]]; then
    eval "$(conda shell.bash hook)"
    conda activate "$MRTRIX_CONDA_ENV"
fi

# Original command availability checks
for cmd in tckgen tckedit; do
    mrtrix "$cmd" -help >/dev/null 2>&1 || { echo "$cmd not runnable" >&2; exit 1; }
done
if [[ "$RUN_SIFT2" == "1" ]]; then
    mrtrix tcksift2 -help >/dev/null 2>&1 || { echo "tcksift2 not runnable" >&2; exit 1; }
fi
if [[ "$MAKE_TDI" == "1" ]]; then
    mrtrix tckmap -help >/dev/null 2>&1 || { echo "tckmap not runnable" >&2; exit 1; }
    if [[ "$EXPORT_TDI_NIFTI" == "1" ]]; then
        mrtrix mrconvert -help >/dev/null 2>&1 || { echo "mrconvert not runnable" >&2; exit 1; }
    fi
fi
if [[ "$RUN_TCKSTATS" == "1" ]]; then
    mrtrix tckstats -help >/dev/null 2>&1 || { echo "tckstats not runnable" >&2; exit 1; }
fi
export MRTRIX_NTHREADS

mkdir -p "$OUT_DIR"
if [[ "$OVERWRITE" != "1" ]]; then
    # Prevent accidental mixing of old and new tractograms / SIFT2 weights.
    for file in "$TRACKS_TCK" "$SIFT2_WEIGHTS" "$QC_SUBSET_TCK" \
                "$TDI_MIF" "$TDI_NII" "$TCKSTATS_TXT" "$TCKSTATS_HIST" \
                "$SIFT2_MU_TXT" "$SIFT2_COEFFS_TXT"; do
        if [[ -e "$file" ]]; then
            echo "Refusing to overwrite existing output: $file" >&2
            echo "Set OVERWRITE=1 to regenerate outputs deliberately." >&2
            exit 1
        fi
    done
fi

printf 'Template FOD: %s\nTemplate mask: %s\nOutput: %s\n' \
    "$TEMPLATE_FOD" "$TEMPLATE_MASK" "$OUT_DIR"
printf 'Algorithm: %s | streamlines: %s | threads: %s\n' \
    "$TRACKING_ALGORITHM" "$N_STREAMLINES" "$MRTRIX_NTHREADS"

{
    echo "=== template tractography run ==="
    echo "Date: $(date --iso-8601=seconds)"
    echo "DATA_MASTER_DIR: $DATA_MASTER_DIR"
    echo "TEMPLATE_FOD: $TEMPLATE_FOD"
    echo "TEMPLATE_MASK: $TEMPLATE_MASK"
    echo "OUT_DIR: $OUT_DIR"
    echo "MRTRIX_CONDA_ENV: $MRTRIX_CONDA_ENV"
    echo "USE_CONDA_RUN: $USE_CONDA_RUN"
    echo "MRTRIX_NTHREADS: $MRTRIX_NTHREADS"
    echo "TRACKING_ALGORITHM: $TRACKING_ALGORITHM"
    echo "N_STREAMLINES: $N_STREAMLINES"
    echo "CUTOFF: $CUTOFF"
    echo "MINLENGTH: $MINLENGTH"
    echo "MAXLENGTH: $MAXLENGTH"
    echo "QC_SUBSET_STREAMLINES: $QC_SUBSET_STREAMLINES"
    echo "RUN_SIFT2: $RUN_SIFT2"
    echo "MAKE_TDI: $MAKE_TDI"
    echo "RUN_TCKSTATS: $RUN_TCKSTATS"
    echo "=== MRtrix version ==="
    mrtrix mrinfo -version 2>/dev/null || true
    echo
} > "$LOG_PATH"

# -----------------------------
# 1) WHOLE-BRAIN TRACTOGRAM
# -----------------------------
echo 'Generating whole-brain tractogram...'
mrtrix tckgen \
    "$TEMPLATE_FOD" \
    "$TRACKS_TCK" \
    -algorithm "$TRACKING_ALGORITHM" \
    -seed_dynamic "$TEMPLATE_FOD" \
    -mask "$TEMPLATE_MASK" \
    -select "$N_STREAMLINES" \
    -cutoff "$CUTOFF" \
    -minlength "$MINLENGTH" \
    -maxlength "$MAXLENGTH" \
    -force >> "$LOG_PATH" 2>&1

# -----------------------------
# 2) SIFT2 WEIGHTS
# -----------------------------
if [[ "$RUN_SIFT2" == "1" ]]; then
    echo 'Computing SIFT2 weights...'
    sift2_args=()
    if [[ "$SIFT2_OUT_MU" == "1" ]]; then
        sift2_args+=( -out_mu "$SIFT2_MU_TXT" )
    fi
    if [[ "$SIFT2_OUT_COEFFS" == "1" ]]; then
        sift2_args+=( -out_coeffs "$SIFT2_COEFFS_TXT" )
    fi
    mrtrix tcksift2 \
        "$TRACKS_TCK" \
        "$TEMPLATE_FOD" \
        "$SIFT2_WEIGHTS" \
        "${sift2_args[@]}" \
        -force >> "$LOG_PATH" 2>&1
fi

# -----------------------------
# 3) QC SUBSET FOR FAST VIEWING
# -----------------------------
echo 'Creating QC subset tractogram...'
mrtrix tckedit \
    "$TRACKS_TCK" \
    "$QC_SUBSET_TCK" \
    -number "$QC_SUBSET_STREAMLINES" \
    -force >> "$LOG_PATH" 2>&1

# -----------------------------
# 4) TRACK-DENSITY IMAGE (TDI)
# -----------------------------
if [[ "$MAKE_TDI" == "1" ]]; then
    echo 'Creating track-density image (TDI)...'
    mrtrix tckmap \
        "$TRACKS_TCK" \
        "$TDI_MIF" \
        -template "$TEMPLATE_FOD" \
        -force >> "$LOG_PATH" 2>&1

    if [[ "$EXPORT_TDI_NIFTI" == "1" ]]; then
        mrtrix mrconvert \
            "$TDI_MIF" \
            "$TDI_NII" \
            -datatype float32 \
            -force >> "$LOG_PATH" 2>&1
    fi
fi

# -----------------------------
# 5) LENGTH STATS
# -----------------------------
if [[ "$RUN_TCKSTATS" == "1" ]]; then
    echo 'Computing tractogram length statistics...'
    {
        echo '=== tckstats summary ==='
        mrtrix tckstats "$TRACKS_TCK"
        echo
        echo '=== tckstats histogram ==='
    } > "$TCKSTATS_TXT" 2>>"$LOG_PATH"

    mrtrix tckstats \
        "$TRACKS_TCK" \
        -histogram "$TCKSTATS_HIST" >> "$LOG_PATH" 2>&1
fi

echo 'Done. Outputs:'
echo "  $TRACKS_TCK"
[[ "$RUN_SIFT2" == "1" ]] && echo "  $SIFT2_WEIGHTS"
echo "  $QC_SUBSET_TCK"
[[ "$MAKE_TDI" == "1" ]] && echo "  $TDI_MIF"
[[ "$MAKE_TDI" == "1" && "$EXPORT_TDI_NIFTI" == "1" ]] && echo "  $TDI_NII"
[[ "$RUN_TCKSTATS" == "1" ]] && echo "  $TCKSTATS_TXT"
echo "Log: $LOG_PATH"
