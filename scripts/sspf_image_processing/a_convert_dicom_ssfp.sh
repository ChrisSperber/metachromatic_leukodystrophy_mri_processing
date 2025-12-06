#!/usr/bin/env bash
# Convert all DICOMs files of controls' SSFP images using dcm2niix
# and reorient the resulting NIfTI files in place with FSL.
# All images are converted into the same folder to be handled
# further down the pipeline in Python.
set -euo pipefail

# --- USER SETTINGS ---
script_dir="$(dirname "$(realpath "$0")")"
projects_path="$(realpath "$script_dir/../../..")"

# main folder containing subfolders with DICOMs / IMA files
input_dir="$projects_path/mld_data/controls/ssfp"

# ---- tool checks ----
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Required tool '$1' not found in PATH" >&2
        exit 1
    }
}

need_cmd fslreorient2std
need_cmd dcm2niix

echo "Input directory: $input_dir"
echo "Starting recursive search for DICOM folders..."

# --- helper: process one directory ---
process_dir() {
    local dir="$1"
    local base
    base="$(basename "$dir")"

    # ---- skip spectroscopy / non-imaging folders ----
    case "$base" in
        *svs*|*SVS*|*spect*)
            echo "=== Skipping non-imaging directory: $dir ==="
            return 0
            ;;
    esac
    echo "=== Processing directory: $dir ==="

    # Look for any candidate "raw" files (not NIfTI) in this directory.
    # This will see dotfiles (.MR....IMA) as well.
    if ! find "$dir" -maxdepth 1 -type f \
        ! -name "*.nii" ! -name "*.nii.gz" | grep -q .; then
        echo "  No candidate files found here, skipping."
        return 0
    fi

    echo "  Candidate files found. Running dcm2niix..."

    # Run dcm2niix on the entire directory.
    # -z y     : gzip-compress NIfTIs
    # -f %p_%s : filename = protocol_series
    # -o dir   : write NIfTI into the same directory
    if ! dcm2niix -z y -f "%p_%s" -o "$dir" "$dir"; then
        echo "  WARNING: dcm2niix failed in $dir (maybe not valid DICOM?). Skipping." >&2
        return 0
    fi

    echo "  dcm2niix finished. Reorienting NIfTI files..."

    # Reorient all NIfTI files in this directory, if any, IN PLACE.
    shopt -s nullglob
    local nifti
    local found_nifti=false
    for nifti in "$dir"/*.nii "$dir"/*.nii.gz; do
        found_nifti=true
        echo "    Reorienting: $nifti"

        # Use a temporary output file, then move back over the original.
        local tmp
        if [[ "$nifti" == *.nii.gz ]]; then
            tmp="${nifti%.nii.gz}_tmp_reoriented.nii.gz"
        else
            tmp="${nifti%.nii}_tmp_reoriented.nii"
        fi

        fslreorient2std "$nifti" "$tmp"
        mv "$tmp" "$nifti"
    done
    shopt -u nullglob

    if [[ "$found_nifti" == false ]]; then
        echo "  No NIfTI files found after conversion (unexpected, but continuing)."
    else
        echo "  Finished reorienting NIfTI files in $dir."
    fi
}

export -f process_dir
export -f need_cmd

# --- main: walk directories up to a certain depth ---
find "$input_dir" -mindepth 1 -maxdepth 3 -type d -print0 \
    | while IFS= read -r -d '' d; do
        process_dir "$d"
      done

echo "All done."
