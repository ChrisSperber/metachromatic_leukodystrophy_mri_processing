#!/usr/bin/env bash
# Convert all DICOMs of controls' T1 images using dcm2niix
# most images are found recursively under a base folder; a few additional cases are explicitly handled
# all images are converted into a single output folder $output_dir
set -euo pipefail

# --- USER SETTINGS ---
script_dir="$(dirname "$(realpath "$0")")"
projects_path="$(realpath "$script_dir/../..")"

input_dir="$projects_path/mld_data/controls/T1" # main folder containing subfolders with DICOMs
output_dir="$projects_path/mld_data/controls/T1_nifti" # NIfTI output directory

# additional folder containing T1 images not included in $input_dir
extra_series_dirs=(
  "$projects_path/mld_data/controls/MP2RAGE/MLD119_prisma/06_t1_mp2rage_sag_1mm_UNI_Images"
  "$projects_path/mld_data/controls/MP2RAGE/MLD119_skyra/06_t1_mp2rage_sag_1mm_UNI_Images"
  "$projects_path/mld_data/controls/MP2RAGE/MLD120/08_t1_mp2rage_sag_1mm_UNI_Images"
  "$projects_path/mld_data/controls/MP2RAGE/MLD199/15_t1_mp2rage_sag_1mm_UNI_Images"
)

# ----------------------

mkdir -p "$output_dir"

# convert main directory; only convert leaf directories that contain files
find "$input_dir" -type d -print0 | while IFS= read -r -d '' d; do
  # must contain files
  find "$d" -maxdepth 1 -type f -print -quit | grep -q . || continue
  # must NOT contain subdirectories
  find "$d" -mindepth 1 -type d -print -quit | grep -q . && continue

  subj="$(basename "$(dirname "$d")")"     # <- MLD100
  echo "Converting: $d (subject=$subj)"
  if ! dcm2niix -z y -f "${subj}_%p_%s" -o "$output_dir" "$d"; then
    echo "WARN: dcm2niix failed for: $d — skipping."
    continue
  fi
done

# extra_series_dirs defined above
for d in "${extra_series_dirs[@]}"; do
  [[ -d "$d" ]] || { echo "Skip (not a dir): $d"; continue; }

  subj="$(basename "$(dirname "$d")")"   # e.g., MLD119_prisma or MLD120
  echo "Converting: $d (subject=$subj)"
  if ! dcm2niix -z y -f "${subj}_%p_%s" -o "$output_dir" "$d"; then
    echo "WARN: dcm2niix failed for: $d — skipping."
  fi
done
