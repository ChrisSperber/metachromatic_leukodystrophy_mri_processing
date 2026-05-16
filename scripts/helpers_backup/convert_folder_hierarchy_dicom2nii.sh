#!/usr/bin/env bash
set -euo pipefail

script_dir="$(dirname "$(realpath "$0")")"
projects_path="$(realpath "$script_dir/../../..")"
ROOT="$projects_path/temp2convert"

for subject_dir in "$ROOT"/*; do
    [ -d "$subject_dir" ] || continue

    for session_dir in "$subject_dir"/*; do
        [ -d "$session_dir" ] || continue

        for dicom_dir in "$session_dir"/*; do
            [ -d "$dicom_dir" ] || continue

            dicom_name="$(basename "$dicom_dir")"
            expected_out="$session_dir/${dicom_name}.nii.gz"

            if [ -f "$expected_out" ]; then
                echo "Skipping existing: $expected_out"
                continue
            fi

            echo "Converting $dicom_dir -> $expected_out"

            dcm2niix \
                -z y \
                -b y \
                -f "$dicom_name" \
                -o "$session_dir" \
                "$dicom_dir"
        done
    done
done
