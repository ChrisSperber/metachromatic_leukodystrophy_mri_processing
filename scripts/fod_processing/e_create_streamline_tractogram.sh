#!/usr/bin/env bash
# Build a whole-brain template-space tractogram from the WM FOD template,
# including SIFT2 weights and a few QC outputs.
#
# Main outputs:
#   - temp_images/fod_template/tractography/template_tracks_2M.tck
#   - temp_images/fod_template/tractography/template_tracks_2M_sift2_weights.txt
#   - temp_images/fod_template/tractography/template_tracks_2M_qc_subset_200k.tck
#   - temp_images/fod_template/tractography/template_tracks_2M_tdi.mif
#   - temp_images/fod_template/tractography/template_tracks_2M_tdi.nii.gz
#   - temp_images/fod_template/tractography/template_tracks_2M_tckstats.txt
#   - temp_images/fod_template/tractography/template_tracks_2M_tckstats_hist.txt
#   - temp_images/fod_template/tractography/template_tractography.log
#
# Notes:
#   - Uses iFOD2 with dynamic seeding from the template FOD.
#   - Uses the template mask to constrain tracking.
#   - Generates SIFT2 weights (one weight per streamline).
#   - Creates a smaller random subset for visual QC in mrview.
#   - Creates a track-density image (TDI) on the template grid.

set -euo pipefail

# -----------------------------
# USER SETTINGS
# -----------------------------
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"

# Tracking parameters
N_STREAMLINES="${N_STREAMLINES:-2000000}"
TRACKING_ALGORITHM="${TRACKING_ALGORITHM:-iFOD2}"
CUTOFF="${CUTOFF:-0.06}"
MINLENGTH="${MINLENGTH:-10}"
MAXLENGTH="${MAXLENGTH:-250}"

# QC / derived outputs
QC_SUBSET_STREAMLINES="${QC_SUBSET_STREAMLINES:-200000}"
MAKE_TDI="${MAKE_TDI:-1}"
EXPORT_TDI_NIFTI="${EXPORT_TDI_NIFTI:-1}"
RUN_TCKSTATS="${RUN_TCKSTATS:-1}"
RUN_SIFT2="${RUN_SIFT2:-1}"

# Optional: SIFT2 regularisation extras
# Leave empty string "" to disable
SIFT2_OUT_MU="${SIFT2_OUT_MU:-1}"
SIFT2_OUT_COEFFS="${SIFT2_OUT_COEFFS:-0}"

# -----------------------------
# PATHS
# -----------------------------
script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"

SRC_DIR="$PROJECT_DIR/temp_images"
TPL_DIR="$SRC_DIR/fod_template"

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

mkdir -p "$OUT_DIR"

echo "Project dir         : $PROJECT_DIR"
echo "Template dir        : $TPL_DIR"
echo "Output dir          : $OUT_DIR"
echo "Conda env           : ${MRTRIX_CONDA_ENV} (USE_CONDA_RUN=${USE_CONDA_RUN})"
echo "Threads             : ${MRTRIX_NTHREADS}"
echo "Template FOD        : $TEMPLATE_FOD"
echo "Template mask       : $TEMPLATE_MASK"
echo "Algorithm           : ${TRACKING_ALGORITHM}"
echo "N streamlines       : ${N_STREAMLINES}"
echo "Cutoff              : ${CUTOFF}"
echo "Min length          : ${MINLENGTH}"
echo "Max length          : ${MAXLENGTH}"
echo "QC subset           : ${QC_SUBSET_STREAMLINES}"
echo "Run SIFT2           : ${RUN_SIFT2}"
echo "Make TDI            : ${MAKE_TDI} (export nifti=${EXPORT_TDI_NIFTI})"
echo "Run tckstats        : ${RUN_TCKSTATS}"
echo

# -----------------------------
# TOOL CHECKS / RUNNER
# -----------------------------
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Required tool '$1' not found in PATH" >&2
        exit 1
    }
}

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

if [[ -n "$MRTRIX_CONDA_ENV" ]]; then
    need_cmd conda
fi

need_cmd basename
need_cmd date
need_cmd realpath
need_cmd mkdir
need_cmd tee

if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" != "1" ]]; then
    eval "$(conda shell.bash hook)"
    conda activate "$MRTRIX_CONDA_ENV"
fi

# Ensure required MRtrix tools are runnable
if [[ "$USE_CONDA_RUN" == "1" ]]; then
    mrtrix tckgen -help >/dev/null 2>&1 || { echo "tckgen not runnable via conda run" >&2; exit 1; }
    mrtrix tckedit -help >/dev/null 2>&1 || { echo "tckedit not runnable via conda run" >&2; exit 1; }
    if [[ "$RUN_SIFT2" == "1" ]]; then
        mrtrix tcksift2 -help >/dev/null 2>&1 || { echo "tcksift2 not runnable via conda run" >&2; exit 1; }
    fi
    if [[ "$MAKE_TDI" == "1" ]]; then
        mrtrix tckmap -help >/dev/null 2>&1 || { echo "tckmap not runnable via conda run" >&2; exit 1; }
        mrtrix mrconvert -help >/dev/null 2>&1 || { echo "mrconvert not runnable via conda run" >&2; exit 1; }
    fi
    if [[ "$RUN_TCKSTATS" == "1" ]]; then
        mrtrix tckstats -help >/dev/null 2>&1 || { echo "tckstats not runnable via conda run" >&2; exit 1; }
    fi
else
    need_cmd tckgen
    need_cmd tckedit
    [[ "$RUN_SIFT2" == "1" ]] && need_cmd tcksift2
    if [[ "$MAKE_TDI" == "1" ]]; then
        need_cmd tckmap
        need_cmd mrconvert
    fi
    [[ "$RUN_TCKSTATS" == "1" ]] && need_cmd tckstats
fi

export MRTRIX_NTHREADS

# -----------------------------
# INPUT CHECKS
# -----------------------------
[[ -f "$TEMPLATE_FOD" ]] || { echo "Missing template FOD: $TEMPLATE_FOD" >&2; exit 1; }
[[ -f "$TEMPLATE_MASK" ]] || { echo "Missing template mask: $TEMPLATE_MASK" >&2; exit 1; }

# -----------------------------
# LOG HEADER
# -----------------------------
{
    echo "=== template tractography run ==="
    echo "Date               : $(date)"
    echo "PROJECT_DIR        : $PROJECT_DIR"
    echo "TEMPLATE_FOD       : $TEMPLATE_FOD"
    echo "TEMPLATE_MASK      : $TEMPLATE_MASK"
    echo "OUT_DIR            : $OUT_DIR"
    echo "TRACKS_TCK         : $TRACKS_TCK"
    echo "SIFT2_WEIGHTS      : $SIFT2_WEIGHTS"
    echo "QC_SUBSET_TCK      : $QC_SUBSET_TCK"
    echo "TDI_MIF            : $TDI_MIF"
    echo "TDI_NII            : $TDI_NII"
    echo "TCKSTATS_TXT       : $TCKSTATS_TXT"
    echo "TCKSTATS_HIST      : $TCKSTATS_HIST"
    echo "MRTRIX_CONDA_ENV   : $MRTRIX_CONDA_ENV"
    echo "USE_CONDA_RUN      : $USE_CONDA_RUN"
    echo "MRTRIX_NTHREADS    : $MRTRIX_NTHREADS"
    echo "TRACKING_ALGORITHM : $TRACKING_ALGORITHM"
    echo "N_STREAMLINES      : $N_STREAMLINES"
    echo "CUTOFF             : $CUTOFF"
    echo "MINLENGTH          : $MINLENGTH"
    echo "MAXLENGTH          : $MAXLENGTH"
    echo "QC_SUBSET_STREAMS  : $QC_SUBSET_STREAMLINES"
    echo "RUN_SIFT2          : $RUN_SIFT2"
    echo "MAKE_TDI           : $MAKE_TDI"
    echo "RUN_TCKSTATS       : $RUN_TCKSTATS"
    echo
    echo "=== MRtrix version ==="
    mrtrix mrinfo -version 2>/dev/null || true
    echo
} > "$LOG_PATH"

# -----------------------------
# 1) WHOLE-BRAIN TRACTOGRAM
# -----------------------------
echo "Generating whole-brain tractogram..."
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

echo "Tractogram created:"
echo "  $TRACKS_TCK"

# -----------------------------
# 2) SIFT2 WEIGHTS
# -----------------------------
if [[ "$RUN_SIFT2" == "1" ]]; then
    echo "Computing SIFT2 weights..."

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

    echo "SIFT2 weights created:"
    echo "  $SIFT2_WEIGHTS"
    [[ "$SIFT2_OUT_MU" == "1" ]] && echo "SIFT2 mu created: $SIFT2_MU_TXT"
    [[ "$SIFT2_OUT_COEFFS" == "1" ]] && echo "SIFT2 coeffs created: $SIFT2_COEFFS_TXT"
    echo
fi

# -----------------------------
# 3) QC SUBSET FOR FAST VIEWING
# -----------------------------
echo "Creating QC subset tractogram..."
mrtrix tckedit \
    "$TRACKS_TCK" \
    "$QC_SUBSET_TCK" \
    -number "$QC_SUBSET_STREAMLINES" \
    -force >> "$LOG_PATH" 2>&1

echo "QC subset created:"
echo "  $QC_SUBSET_TCK"
echo

# -----------------------------
# 4) TRACK DENSITY IMAGE (TDI)
# -----------------------------
if [[ "$MAKE_TDI" == "1" ]]; then
    echo "Creating track-density image (TDI)..."
    mrtrix tckmap \
        "$TRACKS_TCK" \
        "$TDI_MIF" \
        -template "$TEMPLATE_FOD" \
        -force >> "$LOG_PATH" 2>&1

    echo "TDI created:"
    echo "  $TDI_MIF"

    if [[ "$EXPORT_TDI_NIFTI" == "1" ]]; then
        mrtrix mrconvert \
            "$TDI_MIF" \
            "$TDI_NII" \
            -datatype float32 \
            -force >> "$LOG_PATH" 2>&1
        echo "TDI NIfTI created:"
        echo "  $TDI_NII"
    fi
    echo
fi

# -----------------------------
# 5) LENGTH STATS
# -----------------------------
if [[ "$RUN_TCKSTATS" == "1" ]]; then
    echo "Computing tractogram length statistics..."
    {
        echo "=== tckstats summary ==="
        mrtrix tckstats "$TRACKS_TCK"
        echo
        echo "=== tckstats histogram ==="
    } > "$TCKSTATS_TXT" 2>>"$LOG_PATH"

    mrtrix tckstats \
        "$TRACKS_TCK" \
        -histogram "$TCKSTATS_HIST" >> "$LOG_PATH" 2>&1

    echo "tckstats summary written to:"
    echo "  $TCKSTATS_TXT"
    echo "tckstats histogram written to:"
    echo "  $TCKSTATS_HIST"
    echo
fi

echo "Done."
echo "Main outputs:"
echo "  $TRACKS_TCK"
[[ "$RUN_SIFT2" == "1" ]] && echo "  $SIFT2_WEIGHTS"
echo "  $QC_SUBSET_TCK"
[[ "$MAKE_TDI" == "1" ]] && echo "  $TDI_MIF"
[[ "$MAKE_TDI" == "1" && "$EXPORT_TDI_NIFTI" == "1" ]] && echo "  $TDI_NII"
[[ "$RUN_TCKSTATS" == "1" ]] && echo "  $TCKSTATS_TXT"
echo "Log:"
echo "  $LOG_PATH"
