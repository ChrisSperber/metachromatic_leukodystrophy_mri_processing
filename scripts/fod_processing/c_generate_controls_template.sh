#!/usr/bin/env bash
# Build a WM FOD population template from control subjects (subject_MLD*),
# using normalised WM FOD images (*_FOD_wm_norm.mif) produced previously.
#
# Additional features:
#   1) Export control->template warps via -warp_dir
#   2) Generate additional template-space contrasts (GM / CSF) by:
#      - warping each control's GM/CSF compartment image using the corresponding warp
#      - averaging in template space to create template GM/CSF images
#      (These are intended for downstream multi-contrast patient->template normalisation)
#   3) AFD QC generated from template WM FOD

#
# Outputs (main):
#   - temp_images/fod_template/controls_wm_fod_norm_list.txt
#   - temp_images/fod_template/controls_wm_fod_norm_mask_list.txt
#   - temp_images/fod_template/wm_fod_template_<vox>mm.mif
#   - temp_images/fod_template/template_mask_<vox>mm.mif
#   - temp_images/fod_template/warps/ (one warp per input image)
#   - temp_images/fod_template/template_GM_<vox>mm.mif
#   - temp_images/fod_template/template_CSF_<vox>mm.mif
#   - temp_images/fod_template/population_template.log
#   - temp_images/fod_template/scratch/ (intermediates)
#   - (optional) temp_images/fod_template/template_AFD_<vox>mm.mif (+ .nii.gz)

set -euo pipefail

# -----------------------------
# USER SETTINGS
# -----------------------------
MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"

# Threads for MRtrix (exported so MRtrix picks it up)
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"

# Template voxel size (2.0 mm matches DWI resolution)
TEMPLATE_VOXEL_SIZE="${TEMPLATE_VOXEL_SIZE:-2.0}"

# Pattern for control subjects in flat FOD output folder
CONTROL_GLOB="${CONTROL_GLOB:-subject_MLD*_FOD_wm_norm.mif}"

# population_template initial alignment (robust_mass requires masks and is typically robust)
INITIAL_ALIGNMENT="${INITIAL_ALIGNMENT:-robust_mass}"

# Template AFD QC
MAKE_TEMPLATE_AFD="${MAKE_TEMPLATE_AFD:-1}"
MASK_TEMPLATE_AFD="${MASK_TEMPLATE_AFD:-1}"
EXPORT_TEMPLATE_AFD_NIFTI="${EXPORT_TEMPLATE_AFD_NIFTI:-1}"

# Create GM/CSF template-space contrasts for downstream multi-contrast normalisation
MAKE_TISSUE_TEMPLATES="${MAKE_TISSUE_TEMPLATES:-1}"

# Suffixes for compartment images (must exist in FOD_DIR)
# Derived from the WM basename by replacing "_FOD_wm_norm.mif"
GM_SUFFIX="${GM_SUFFIX:-_FOD_gm_norm.mif}"
CSF_SUFFIX="${CSF_SUFFIX:-_FOD_csf_norm.mif}"

# Interpolation for warping GM/CSF compartments
# (they are isotropic / scalar-like; linear is typically fine)
TISSUE_INTERP="${TISSUE_INTERP:-linear}"

# -----------------------------
# PATHS
# -----------------------------
script_dir="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(realpath "$script_dir/../../..")"

SRC_DIR="$PROJECT_DIR/temp_images"
FOD_DIR="$SRC_DIR/FOD_images"

TPL_DIR="$SRC_DIR/fod_template"
SCRATCH_DIR="$TPL_DIR/scratch"

LIST_PATH="$TPL_DIR/controls_wm_fod_norm_list.txt"
MASK_LIST_PATH="$TPL_DIR/controls_wm_fod_norm_mask_list.txt"

TEMPLATE_OUT="$TPL_DIR/wm_fod_template_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_MASK="$TPL_DIR/template_mask_${TEMPLATE_VOXEL_SIZE}mm.mif"
LOG_PATH="$TPL_DIR/population_template.log"

# Warps output (control -> template)
WARP_DIR="$TPL_DIR/warps"

# Tissue template outputs
TEMPLATE_GM="$TPL_DIR/template_GM_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_CSF="$TPL_DIR/template_CSF_${TEMPLATE_VOXEL_SIZE}mm.mif"

# Intermediate transformed tissue dirs
XFM_GM_DIR="$TPL_DIR/transformed_controls_gm"
XFM_CSF_DIR="$TPL_DIR/transformed_controls_csf"

# Concatenated stacks for averaging (4D)
GM_STACK_4D="$TPL_DIR/transformed_controls_gm_stack_4d.mif"
CSF_STACK_4D="$TPL_DIR/transformed_controls_csf_stack_4d.mif"

# template AFD outputs (QC)
AFD_DIR="$TPL_DIR/template_fixels"
TEMPLATE_AFD_MIF="$TPL_DIR/template_AFD_${TEMPLATE_VOXEL_SIZE}mm.mif"
TEMPLATE_AFD_NII="$TPL_DIR/template_AFD_${TEMPLATE_VOXEL_SIZE}mm.nii.gz"

mkdir -p "$TPL_DIR" "$SCRATCH_DIR"

# MRtrix scripts operate on a single input dir; create one with symlinks
TPL_INPUT_DIR="$TPL_DIR/input_controls"
TPL_MASK_DIR="$TPL_DIR/input_controls_masks"
mkdir -p "$TPL_INPUT_DIR" "$TPL_MASK_DIR"

echo "Project dir       : $PROJECT_DIR"
echo "FOD dir           : $FOD_DIR"
echo "Template dir      : $TPL_DIR"
echo "Conda env         : ${MRTRIX_CONDA_ENV} (USE_CONDA_RUN=${USE_CONDA_RUN})"
echo "Threads           : ${MRTRIX_NTHREADS}"
echo "Voxel size        : ${TEMPLATE_VOXEL_SIZE} mm"
echo "Control glob      : ${CONTROL_GLOB}"
echo "Initial align     : ${INITIAL_ALIGNMENT}"
echo "Warp dir          : ${WARP_DIR}"
echo "Make tissues      : ${MAKE_TISSUE_TEMPLATES} (GM suffix=${GM_SUFFIX}, CSF suffix=${CSF_SUFFIX}, interp=${TISSUE_INTERP})"
echo "Make AFD          : ${MAKE_TEMPLATE_AFD} (mask=${MASK_TEMPLATE_AFD}, export nifti=${EXPORT_TEMPLATE_AFD_NIFTI})"
echo "TPL_INPUT_DIR     : $TPL_INPUT_DIR"
echo "TPL_MASK_DIR      : $TPL_MASK_DIR"
echo "Template mask out : $TEMPLATE_MASK"
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

need_cmd find
need_cmd sort
need_cmd wc
need_cmd basename

if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" != "1" ]]; then
    eval "$(conda shell.bash hook)"
    conda activate "$MRTRIX_CONDA_ENV"
fi

# Ensure required MRtrix tools are runnable
if [[ "$USE_CONDA_RUN" == "1" ]]; then
    mrtrix population_template -help >/dev/null 2>&1 || { echo "population_template not runnable via conda run" >&2; exit 1; }
    mrtrix mrtransform -help >/dev/null 2>&1 || { echo "mrtransform not runnable via conda run" >&2; exit 1; }
    mrtrix mrcat -help >/dev/null 2>&1 || { echo "mrcat not runnable via conda run" >&2; exit 1; }
    mrtrix mrmath -help >/dev/null 2>&1 || { echo "mrmath not runnable via conda run" >&2; exit 1; }
    if [[ "$MAKE_TEMPLATE_AFD" == "1" ]]; then
        mrtrix fod2fixel -help >/dev/null 2>&1 || { echo "fod2fixel not runnable via conda run" >&2; exit 1; }
        mrtrix fixel2voxel -help >/dev/null 2>&1 || { echo "fixel2voxel not runnable via conda run" >&2; exit 1; }
        mrtrix mrcalc -help >/dev/null 2>&1 || { echo "mrcalc not runnable via conda run" >&2; exit 1; }
        mrtrix mrconvert -help >/dev/null 2>&1 || { echo "mrconvert not runnable via conda run" >&2; exit 1; }
    fi
else
    need_cmd population_template
    need_cmd mrtransform
    need_cmd mrcat
    need_cmd mrmath
    if [[ "$MAKE_TEMPLATE_AFD" == "1" ]]; then
        need_cmd fod2fixel
        need_cmd fixel2voxel
        need_cmd mrcalc
        need_cmd mrconvert
    fi
fi

# Set MRtrix threads for this script
export MRTRIX_NTHREADS

# -----------------------------
# 1) COLLECT CONTROL FODS (+ MATCHING MASKS)
# -----------------------------
echo "Collecting control WM FODs..."
find "$FOD_DIR" -type f -name "$CONTROL_GLOB" | sort > "$LIST_PATH"

n_total=$(wc -l < "$LIST_PATH" | tr -d ' ')
echo "Found ${n_total} candidate control FODs."
echo "List file: $LIST_PATH"

if [[ "$n_total" -lt 3 ]]; then
    echo "ERROR: too few inputs for template building (need at least 3). Check CONTROL_GLOB / folder." >&2
    exit 1
fi

echo
echo "First 5 candidate inputs:"
head -n 5 "$LIST_PATH" || true
echo

echo "Preparing template input directories (symlinks for FODs + masks)..."
find "$TPL_INPUT_DIR" -maxdepth 1 -type l -delete || true
find "$TPL_MASK_DIR" -maxdepth 1 -type l -delete || true

: > "$MASK_LIST_PATH"

n_kept=0
n_missing_mask=0

# For each FOD, find its corresponding mask in FOD_DIR:
#   subject_X_date_Y_FOD_wm_norm.mif  ->  subject_X_date_Y_dwi_mask.mif
while IFS= read -r fod; do
    bname="$(basename "$fod")"
    baseprefix="${bname%_FOD_wm_norm.mif}"
    mask_src="$FOD_DIR/${baseprefix}_dwi_mask.mif"

    if [[ ! -f "$mask_src" ]]; then
        echo "WARNING: missing mask for ${bname} -> skipping this subject for template" >&2
        echo "  Expected: $mask_src" >&2
        n_missing_mask=$((n_missing_mask + 1))
        continue
    fi

    # Symlink input FOD
    ln -s "$fod" "$TPL_INPUT_DIR/$bname"

    # Symlink mask with same basename as input image (population_template matches on name)
    ln -s "$mask_src" "$TPL_MASK_DIR/$bname"

    echo "$mask_src" >> "$MASK_LIST_PATH"
    n_kept=$((n_kept + 1))
done < "$LIST_PATH"

echo
echo "Kept ${n_kept} subjects with matching masks (skipped ${n_missing_mask} without masks)."
echo "Mask list file: $MASK_LIST_PATH"

if [[ "$n_kept" -lt 3 ]]; then
    echo "ERROR: too few inputs with masks for template building (need at least 3)." >&2
    exit 1
fi

# -----------------------------
# 2) BUILD TEMPLATE (WITH MASKS + TEMPLATE MASK + WARPS)
# -----------------------------
echo
echo "Building population template..."
echo "Logging to: $LOG_PATH"
echo

{
    echo "=== population_template run ==="
    echo "Date: $(date)"
    echo "FOD_DIR: $FOD_DIR"
    echo "LIST_PATH: $LIST_PATH"
    echo "MASK_LIST_PATH: $MASK_LIST_PATH"
    echo "TPL_INPUT_DIR: $TPL_INPUT_DIR"
    echo "TPL_MASK_DIR: $TPL_MASK_DIR"
    echo "TEMPLATE_OUT: $TEMPLATE_OUT"
    echo "TEMPLATE_MASK: $TEMPLATE_MASK"
    echo "WARP_DIR: $WARP_DIR"
    echo "VOXEL_SIZE: $TEMPLATE_VOXEL_SIZE"
    echo "INITIAL_ALIGNMENT: $INITIAL_ALIGNMENT"
    echo "MRTRIX_NTHREADS: $MRTRIX_NTHREADS"
    echo "N_INPUTS_USED: $n_kept"
    echo
} > "$LOG_PATH"

mkdir -p "$WARP_DIR"

mrtrix population_template \
    "$TPL_INPUT_DIR" \
    "$TEMPLATE_OUT" \
    -voxel_size "$TEMPLATE_VOXEL_SIZE" \
    -initial_alignment "$INITIAL_ALIGNMENT" \
    -mask_dir "$TPL_MASK_DIR" \
    -template_mask "$TEMPLATE_MASK" \
    -warp_dir "$WARP_DIR" \
    -scratch "$SCRATCH_DIR" \
    -force >> "$LOG_PATH" 2>&1

echo
echo "Template created:"
echo "  $TEMPLATE_OUT"
echo "Template mask created:"
echo "  $TEMPLATE_MASK"
echo "Warps written to:"
echo "  $WARP_DIR"
echo

# -----------------------------
# 3) GENERATE TEMPLATE-SPACE GM / CSF CONTRASTS (BY WARPING CONTROLS)
# -----------------------------
if [[ "$MAKE_TISSUE_TEMPLATES" == "1" ]]; then
    echo "Generating template-space GM/CSF images using control->template warps..."
    rm -rf "$XFM_GM_DIR" "$XFM_CSF_DIR"
    mkdir -p "$XFM_GM_DIR" "$XFM_CSF_DIR"

    # Build per-subject transformed GM/CSF images
    n_tissue_kept=0
    n_missing_gm=0
    n_missing_csf=0
    n_missing_warp=0

    while IFS= read -r fod; do
        bname="$(basename "$fod")"
        baseprefix="${bname%_FOD_wm_norm.mif}"

        gm_src="$FOD_DIR/${baseprefix}${GM_SUFFIX}"
        csf_src="$FOD_DIR/${baseprefix}${CSF_SUFFIX}"
        warp_src="$WARP_DIR/$bname"

        if [[ ! -f "$warp_src" ]]; then
            echo "WARNING: missing warp for ${bname} -> skipping tissue transforms" >&2
            echo "  Expected: $warp_src" >&2
            n_missing_warp=$((n_missing_warp + 1))
            continue
        fi
        if [[ ! -f "$gm_src" ]]; then
            echo "WARNING: missing GM image for ${baseprefix} -> skipping GM for this subject" >&2
            echo "  Expected: $gm_src" >&2
            n_missing_gm=$((n_missing_gm + 1))
        fi
        if [[ ! -f "$csf_src" ]]; then
            echo "WARNING: missing CSF image for ${baseprefix} -> skipping CSF for this subject" >&2
            echo "  Expected: $csf_src" >&2
            n_missing_csf=$((n_missing_csf + 1))
        fi

        # Only include subject if we have BOTH GM and CSF for clean downstream use
        if [[ ! -f "$gm_src" || ! -f "$csf_src" ]]; then
            continue
        fi

        gm_out="$XFM_GM_DIR/${baseprefix}_GM_in_template.mif"
        csf_out="$XFM_CSF_DIR/${baseprefix}_CSF_in_template.mif"

        # Apply control->template warp; use template as reference grid
        mrtrix mrtransform "$gm_src" "$gm_out" \
            -warp_full "$warp_src" \
            -template "$TEMPLATE_OUT" \
            -interp "$TISSUE_INTERP" \
            -force >> "$LOG_PATH" 2>&1


        mrtrix mrtransform "$csf_src" "$csf_out" \
            -warp_full "$warp_src" \
            -template "$TEMPLATE_OUT" \
            -interp "$TISSUE_INTERP" \
            -force >> "$LOG_PATH" 2>&1

        n_tissue_kept=$((n_tissue_kept + 1))
    done < "$LIST_PATH"

    echo "Tissue transforms completed for ${n_tissue_kept} subjects."
    echo "Missing: warps=${n_missing_warp}, GM=${n_missing_gm}, CSF=${n_missing_csf}"

    if [[ "$n_tissue_kept" -lt 3 ]]; then
        echo "ERROR: too few subjects with GM+CSF+warp to build tissue templates (need >=3)." >&2
        exit 1
    fi

    # Average transformed GM/CSF images in template space
    # Use mrcat -> mrmath (avoids huge argument lists on large cohorts)
    echo "Averaging GM in template space..."
    mrtrix mrcat "$XFM_GM_DIR"/*.mif -axis 3 "$GM_STACK_4D" -force >> "$LOG_PATH" 2>&1
    mrtrix mrmath "$GM_STACK_4D" mean -axis 3 "$TEMPLATE_GM" -force >> "$LOG_PATH" 2>&1

    echo "Averaging CSF in template space..."
    mrtrix mrcat "$XFM_CSF_DIR"/*.mif -axis 3 "$CSF_STACK_4D" -force >> "$LOG_PATH" 2>&1
    mrtrix mrmath "$CSF_STACK_4D" mean -axis 3 "$TEMPLATE_CSF" -force >> "$LOG_PATH" 2>&1

    echo "Template GM created : $TEMPLATE_GM"
    echo "Template CSF created: $TEMPLATE_CSF"
    echo
fi

# -----------------------------
# 4) DERIVE TEMPLATE AFD (QC)  -> 3D voxel image (+ optional NIfTI)
# -----------------------------
if [[ "$MAKE_TEMPLATE_AFD" == "1" ]]; then
    echo "Deriving template AFD map (QC)..."
    rm -rf "$AFD_DIR"
    mkdir -p "$AFD_DIR"

    AFD_FX_BASENAME="template_AFD_fixel.mif"
    AFD_FX_PATH="${AFD_DIR}/${AFD_FX_BASENAME}"

    AFD_VOX_MIF="${AFD_DIR}/template_AFD_voxel.mif"
    AFD_VOX_MASKED_MIF="${AFD_DIR}/template_AFD_voxel_masked.mif"

    mrtrix fod2fixel "$TEMPLATE_OUT" "$AFD_DIR" -afd "$AFD_FX_BASENAME" -force >> "$LOG_PATH" 2>&1
    mrtrix fixel2voxel "$AFD_FX_PATH" mean "$AFD_VOX_MIF" >> "$LOG_PATH" 2>&1

    if [[ "$MASK_TEMPLATE_AFD" == "1" ]]; then
        if [[ ! -f "$TEMPLATE_MASK" ]]; then
            echo "WARNING: template mask not found ($TEMPLATE_MASK) -> cannot mask AFD" >&2
            mv -f "$AFD_VOX_MIF" "$TEMPLATE_AFD_MIF"
        else
            mrtrix mrcalc "$AFD_VOX_MIF" "$TEMPLATE_MASK" -mult "$AFD_VOX_MASKED_MIF" >> "$LOG_PATH" 2>&1
            mv -f "$AFD_VOX_MASKED_MIF" "$TEMPLATE_AFD_MIF"
            rm -f "$AFD_VOX_MIF"
        fi
    else
        mv -f "$AFD_VOX_MIF" "$TEMPLATE_AFD_MIF"
    fi

    echo "  AFD 3D (mif): $TEMPLATE_AFD_MIF"

    if [[ "$EXPORT_TEMPLATE_AFD_NIFTI" == "1" ]]; then
        mrtrix mrconvert "$TEMPLATE_AFD_MIF" "$TEMPLATE_AFD_NII" -datatype float32 -force >> "$LOG_PATH" 2>&1
        echo "  AFD 3D (nii): $TEMPLATE_AFD_NII"
    fi

    echo
fi

echo "Done."
