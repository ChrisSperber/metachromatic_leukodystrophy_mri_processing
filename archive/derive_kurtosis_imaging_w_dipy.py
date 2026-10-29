"""Fit DKI maps (MK, AK, RK) from the corrected DWI inventory.

Uses DIPY's WLS fitting and default fit.mk()/ak()/rk() bounds.
Prints progress and writes a per-session processing/QC CSV.
No original DWI or mask files are modified.
"""

# %%
import csv
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import dipy
import nibabel as nib
import numpy as np
import pandas as pd
from dipy.core.gradients import gradient_table
from dipy.io.gradients import read_bvals_bvecs
from dipy.reconst.dki import DiffusionKurtosisModel

from mld_tbss.config import NOT_APPLICABLE, ORIGINAL_PROJECT_ROOT_DIR

DATA_MASTER_DIR = ORIGINAL_PROJECT_ROOT_DIR / "mld_data_master_2026"
INVENTORY_CSV = DATA_MASTER_DIR / "imaging_file_manifest.csv"
DIFFUSION_DERIVATIVES_DIR = DATA_MASTER_DIR / "derivatives" / "diffusion"
TEMP_PARENT_DIR = ORIGINAL_PROJECT_ROOT_DIR / "dwi_processing_tmp"
PROCESSING_LOG_CSV = DATA_MASTER_DIR / "dki_processing_log.csv"

SUBJECT_ID = "SubjectID"
SESSION_ID = "SessionID"
PATH_DWI_MIF = "PathDWIMIF"
PATH_MASK_MIF = "PathMaskMIF"

MRTRIX_CONDA_ENV = "mrtrix3"
FIT_METHOD = "WLS"
OVERWRITE = False
RUN_LIMIT = None  # Set to 1 to process one subject/session for testing

# Defaults of DIPY 1.11.0 DiffusionKurtosisFit.mk/ak/rk:
KURTOSIS_LOWER = -3.0 / 7.0
KURTOSIS_UPPER = {"MK": 10.0, "AK": 10.0, "RK": 10.0}

LOG_COLS = [
    SUBJECT_ID,
    SESSION_ID,
    "Status",
    "Error",
    "InputDWI",
    "InputMask",
    "DIPYVersion",
    "FitMethod",
    "NumVolumes",
    "MaskVoxels",
    "RuntimeSeconds",
    *[
        f"{metric}_{name}"
        for metric in ("MK", "AK", "RK")
        for name in (
            "Mean",
            "Median",
            "PctClippedLow",
            "PctClippedHigh",
            "PctClippedTotal",
            "PctNonfiniteRaw",
        )
    ],
]

# %%
# Helpers


def mrconvert(*arguments):
    """Run MRtrix without changing the active Python virtual environment."""
    cmd = [
        "conda",
        "run",
        "--no-capture-output",
        "-n",
        MRTRIX_CONDA_ENV,
        "mrconvert",
        *map(str, arguments),
    ]
    subprocess.run(cmd, check=True, capture_output=True, text=True)  # noqa: S603


def resolve_inventory_path(value):
    """Resolve a project-root-relative path; return None for absent entries."""
    if pd.isna(value):
        return None
    value = str(value).strip()
    if not value or value == str(NOT_APPLICABLE):
        return None
    path = Path(value)
    return path if path.is_absolute() else DATA_MASTER_DIR / path


def map_paths(subject, session):
    """Use BIDS-inspired filenames, under the existing diffusion derivatives tree."""
    sub = f"sub-{subject}" if not str(subject).startswith("sub-") else str(subject)
    ses = f"ses-{session}" if not str(session).startswith("ses-") else str(session)
    out_dir = DIFFUSION_DERIVATIVES_DIR / sub / ses / "dki"
    prefix = f"{sub}_{ses}"
    return {
        metric: out_dir / f"{prefix}_desc-{metric}_dwimap.nii.gz"
        for metric in ("MK", "AK", "RK")
    }


def write_log_row(record):
    """Append immediately, so results survive an interrupted batch."""
    new_file = not PROCESSING_LOG_CSV.exists() or PROCESSING_LOG_CSV.stat().st_size == 0
    with PROCESSING_LOG_CSV.open("a", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=LOG_COLS, extrasaction="ignore")
        if new_file:
            writer.writeheader()
        writer.writerow(record)


def metric_qc(raw, clipped, mask, metric):
    """Clipping percentages have ALL brain-mask voxels as denominator."""
    raw_values = raw[mask]
    clipped_values = clipped[mask]
    n = raw_values.size
    finite = np.isfinite(raw_values)
    lo = KURTOSIS_LOWER
    hi = KURTOSIS_UPPER[metric]
    low = finite & (raw_values < lo)
    high = finite & (raw_values > hi)
    # Nonfinite raw estimates are tracked separately, not counted as clipping.
    stats = {
        f"{metric}_PctClippedLow": 100.0 * np.count_nonzero(low) / n,
        f"{metric}_PctClippedHigh": 100.0 * np.count_nonzero(high) / n,
        f"{metric}_PctClippedTotal": 100.0
        * (np.count_nonzero(low) + np.count_nonzero(high))
        / n,
        f"{metric}_PctNonfiniteRaw": 100.0 * np.count_nonzero(~finite) / n,
    }
    valid = clipped_values[np.isfinite(clipped_values)]
    stats[f"{metric}_Mean"] = float(np.mean(valid)) if valid.size else np.nan
    stats[f"{metric}_Median"] = float(np.median(valid)) if valid.size else np.nan
    return stats


def validate_existing_outputs(paths):
    """Conservative restart check: each file must be a nonempty 3D NIfTI."""
    for file in paths.values():
        if not file.is_file() or file.stat().st_size == 0:
            return False
        try:
            if len(nib.load(str(file)).shape) != 3:  # type: ignore  # noqa: PLR2004
                return False
        except Exception:
            return False
    return True


# %%
# Read inventory and check environment

if shutil.which("conda") is None:
    raise RuntimeError("'conda' not available on PATH; needed for MRtrix conversion.")

TEMP_PARENT_DIR.mkdir(parents=True, exist_ok=True)

inventory_df = pd.read_csv(
    INVENTORY_CSV,
    dtype={SUBJECT_ID: str, SESSION_ID: str},
    keep_default_na=False,
)

required_cols = {SUBJECT_ID, SESSION_ID, PATH_DWI_MIF, PATH_MASK_MIF}
missing_cols = required_cols - set(inventory_df.columns)
if missing_cols:
    raise ValueError(f"Missing inventory columns: {sorted(missing_cols)}")

if inventory_df.duplicated([SUBJECT_ID, SESSION_ID]).any():
    raise ValueError("Duplicate subject/session rows in inventory.")

print(f"Sessions in inventory: {len(inventory_df)}")
print(f"DIPY version: {dipy.__version__}")
print(f"Fitting: {FIT_METHOD}, DIPY fit-method default kurtosis bounds")
print(f"Bounds: low={KURTOSIS_LOWER:.6f}; highs={KURTOSIS_UPPER}")
print(f"Log: {PROCESSING_LOG_CSV}")

# %%
# Process sessions

results = []
rows_to_process = inventory_df if RUN_LIMIT is None else inventory_df.head(RUN_LIMIT)

for number, (_, row) in enumerate(rows_to_process.iterrows(), start=1):
    subject = str(row[SUBJECT_ID]).strip()
    session = str(row[SESSION_ID]).strip()
    dwi_path = resolve_inventory_path(row[PATH_DWI_MIF])
    mask_path = resolve_inventory_path(row[PATH_MASK_MIF])
    outputs = map_paths(subject, session)
    start_time = time.perf_counter()

    result = {
        SUBJECT_ID: subject,
        SESSION_ID: session,
        "Status": "FAILED",
        "Error": "",
        "InputDWI": str(dwi_path) if dwi_path else "",
        "InputMask": str(mask_path) if mask_path else "",
        "DIPYVersion": dipy.__version__,
        "FitMethod": FIT_METHOD,
    }

    print(f"[{number}/{len(rows_to_process)}] {subject} / {session}", flush=True)

    try:
        if dwi_path is None or mask_path is None:
            raise FileNotFoundError("DWI or mask path missing in inventory")
        if not dwi_path.is_file() or not mask_path.is_file():
            raise FileNotFoundError("DWI or mask file not found")

        if not OVERWRITE and validate_existing_outputs(outputs):
            result["Status"] = "SKIPPED_EXISTS"
            print("  Existing MK/AK/RK maps: skipped")
            continue

        # Keep MRtrix conversions and output staging temporary.
        with tempfile.TemporaryDirectory(prefix="dki_", dir=TEMP_PARENT_DIR) as tmp:
            temp = Path(tmp)
            dwi_nii = temp / "dwi.nii.gz"
            mask_nii = temp / "mask.nii.gz"
            bvec_file = temp / "dwi.bvec"
            bval_file = temp / "dwi.bval"

            mrconvert(dwi_path, dwi_nii, "-export_grad_fsl", bvec_file, bval_file)
            mrconvert(mask_path, mask_nii, "-datatype", "bit")

            dwi_img = nib.load(str(dwi_nii))  # type: ignore
            mask_img = nib.load(str(mask_nii))  # type: ignore
            if len(dwi_img.shape) != 4 or len(mask_img.shape) != 3:  # type: ignore  # noqa: PLR2004
                raise ValueError("Expected 4D DWI and 3D brain mask")
            if dwi_img.shape[:3] != mask_img.shape:  # type: ignore
                raise ValueError("DWI/mask voxel dimensions differ")
            if not np.allclose(dwi_img.affine, mask_img.affine, atol=1e-3):  # type: ignore
                raise ValueError("DWI/mask spatial transforms differ")

            bvals, bvecs = read_bvals_bvecs(str(bval_file), str(bvec_file))
            if bvals is None or bvecs is None or len(bvals) != dwi_img.shape[3]:  # type: ignore
                raise ValueError("Missing or mismatching diffusion gradients")
            gtab = gradient_table(bvals, bvecs=bvecs, b0_threshold=50)
            if len(np.unique(np.round(bvals[bvals > 50] / 100))) < 2:  # noqa: PLR2004
                raise ValueError("Expected at least two nonzero b-value shells")

            mask = np.asarray(mask_img.dataobj) > 0  # type: ignore
            if not np.any(mask):
                raise ValueError("Empty brain mask")
            result["MaskVoxels"] = int(mask.sum())  # type: ignore
            result["NumVolumes"] = int(dwi_img.shape[3])  # type: ignore

            data = np.asarray(dwi_img.dataobj, dtype=np.float32)  # type: ignore
            if not np.isfinite(data[mask]).all():
                raise ValueError("Nonfinite input diffusion intensities inside mask")

            print("  Fitting DKI (WLS)...", flush=True)
            model = DiffusionKurtosisModel(gtab, fit_method=FIT_METHOD)
            fit = model.fit(data, mask=mask)
            del data

            staged = {}
            for metric, method in (("MK", fit.mk), ("AK", fit.ak), ("RK", fit.rk)):  # type: ignore
                print(f"  Computing {metric} and clipping QC...", flush=True)
                raw = method(min_kurtosis=None, max_kurtosis=None)  # type: ignore
                clipped = method()  # DIPY 1.11.0 fit-method defaults
                result.update(metric_qc(raw, clipped, mask, metric))  # type: ignore

                # Do not silently replace nonfinite inside-mask values with zeros.
                if not np.isfinite(clipped[mask]).all():
                    raise ValueError(
                        f"{metric} contains nonfinite estimates in brain mask"
                    )
                clean = np.where(mask, clipped, 0).astype(np.float32)
                staged_path = temp / outputs[metric].name
                img = nib.Nifti1Image(clean, dwi_img.affine, dwi_img.header.copy())  # type: ignore
                img.header.set_data_dtype(np.float32)
                nib.save(img, str(staged_path))  # type: ignore
                staged[metric] = staged_path
                del raw, clipped, clean

            # Publish only after ALL three maps have passed QC and been saved.
            out_dir = outputs["MK"].parent
            out_dir.mkdir(parents=True, exist_ok=True)
            for metric in ("MK", "AK", "RK"):
                os.replace(staged[metric], outputs[metric])
            if not validate_existing_outputs(outputs):
                raise RuntimeError("Output validation failed")

        result["Status"] = "COMPLETED"
        for metric in ("MK", "AK", "RK"):
            print(
                f"  {metric}: {result[f'{metric}_PctClippedTotal']:.2f}% clipped, "
                f"{result[f'{metric}_PctNonfiniteRaw']:.2f}% nonfinite (raw)"
            )

    except Exception as exc:
        result["Error"] = f"{type(exc).__name__}: {exc}"
        print(f"  FAILED: {result['Error']}")

    finally:
        result["RuntimeSeconds"] = round(time.perf_counter() - start_time, 2)  # type: ignore
        results.append(result)
        write_log_row(result)

# %%
# Review results from this run

results_df = pd.DataFrame(results)
print("\nProcessing summary:")
print(results_df["Status"].value_counts().to_string())
print(f"\nAppended processing records to: {PROCESSING_LOG_CSV}")
if not results_df.empty:
    qc_cols = [
        SUBJECT_ID,
        SESSION_ID,
        "Status",
        "MK_PctClippedTotal",
        "AK_PctClippedTotal",
        "RK_PctClippedTotal",
    ]
    print(results_df.reindex(columns=qc_cols).to_string(index=False))

# %%
