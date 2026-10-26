#!/usr/bin/env bash
# convert new sample of diffusion data into FA/MD maps
# use reverse b0 for susceptibility correction via FSL topup & eddy
#
# MRtrix commands are run inside a dedicated conda environment.
# FSL commands are called directly from the local shell installation.
# shellcheck disable=SC2094

set -euo pipefail

# --------- config ---------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

TEMP_SOURCE_DATA_DIR="$PROJECT_DIR/temp2convert/data_converted_dti"
MANIFEST_TSV_PATH="$TEMP_SOURCE_DATA_DIR/_manifest/dti_manifest.tsv"

OUTPUT_DIR="$PROJECT_DIR/output_fa_md"
LOG_DIR="$OUTPUT_DIR/_logs"
SCRATCH_ROOT="$OUTPUT_DIR/_scratch"
SUMMARY_TSV="$OUTPUT_DIR/_processing_summary.tsv"

MRTRIX_CONDA_ENV="${MRTRIX_CONDA_ENV:-mrtrix3}"
USE_CONDA_RUN="${USE_CONDA_RUN:-1}"
MRTRIX_NTHREADS="${MRTRIX_NTHREADS:-6}"

# FSL eddy executable. Override if needed, e.g.
#   EDDY_COMMAND=eddy_openmp ./process_fa_md_fsl_local_v2.sh
#   EDDY_COMMAND=eddy_cuda ./process_fa_md_fsl_local_v2.sh
EDDY_COMMAND="${EDDY_COMMAND:-eddy}"

# Fit conventional DTI metrics using b=0 and the low-b shell only.
DTI_SHELL="${DTI_SHELL:-700}"

# Treat b-values <= this value as b0.
B0_THRESHOLD="${B0_THRESHOLD:-100}"

# Numerical tolerance for TE/TR/flip-angle consistency checks.
FLOAT_TOL="${FLOAT_TOL:-0.0001}"

# Replace existing completed outputs when set to 1.
OVERWRITE="${OVERWRITE:-0}"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$SCRATCH_ROOT"

# --------- command wrappers ---------

mrtrix() {
  if [[ -n "$MRTRIX_CONDA_ENV" && "$USE_CONDA_RUN" == "1" ]]; then
    conda run -n "$MRTRIX_CONDA_ENV" "$@"
  else
    "$@"
  fi
}

fsl() {
  "$@"
}

export MRTRIX_NTHREADS

# --------- helper functions ---------

log_msg() {
  local log="$1"
  shift
  printf '%s\n' "$*" | tee -a "$log" >&2
}

json_path_for_nifti() {
  local nifti="$1"
  if [[ "$nifti" == *.nii.gz ]]; then
    printf '%s\n' "${nifti%.nii.gz}.json"
  elif [[ "$nifti" == *.nii ]]; then
    printf '%s\n' "${nifti%.nii}.json"
  else
    return 1
  fi
}

read_json_value() {
  local json_file="$1"
  local key="$2"

  python3 - "$json_file" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

value = data.get(key, None)
if value is None:
    raise SystemExit(1)

if isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PY
}

pe_to_fsl_vector() {
  local pe="$1"

  case "$pe" in
    i)  echo "1 0 0" ;;
    i-) echo "-1 0 0" ;;
    j)  echo "0 1 0" ;;
    j-) echo "0 -1 0" ;;
    k)  echo "0 0 1" ;;
    k-) echo "0 0 -1" ;;
    *)  return 1 ;;
  esac
}

pe_is_opposite() {
  local pe1="$1"
  local pe2="$2"

  python3 - "$pe1" "$pe2" <<'PY'
import sys

opposite = {
    "i": "i-",
    "i-": "i",
    "j": "j-",
    "j-": "j",
    "k": "k-",
    "k-": "k",
}

a, b = sys.argv[1:3]
raise SystemExit(0 if opposite.get(a) == b else 1)
PY
}

float_abs_diff_le() {
  local a="$1"
  local b="$2"
  local tol="$3"

  python3 - "$a" "$b" "$tol" <<'PY'
import math
import sys

try:
    a, b, tol = map(float, sys.argv[1:4])
except ValueError:
    raise SystemExit(1)

raise SystemExit(
    0
    if math.isfinite(a) and math.isfinite(b) and abs(a - b) <= tol
    else 1
)
PY
}

read_first_bval() {
  local bval_file="$1"

  python3 - "$bval_file" <<'PY'
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    vals = f.read().split()

if not vals:
    raise SystemExit(1)

print(vals[0])
PY
}

count_bvals() {
  local bval_file="$1"

  python3 - "$bval_file" <<'PY'
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    vals = f.read().split()

print(len(vals))
PY
}

bval_is_b0() {
  local bval="$1"
  local threshold="$2"

  python3 - "$bval" "$threshold" <<'PY'
import sys

b, th = map(float, sys.argv[1:3])
raise SystemExit(0 if b <= th else 1)
PY
}

append_summary() {
  local subject_id="$1"
  local session_id="$2"
  local status="$3"
  local message="$4"

  printf '%s\t%s\t%s\t%s\n' \
    "$subject_id" "$session_id" "$status" "$message" >> "$SUMMARY_TSV"
}

# --------- tool sanity checks ---------

[[ -f "$MANIFEST_TSV_PATH" ]] || {
  echo "ERROR: Manifest not found: $MANIFEST_TSV_PATH" >&2
  exit 1
}

command -v conda >/dev/null 2>&1 || {
  echo "ERROR: conda is not available in the current shell." >&2
  exit 1
}

mrtrix mrconvert -help >/dev/null 2>&1 || {
  echo "ERROR: MRtrix command unavailable in environment '$MRTRIX_CONDA_ENV': mrconvert" >&2
  exit 1
}
mrtrix dwidenoise -help >/dev/null 2>&1 || {
  echo "ERROR: MRtrix command unavailable in environment '$MRTRIX_CONDA_ENV': dwidenoise" >&2
  exit 1
}
mrtrix mrdegibbs -help >/dev/null 2>&1 || {
  echo "ERROR: MRtrix command unavailable in environment '$MRTRIX_CONDA_ENV': mrdegibbs" >&2
  exit 1
}
mrtrix dwiextract -help >/dev/null 2>&1 || {
  echo "ERROR: MRtrix command unavailable in environment '$MRTRIX_CONDA_ENV': dwiextract" >&2
  exit 1
}
mrtrix dwi2mask -help >/dev/null 2>&1 || {
  echo "ERROR: MRtrix command unavailable in environment '$MRTRIX_CONDA_ENV': dwi2mask" >&2
  exit 1
}
mrtrix dwi2tensor -help >/dev/null 2>&1 || {
  echo "ERROR: MRtrix command unavailable in environment '$MRTRIX_CONDA_ENV': dwi2tensor" >&2
  exit 1
}
mrtrix tensor2metric -help >/dev/null 2>&1 || {
  echo "ERROR: MRtrix command unavailable in environment '$MRTRIX_CONDA_ENV': tensor2metric" >&2
  exit 1
}

for tool in topup fslmerge fslmaths bet "$EDDY_COMMAND"; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: FSL tool unavailable from the local shell: $tool" >&2
    exit 1
  }
done

if ! command -v eddy_quad >/dev/null 2>&1; then
  echo "WARNING: eddy_quad is not available. Eddy QC reports will be skipped." >&2
fi

# Detect dwiextract shell option spelling.
if mrtrix dwiextract -help 2>&1 | grep -q -- '-shells'; then
  DWIEXTRACT_SHELL_OPT="-shells"
else
  DWIEXTRACT_SHELL_OPT="-shell"
fi

# --------- initialise summary ---------

printf 'subject_id\tsession_id\tprocessing_status\tmessage\n' > "$SUMMARY_TSV"

# --------- process manifest ---------

while IFS=$'\t' read -r \
  subject_id \
  session_id \
  _session_folder \
  dti_image_rel \
  dti_bval_rel \
  dti_bvec_rel \
  pa_image_rel \
  pa_bval_rel \
  pa_bvec_rel \
  status
do
  [[ -n "$subject_id" ]] || continue

  if [[ "$status" != "complete" ]]; then
    append_summary "$subject_id" "$session_id" "skipped_manifest" "status=$status"
    continue
  fi

  SESSION_OUT="$OUTPUT_DIR/$subject_id/$session_id"
  SESSION_LOG="$LOG_DIR/${subject_id}_${session_id}.log"
  SESSION_SCRATCH="$SCRATCH_ROOT/${subject_id}_${session_id}"

  mkdir -p "$SESSION_OUT"
  rm -f "$SESSION_LOG"

  FINAL_DWI="$SESSION_OUT/dwi_preprocessed.mif"
  FINAL_MASK="$SESSION_OUT/brain_mask.mif"
  FINAL_TENSOR="$SESSION_OUT/tensor.mif"
  FINAL_FA="$SESSION_OUT/FA.nii.gz"
  FINAL_MD="$SESSION_OUT/MD.nii.gz"

  if [[ "$OVERWRITE" != "1" \
        && -s "$FINAL_DWI" \
        && -s "$FINAL_MASK" \
        && -s "$FINAL_TENSOR" \
        && -s "$FINAL_FA" \
        && -s "$FINAL_MD" ]]; then
    log_msg "$SESSION_LOG" "SKIP: final outputs already exist."
    append_summary "$subject_id" "$session_id" "already_complete" "Outputs already exist"
    continue
  fi

  rm -rf "$SESSION_SCRATCH"
  mkdir -p "$SESSION_SCRATCH"

  log_msg "$SESSION_LOG" "========================================"
  log_msg "$SESSION_LOG" "Subject: $subject_id"
  log_msg "$SESSION_LOG" "Session: $session_id"
  log_msg "$SESSION_LOG" "========================================"

  DTI_IMAGE="$TEMP_SOURCE_DATA_DIR/$dti_image_rel"
  DTI_BVAL="$TEMP_SOURCE_DATA_DIR/$dti_bval_rel"
  DTI_BVEC="$TEMP_SOURCE_DATA_DIR/$dti_bvec_rel"
  PA_IMAGE="$TEMP_SOURCE_DATA_DIR/$pa_image_rel"
  PA_BVAL="$TEMP_SOURCE_DATA_DIR/$pa_bval_rel"
  PA_BVEC="$TEMP_SOURCE_DATA_DIR/$pa_bvec_rel"

  DTI_JSON="$(json_path_for_nifti "$DTI_IMAGE")"
  PA_JSON="$(json_path_for_nifti "$PA_IMAGE")"

  session_failed=0
  fail_message=""

  for required_file in \
    "$DTI_IMAGE" "$DTI_BVAL" "$DTI_BVEC" "$DTI_JSON" \
    "$PA_IMAGE" "$PA_BVAL" "$PA_BVEC" "$PA_JSON"
  do
    if [[ ! -f "$required_file" ]]; then
      session_failed=1
      fail_message="Missing required file: $required_file"
      break
    fi
  done

  if [[ "$session_failed" == "1" ]]; then
    log_msg "$SESSION_LOG" "ERROR: $fail_message"
    append_summary "$subject_id" "$session_id" "failed" "$fail_message"
    continue
  fi

  if ! DTI_PE="$(read_json_value "$DTI_JSON" "PhaseEncodingDirection")"; then
    session_failed=1
    fail_message="Missing PhaseEncodingDirection in DTI JSON"
  elif ! PA_PE="$(read_json_value "$PA_JSON" "PhaseEncodingDirection")"; then
    session_failed=1
    fail_message="Missing PhaseEncodingDirection in PA JSON"
  elif ! DTI_TRT="$(read_json_value "$DTI_JSON" "TotalReadoutTime")"; then
    session_failed=1
    fail_message="Missing TotalReadoutTime in DTI JSON"
  elif ! PA_TRT="$(read_json_value "$PA_JSON" "TotalReadoutTime")"; then
    session_failed=1
    fail_message="Missing TotalReadoutTime in PA JSON"
  fi

  if [[ "$session_failed" == "1" ]]; then
    log_msg "$SESSION_LOG" "ERROR: $fail_message"
    append_summary "$subject_id" "$session_id" "failed" "$fail_message"
    continue
  fi

  if ! pe_is_opposite "$DTI_PE" "$PA_PE"; then
    fail_message="PhaseEncodingDirection values are not opposite: DTI=$DTI_PE, PA=$PA_PE"
    log_msg "$SESSION_LOG" "ERROR: $fail_message"
    append_summary "$subject_id" "$session_id" "failed" "$fail_message"
    continue
  fi

  if ! DTI_PE_VEC="$(pe_to_fsl_vector "$DTI_PE")"; then
    fail_message="Unsupported DTI PhaseEncodingDirection: $DTI_PE"
    log_msg "$SESSION_LOG" "ERROR: $fail_message"
    append_summary "$subject_id" "$session_id" "failed" "$fail_message"
    continue
  fi

  if ! PA_PE_VEC="$(pe_to_fsl_vector "$PA_PE")"; then
    fail_message="Unsupported PA PhaseEncodingDirection: $PA_PE"
    log_msg "$SESSION_LOG" "ERROR: $fail_message"
    append_summary "$subject_id" "$session_id" "failed" "$fail_message"
    continue
  fi

  log_msg "$SESSION_LOG" "DTI PE direction: $DTI_PE"
  log_msg "$SESSION_LOG" "DTI TotalReadoutTime: $DTI_TRT"
  log_msg "$SESSION_LOG" "PA PE direction: $PA_PE"
  log_msg "$SESSION_LOG" "PA TotalReadoutTime: $PA_TRT"

  for key in EchoTime RepetitionTime FlipAngle; do
    if dti_val="$(read_json_value "$DTI_JSON" "$key" 2>/dev/null)" \
       && pa_val="$(read_json_value "$PA_JSON" "$key" 2>/dev/null)"; then
      if ! float_abs_diff_le "$dti_val" "$pa_val" "$FLOAT_TOL"; then
        log_msg "$SESSION_LOG" \
          "WARNING: $key differs between DTI and PA: DTI=$dti_val, PA=$pa_val"
      fi
    fi
  done

  FIRST_DTI_BVAL="$(read_first_bval "$DTI_BVAL")"
  if ! bval_is_b0 "$FIRST_DTI_BVAL" "$B0_THRESHOLD"; then
    fail_message="First DTI volume is not b0: b=$FIRST_DTI_BVAL"
    log_msg "$SESSION_LOG" "ERROR: $fail_message"
    append_summary "$subject_id" "$session_id" "failed" "$fail_message"
    continue
  fi

  FIRST_PA_BVAL="$(read_first_bval "$PA_BVAL")"
  if ! bval_is_b0 "$FIRST_PA_BVAL" "$B0_THRESHOLD"; then
    fail_message="PA image is not b0 according to its bval file: b=$FIRST_PA_BVAL"
    log_msg "$SESSION_LOG" "ERROR: $fail_message"
    append_summary "$subject_id" "$session_id" "failed" "$fail_message"
    continue
  fi

  N_DWI_VOLUMES="$(count_bvals "$DTI_BVAL")"

  ACQPARAMS="$SESSION_SCRATCH/acqparams.txt"
  INDEX="$SESSION_SCRATCH/index.txt"

  printf '%s %s\n' "$DTI_PE_VEC" "$DTI_TRT" > "$ACQPARAMS"
  printf '%s %s\n' "$PA_PE_VEC" "$PA_TRT" >> "$ACQPARAMS"

  python3 - "$N_DWI_VOLUMES" > "$INDEX" <<'PY'
import sys
n = int(sys.argv[1])
print(" ".join(["1"] * n))
PY

  log_msg "$SESSION_LOG" "Generated acqparams.txt:"
  while IFS= read -r line; do
    log_msg "$SESSION_LOG" "  $line"
  done < "$ACQPARAMS"

  DWI_RAW_MIF="$SESSION_SCRATCH/dwi_raw.mif"
  DWI_DENOISED_MIF="$SESSION_SCRATCH/dwi_denoised.mif"
  DWI_DEGIBBS_MIF="$SESSION_SCRATCH/dwi_degibbs.mif"
  DTI_B0_MIF="$SESSION_SCRATCH/dti_b0.mif"
  PA_RAW_MIF="$SESSION_SCRATCH/pa_raw.mif"
  PA_DEGIBBS_MIF="$SESSION_SCRATCH/pa_degibbs.mif"

  DTI_B0_NII="$SESSION_SCRATCH/dti_b0.nii.gz"
  PA_B0_NII="$SESSION_SCRATCH/pa_b0.nii.gz"
  B0_PAIR_NII="$SESSION_SCRATCH/b0_pair.nii.gz"

  TOPUP_BASE="$SESSION_SCRATCH/topup_results"
  TOPUP_FOUT="$SESSION_SCRATCH/topup_field.nii.gz"
  TOPUP_IOUT="$SESSION_SCRATCH/topup_corrected_b0s.nii.gz"

  TOPUP_MEAN_B0="$SESSION_SCRATCH/topup_mean_b0.nii.gz"
  BRAIN_BASE="$SESSION_SCRATCH/topup_mean_b0_brain"
  BRAIN_MASK="$SESSION_SCRATCH/topup_mean_b0_brain_mask.nii.gz"

  DWI_EDDY_IN="$SESSION_SCRATCH/dwi_eddy_input.nii.gz"
  EDDY_BVAL="$SESSION_SCRATCH/dwi_eddy_input.bval"
  EDDY_BVEC="$SESSION_SCRATCH/dwi_eddy_input.bvec"
  EDDY_BASE="$SESSION_SCRATCH/eddy_corrected"

  QC_DIR="$SESSION_OUT/eddy_qc"

  {
    log_msg "$SESSION_LOG" "Converting DTI to MRtrix format..."
    mrtrix mrconvert \
      "$DTI_IMAGE" \
      "$DWI_RAW_MIF" \
      -fslgrad "$DTI_BVEC" "$DTI_BVAL" \
      -json_import "$DTI_JSON" \
      -force

    log_msg "$SESSION_LOG" "Denoising DTI..."
    mrtrix dwidenoise "$DWI_RAW_MIF" "$DWI_DENOISED_MIF" -force

    log_msg "$SESSION_LOG" "Removing Gibbs ringing from DTI..."
    mrtrix mrdegibbs "$DWI_DENOISED_MIF" "$DWI_DEGIBBS_MIF" -force

    log_msg "$SESSION_LOG" "Extracting first DTI b0..."
    mrtrix mrconvert "$DWI_DEGIBBS_MIF" "$DTI_B0_MIF" -coord 3 0 -force

    log_msg "$SESSION_LOG" "Preparing PA b0..."
    mrtrix mrconvert "$PA_IMAGE" "$PA_RAW_MIF" -json_import "$PA_JSON" -force
    mrtrix mrdegibbs "$PA_RAW_MIF" "$PA_DEGIBBS_MIF" -force

    mrtrix mrconvert "$DTI_B0_MIF" "$DTI_B0_NII" -force
    mrtrix mrconvert "$PA_DEGIBBS_MIF" "$PA_B0_NII" -force

    log_msg "$SESSION_LOG" "Creating reverse-PE b0 pair..."
    fsl fslmerge -t "$B0_PAIR_NII" "$DTI_B0_NII" "$PA_B0_NII"

    log_msg "$SESSION_LOG" "Running topup..."
    fsl topup \
      --imain="$B0_PAIR_NII" \
      --datain="$ACQPARAMS" \
      --config=b02b0.cnf \
      --out="$TOPUP_BASE" \
      --fout="$TOPUP_FOUT" \
      --iout="$TOPUP_IOUT"

    log_msg "$SESSION_LOG" "Creating brain mask from topup-corrected b0 images..."
    fsl fslmaths "$TOPUP_IOUT" -Tmean "$TOPUP_MEAN_B0"
    fsl bet "$TOPUP_MEAN_B0" "$BRAIN_BASE" -m -f 0.25

    log_msg "$SESSION_LOG" "Exporting DWI for eddy..."
    mrtrix mrconvert \
      "$DWI_DEGIBBS_MIF" \
      "$DWI_EDDY_IN" \
      -export_grad_fsl "$EDDY_BVEC" "$EDDY_BVAL" \
      -force

    log_msg "$SESSION_LOG" "Running $EDDY_COMMAND..."
    fsl "$EDDY_COMMAND" \
      --imain="$DWI_EDDY_IN" \
      --mask="$BRAIN_MASK" \
      --acqp="$ACQPARAMS" \
      --index="$INDEX" \
      --bvecs="$EDDY_BVEC" \
      --bvals="$EDDY_BVAL" \
      --topup="$TOPUP_BASE" \
      --out="$EDDY_BASE" \
      --repol

    ROTATED_BVECS="${EDDY_BASE}.eddy_rotated_bvecs"

    [[ -f "$ROTATED_BVECS" ]] || {
      echo "ERROR: eddy did not produce rotated b-vectors: $ROTATED_BVECS" >&2
      exit 1
    }

    log_msg "$SESSION_LOG" "Importing eddy-corrected data back into MRtrix..."
    mrtrix mrconvert \
      "${EDDY_BASE}.nii.gz" \
      "$FINAL_DWI" \
      -fslgrad "$ROTATED_BVECS" "$EDDY_BVAL" \
      -json_import "$DTI_JSON" \
      -force

    log_msg "$SESSION_LOG" "Creating final DWI brain mask..."
    mrtrix dwi2mask "$FINAL_DWI" "$FINAL_MASK" -force

    DTI_FIT_MIF="$SESSION_SCRATCH/dwi_dti_shell.mif"

    log_msg "$SESSION_LOG" "Extracting b=0 and b~${DTI_SHELL} volumes for tensor fitting..."
    mrtrix dwiextract \
      "$FINAL_DWI" \
      "$DTI_FIT_MIF" \
      "$DWIEXTRACT_SHELL_OPT" "0,$DTI_SHELL" \
      -force

    log_msg "$SESSION_LOG" "Fitting diffusion tensor..."
    mrtrix dwi2tensor \
      "$DTI_FIT_MIF" \
      "$FINAL_TENSOR" \
      -mask "$FINAL_MASK" \
      -force

    log_msg "$SESSION_LOG" "Generating FA and MD..."
    mrtrix tensor2metric \
      "$FINAL_TENSOR" \
      -fa "$FINAL_FA" \
      -adc "$FINAL_MD" \
      -mask "$FINAL_MASK" \
      -force

    cp "$ACQPARAMS" "$SESSION_OUT/acqparams.txt"
    cp "$INDEX" "$SESSION_OUT/index.txt"

    if command -v eddy_quad >/dev/null 2>&1; then
      log_msg "$SESSION_LOG" "Running eddy_quad QC..."
      rm -rf "$QC_DIR"

      if ! fsl eddy_quad \
        "$EDDY_BASE" \
        -idx "$INDEX" \
        -par "$ACQPARAMS" \
        -m "$BRAIN_MASK" \
        -b "$EDDY_BVAL" \
        -f "$TOPUP_FOUT" \
        -o "$QC_DIR"; then
        log_msg "$SESSION_LOG" \
          "WARNING: eddy_quad failed; FA/MD outputs were still generated."
      fi
    fi

    for output_file in \
      "$FINAL_DWI" "$FINAL_MASK" "$FINAL_TENSOR" "$FINAL_FA" "$FINAL_MD"
    do
      [[ -s "$output_file" ]] || {
        echo "ERROR: Expected output missing or empty: $output_file" >&2
        exit 1
      }
    done

  } >> "$SESSION_LOG" 2>&1 || {
    exit_code=$?
    fail_message="Exit code $exit_code; see $SESSION_LOG"
    printf 'ERROR: processing failed for %s / %s: %s\n' \
      "$subject_id" "$session_id" "$fail_message" >&2
    append_summary "$subject_id" "$session_id" "failed" "$fail_message"
    continue
  }

  log_msg "$SESSION_LOG" "Processing completed successfully."
  append_summary "$subject_id" "$session_id" "complete" "OK"
  rm -rf "$SESSION_SCRATCH"

done < <(
  python3 - "$MANIFEST_TSV_PATH" <<'PY'
import csv
import sys

path = sys.argv[1]

wanted = [
    "subject_id",
    "session_id",
    "session_folder",
    "dti_image",
    "dti_bval",
    "dti_bvec",
    "pa_image",
    "pa_bval",
    "pa_bvec",
    "status",
]

with open(path, "r", encoding="utf-8-sig", newline="") as f:
    reader = csv.DictReader(f, delimiter="\t")

    missing = [x for x in wanted if x not in (reader.fieldnames or [])]
    if missing:
        raise SystemExit(
            "ERROR: Manifest is missing required columns: " + ", ".join(missing)
        )

    for row in reader:
        values = [
            (row.get(col) or "").replace("\t", " ").replace("\n", " ")
            for col in wanted
        ]
        print("\t".join(values))
PY
)

echo
echo "Finished."
echo "Summary: $SUMMARY_TSV"
