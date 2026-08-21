# %%  # noqa: D100
# Create and validate a DTI file manifest
#
# Expected directory structure:
#
# MAIN_FOLDER/
# ├── subject_001/
# │   ├── session_001/
# │   │   ├── ...DTI_2shell....nii.gz
# │   │   ├── ...DTI_2shell....bval
# │   │   ├── ...DTI_2shell....bvec
# │   │   ├── ...b0correct...PA....nii.gz
# │   │   ├── ...b0correct...PA....bval
# │   │   └── ...b0correct...PA....bvec
#
# The output paths are stored relative to MAIN_FOLDER.

# %%
import hashlib
from pathlib import Path

import nibabel as nib
import numpy as np
import pandas as pd

from mld_tbss.config import ORIGINAL_PROJECT_ROOT_DIR

# %%
# Settings

# %%
# main folder containing the subject folders.
MAIN_FOLDER = ORIGINAL_PROJECT_ROOT_DIR / "temp2convert" / "data_converted_dti"
OUTPUT_FOLDER = MAIN_FOLDER / "_manifest"

MANIFEST_FILE = OUTPUT_FOLDER / "dti_manifest.tsv"
ISSUES_FILE = OUTPUT_FOLDER / "dti_validation_issues.tsv"

# Filename identification rules.
DTI_REQUIRED_SUBSTRINGS = ("dti_2shell",)
PA_REQUIRED_SUBSTRINGS = ("b0correct", "pa")

# b-values at or below this threshold are treated as b0 volumes.
B0_THRESHOLD = 50

# Optional checksum calculation.
# This is disabled because hashing large NIfTI files can considerably increase
# runtime. Set to True when duplicate-content checking is needed.
CALCULATE_CHECKSUMS = False


# %% [markdown]
# ## Helper functions


# %%
def relative_path(path: Path | None, root: Path) -> str:
    """Return a path relative to the data root."""
    if path is None:
        return ""
    return path.relative_to(root).as_posix()


def has_all_substrings(path: Path, substrings: tuple[str, ...]) -> bool:
    """Check whether a filename contains all specified substrings."""
    filename = path.name.lower()
    return all(substring.lower() in filename for substring in substrings)


def is_nifti(path: Path) -> bool:
    """Check whether a path has a NIfTI extension."""
    name = path.name.lower()
    return name.endswith(".nii") or name.endswith(".nii.gz")


def strip_nifti_extension(path: Path) -> str:
    """Return a NIfTI filename without .nii or .nii.gz."""
    name = path.name

    if name.lower().endswith(".nii.gz"):
        return name[:-7]

    if name.lower().endswith(".nii"):
        return name[:-4]

    return path.stem


def find_sidecar(
    session_folder: Path,
    image_path: Path | None,
    extension: str,
) -> tuple[Path | None, list[Path]]:
    """Find a bval or bvec file corresponding to an image.

    The function first searches for an exact matching basename. If that is not
    found, it searches for files whose basename starts with or contains the
    image basename.
    """
    if image_path is None:
        return None, []

    image_basename = strip_nifti_extension(image_path)
    extension = extension.lstrip(".").lower()

    all_sidecars = [
        path
        for path in session_folder.iterdir()
        if path.is_file() and path.suffix.lower() == f".{extension}"
    ]

    exact_matches = [
        path for path in all_sidecars if path.stem.lower() == image_basename.lower()
    ]

    if len(exact_matches) == 1:
        return exact_matches[0], exact_matches

    if len(exact_matches) > 1:
        return None, exact_matches

    approximate_matches = [
        path
        for path in all_sidecars
        if (
            image_basename.lower() in path.stem.lower()
            or path.stem.lower() in image_basename.lower()
        )
    ]

    if len(approximate_matches) == 1:
        return approximate_matches[0], approximate_matches

    return None, approximate_matches


def load_bvals(path: Path) -> np.ndarray:
    """Load a bval file as a one-dimensional array."""
    values = np.loadtxt(path, dtype=float)
    return np.asarray(values).reshape(-1)


def load_bvecs(path: Path) -> tuple[np.ndarray, str]:
    """Load a bvec file and return it in 3 × N orientation.

    Returns
    -------
    bvecs
        Array with shape 3 × N.
    original_orientation
        Description of the file's original orientation.

    """
    bvecs = np.loadtxt(path, dtype=float)
    bvecs = np.asarray(bvecs)

    if bvecs.ndim == 1:
        if bvecs.size == 3:  # noqa: PLR2004
            return bvecs.reshape(3, 1), "single vector"
        raise ValueError(
            f"One-dimensional bvec file has {bvecs.size} values instead of 3."
        )

    if bvecs.shape[0] == 3:  # noqa: PLR2004
        return bvecs, "3 x N"

    if bvecs.shape[1] == 3:  # noqa: PLR2004
        return bvecs.T, "N x 3"

    raise ValueError(f"Unexpected bvec shape {bvecs.shape}; expected 3 x N or N x 3.")


def read_nifti_metadata(path: Path) -> dict:
    """Read NIfTI dimensions and voxel sizes without loading all voxel data."""
    image = nib.load(path)  # pyright: ignore[reportPrivateImportUsage]

    shape = tuple(
        int(value)
        for value in image.shape  # pyright: ignore[reportAttributeAccessIssue]
    )
    zooms = tuple(
        float(value)
        for value in image.header.get_zooms()  # pyright: ignore[reportAttributeAccessIssue]
    )

    if len(shape) == 3:  # noqa: PLR2004
        spatial_shape = shape
        n_volumes = 1
    elif len(shape) == 4:  # noqa: PLR2004
        spatial_shape = shape[:3]
        n_volumes = shape[3]
    else:
        spatial_shape = shape[:3]
        n_volumes = int(np.prod(shape[3:])) if len(shape) > 3 else 1  # noqa: PLR2004

    return {
        "shape": shape,
        "spatial_shape": spatial_shape,
        "n_volumes": n_volumes,
        "voxel_sizes": zooms[:3],
    }


def calculate_md5(path: Path, chunk_size: int = 1024 * 1024) -> str:
    """Calculate an MD5 checksum without loading the entire file at once."""
    checksum = hashlib.md5()  # noqa: S324

    with path.open("rb") as file:
        while chunk := file.read(chunk_size):
            checksum.update(chunk)

    return checksum.hexdigest()


def add_issue(
    issues: list[str],
    severity: str,
    message: str,
) -> None:
    """Append a formatted validation issue."""
    issues.append(f"{severity}: {message}")


# %% [markdown]
# ## Verify the data root

# %%
if not MAIN_FOLDER.exists():
    raise FileNotFoundError(f"MAIN_FOLDER does not exist: {MAIN_FOLDER}")

if not MAIN_FOLDER.is_dir():
    raise NotADirectoryError(f"MAIN_FOLDER is not a directory: {MAIN_FOLDER}")

OUTPUT_FOLDER.mkdir(parents=True, exist_ok=True)

print(f"Data root:   {MAIN_FOLDER}")
print(f"Output path: {OUTPUT_FOLDER}")


# %% [markdown]
# ## Find candidate session folders
#
# A folder is considered a candidate session if it directly contains at least
# one NIfTI, bval, or bvec file.

# %%
candidate_session_folders = []

for folder in MAIN_FOLDER.rglob("*"):
    if not folder.is_dir():
        continue

    files = [path for path in folder.iterdir() if path.is_file()]

    contains_relevant_file = any(
        is_nifti(path) or path.suffix.lower() in {".bval", ".bvec"} for path in files
    )

    if contains_relevant_file:
        candidate_session_folders.append(folder)

candidate_session_folders = sorted(candidate_session_folders)

print(f"Candidate session folders found: {len(candidate_session_folders)}")


# %% [markdown]
# ## Scan and validate all sessions

# %%
records = []

for session_folder in candidate_session_folders:
    relative_folder = session_folder.relative_to(MAIN_FOLDER)
    folder_parts = relative_folder.parts

    # With the expected subject/session structure, the final two folder levels
    # identify subject and session.
    subject_id = folder_parts[-2] if len(folder_parts) >= 2 else ""  # noqa: PLR2004
    session_id = folder_parts[-1] if len(folder_parts) >= 1 else ""

    issues: list[str] = []

    files = sorted(path for path in session_folder.iterdir() if path.is_file())
    nifti_files = [path for path in files if is_nifti(path)]

    dti_candidates = [
        path
        for path in nifti_files
        if has_all_substrings(path, DTI_REQUIRED_SUBSTRINGS)
    ]

    pa_candidates = [
        path for path in nifti_files if has_all_substrings(path, PA_REQUIRED_SUBSTRINGS)
    ]

    # Avoid accidentally assigning a PA image as the main DTI image if a
    # filename happens to contain both sets of terms.
    dti_candidates = [path for path in dti_candidates if path not in pa_candidates]

    dti_image = dti_candidates[0] if len(dti_candidates) == 1 else None
    pa_image = pa_candidates[0] if len(pa_candidates) == 1 else None

    # Validation 1: exactly one main DTI image.
    if len(dti_candidates) == 0:
        add_issue(issues, "ERROR", "No DTI_2shell NIfTI image found.")
    elif len(dti_candidates) > 1:
        names = ", ".join(path.name for path in dti_candidates)
        add_issue(
            issues,
            "ERROR",
            f"Multiple DTI_2shell NIfTI images found: {names}",
        )

    # Validation 3: exactly one reverse-encoding PA image.
    if len(pa_candidates) == 0:
        add_issue(
            issues,
            "ERROR",
            "No NIfTI image containing both b0correct and PA found.",
        )
    elif len(pa_candidates) > 1:
        names = ", ".join(path.name for path in pa_candidates)
        add_issue(
            issues,
            "ERROR",
            f"Multiple b0correct PA NIfTI images found: {names}",
        )

    # Validation 2: corresponding bval and bvec files.
    dti_bval, dti_bval_candidates = find_sidecar(session_folder, dti_image, "bval")
    dti_bvec, dti_bvec_candidates = find_sidecar(session_folder, dti_image, "bvec")
    pa_bval, pa_bval_candidates = find_sidecar(session_folder, pa_image, "bval")
    pa_bvec, pa_bvec_candidates = find_sidecar(session_folder, pa_image, "bvec")

    sidecar_checks = [
        ("DTI bval", dti_bval, dti_bval_candidates),
        ("DTI bvec", dti_bvec, dti_bvec_candidates),
        ("PA bval", pa_bval, pa_bval_candidates),
        ("PA bvec", pa_bvec, pa_bvec_candidates),
    ]

    for label, selected_file, candidates in sidecar_checks:
        if selected_file is not None:
            continue

        if len(candidates) == 0:
            add_issue(issues, "ERROR", f"No matching {label} file found.")
        else:
            names = ", ".join(path.name for path in candidates)
            add_issue(
                issues,
                "ERROR",
                f"Multiple possible {label} files found: {names}",
            )

    dti_metadata = {}
    pa_metadata = {}
    dti_bvals = None
    dti_bvecs = None
    pa_bvals = None
    pa_bvecs = None
    dti_bvec_orientation = ""
    pa_bvec_orientation = ""

    # Read DTI NIfTI metadata.
    if dti_image is not None:
        try:
            dti_metadata = read_nifti_metadata(dti_image)

            if len(dti_metadata["shape"]) != 4:  # noqa: PLR2004
                add_issue(
                    issues,
                    "ERROR",
                    f"DTI image is not 4D; shape is " f"{dti_metadata['shape']}.",
                )

        except Exception as error:
            add_issue(
                issues,
                "ERROR",
                f"Could not read DTI image: {error}",
            )

    # Read PA NIfTI metadata.
    if pa_image is not None:
        try:
            pa_metadata = read_nifti_metadata(pa_image)

            if len(pa_metadata["shape"]) not in {3, 4}:
                add_issue(
                    issues,
                    "ERROR",
                    f"PA image has unexpected shape " f"{pa_metadata['shape']}.",
                )

        except Exception as error:
            add_issue(
                issues,
                "ERROR",
                f"Could not read PA image: {error}",
            )

    # Read DTI b-values.
    if dti_bval is not None:
        try:
            dti_bvals = load_bvals(dti_bval)
        except Exception as error:
            add_issue(
                issues,
                "ERROR",
                f"Could not read DTI bval file: {error}",
            )

    # Read DTI b-vectors.
    if dti_bvec is not None:
        try:
            dti_bvecs, dti_bvec_orientation = load_bvecs(dti_bvec)
        except Exception as error:
            add_issue(
                issues,
                "ERROR",
                f"Could not read DTI bvec file: {error}",
            )

    # Read PA b-values.
    if pa_bval is not None:
        try:
            pa_bvals = load_bvals(pa_bval)
        except Exception as error:
            add_issue(
                issues,
                "ERROR",
                f"Could not read PA bval file: {error}",
            )

    # Read PA b-vectors.
    if pa_bvec is not None:
        try:
            pa_bvecs, pa_bvec_orientation = load_bvecs(pa_bvec)
        except Exception as error:
            add_issue(
                issues,
                "ERROR",
                f"Could not read PA bvec file: {error}",
            )

    # Validation 4: number of image volumes equals number of b-values.
    if dti_metadata and dti_bvals is not None:
        if dti_metadata["n_volumes"] != len(dti_bvals):
            add_issue(
                issues,
                "ERROR",
                "DTI volume count does not match bval count: "
                f"{dti_metadata['n_volumes']} volumes versus "
                f"{len(dti_bvals)} b-values.",
            )

    if pa_metadata and pa_bvals is not None:
        if pa_metadata["n_volumes"] != len(pa_bvals):
            add_issue(
                issues,
                "ERROR",
                "PA volume count does not match bval count: "
                f"{pa_metadata['n_volumes']} volumes versus "
                f"{len(pa_bvals)} b-values.",
            )

    # Validation 5: number of b-vectors equals number of image volumes and
    # b-values.
    if dti_bvecs is not None:
        n_dti_bvecs = dti_bvecs.shape[1]

        if dti_metadata and n_dti_bvecs != dti_metadata["n_volumes"]:
            add_issue(
                issues,
                "ERROR",
                "DTI volume count does not match bvec count: "
                f"{dti_metadata['n_volumes']} volumes versus "
                f"{n_dti_bvecs} vectors.",
            )

        if dti_bvals is not None and n_dti_bvecs != len(dti_bvals):
            add_issue(
                issues,
                "ERROR",
                "DTI bval count does not match bvec count: "
                f"{len(dti_bvals)} b-values versus "
                f"{n_dti_bvecs} vectors.",
            )

    if pa_bvecs is not None:
        n_pa_bvecs = pa_bvecs.shape[1]

        if pa_metadata and n_pa_bvecs != pa_metadata["n_volumes"]:
            add_issue(
                issues,
                "ERROR",
                "PA volume count does not match bvec count: "
                f"{pa_metadata['n_volumes']} volumes versus "
                f"{n_pa_bvecs} vectors.",
            )

        if pa_bvals is not None and n_pa_bvecs != len(pa_bvals):
            add_issue(
                issues,
                "ERROR",
                "PA bval count does not match bvec count: "
                f"{len(pa_bvals)} b-values versus "
                f"{n_pa_bvecs} vectors.",
            )

    # Validation 6: compatible spatial dimensions and voxel sizes.
    if dti_metadata and pa_metadata:
        if dti_metadata["spatial_shape"] != pa_metadata["spatial_shape"]:
            add_issue(
                issues,
                "ERROR",
                "DTI and PA spatial shapes differ: "
                f"{dti_metadata['spatial_shape']} versus "
                f"{pa_metadata['spatial_shape']}.",
            )

        if not np.allclose(
            dti_metadata["voxel_sizes"],
            pa_metadata["voxel_sizes"],
            rtol=1e-4,
            atol=1e-4,
        ):
            add_issue(
                issues,
                "WARNING",
                "DTI and PA voxel sizes differ: "
                f"{dti_metadata['voxel_sizes']} versus "
                f"{pa_metadata['voxel_sizes']}.",
            )

    # Validation 7: PA acquisition should contain only b0 volumes.
    if pa_bvals is not None:
        non_b0_values = pa_bvals[pa_bvals > B0_THRESHOLD]

        if len(non_b0_values) > 0:
            add_issue(
                issues,
                "WARNING",
                "PA acquisition contains b-values above the b0 threshold "
                f"of {B0_THRESHOLD}: "
                f"{np.unique(non_b0_values).tolist()}",
            )

    # Additional simple plausibility checks.
    if dti_bvals is not None:
        if not np.any(dti_bvals <= B0_THRESHOLD):
            add_issue(
                issues,
                "WARNING",
                "DTI acquisition contains no detected b0 volume.",
            )

        if not np.any(dti_bvals > B0_THRESHOLD):
            add_issue(
                issues,
                "ERROR",
                "DTI acquisition contains no diffusion-weighted volume.",
            )

    if dti_bvecs is not None and not np.all(np.isfinite(dti_bvecs)):
        add_issue(
            issues,
            "ERROR",
            "DTI bvec file contains non-finite values.",
        )

    if pa_bvecs is not None and not np.all(np.isfinite(pa_bvecs)):
        add_issue(
            issues,
            "ERROR",
            "PA bvec file contains non-finite values.",
        )

    # Optional validation 8: checksums for detecting identical file contents.
    dti_md5 = ""
    pa_md5 = ""

    if CALCULATE_CHECKSUMS:
        if dti_image is not None:
            dti_md5 = calculate_md5(dti_image)

        if pa_image is not None:
            pa_md5 = calculate_md5(pa_image)

        if dti_md5 and pa_md5 and dti_md5 == pa_md5:
            add_issue(
                issues,
                "ERROR",
                "DTI and PA NIfTI files have identical checksums.",
            )

    has_error = any(issue.startswith("ERROR:") for issue in issues)
    has_warning = any(issue.startswith("WARNING:") for issue in issues)

    if has_error:
        status = "error"
    elif has_warning:
        status = "warning"
    else:
        status = "complete"

    records.append(
        {
            "subject_id": subject_id,
            "session_id": session_id,
            "session_folder": relative_path(session_folder, MAIN_FOLDER),
            "dti_image": relative_path(dti_image, MAIN_FOLDER),
            "dti_bval": relative_path(dti_bval, MAIN_FOLDER),
            "dti_bvec": relative_path(dti_bvec, MAIN_FOLDER),
            "pa_image": relative_path(pa_image, MAIN_FOLDER),
            "pa_bval": relative_path(pa_bval, MAIN_FOLDER),
            "pa_bvec": relative_path(pa_bvec, MAIN_FOLDER),
            "n_dti_image_candidates": len(dti_candidates),
            "n_pa_image_candidates": len(pa_candidates),
            "dti_shape": str(dti_metadata.get("shape", "")),
            "pa_shape": str(pa_metadata.get("shape", "")),
            "dti_voxel_sizes": str(dti_metadata.get("voxel_sizes", "")),
            "pa_voxel_sizes": str(pa_metadata.get("voxel_sizes", "")),
            "dti_n_volumes": dti_metadata.get("n_volumes", np.nan),
            "pa_n_volumes": pa_metadata.get("n_volumes", np.nan),
            "dti_n_bvals": (len(dti_bvals) if dti_bvals is not None else np.nan),
            "dti_n_bvecs": (dti_bvecs.shape[1] if dti_bvecs is not None else np.nan),
            "pa_n_bvals": (len(pa_bvals) if pa_bvals is not None else np.nan),
            "pa_n_bvecs": (pa_bvecs.shape[1] if pa_bvecs is not None else np.nan),
            "dti_bvec_orientation": dti_bvec_orientation,
            "pa_bvec_orientation": pa_bvec_orientation,
            "dti_unique_bvals": (
                ",".join(
                    str(value) for value in np.unique(np.rint(dti_bvals).astype(int))
                )
                if dti_bvals is not None
                else ""
            ),
            "pa_unique_bvals": (
                ",".join(
                    str(value) for value in np.unique(np.rint(pa_bvals).astype(int))
                )
                if pa_bvals is not None
                else ""
            ),
            "dti_md5": dti_md5,
            "pa_md5": pa_md5,
            "status": status,
            "issues": " | ".join(issues),
        }
    )


# %% [markdown]
# ## Create and save the manifest

# %%
manifest = pd.DataFrame(records)

if manifest.empty:
    print("No candidate sessions were found.")
else:
    manifest = manifest.sort_values(
        ["subject_id", "session_id", "session_folder"],
        na_position="last",
    ).reset_index(drop=True)

    manifest.to_csv(
        MANIFEST_FILE,
        sep="\t",
        index=False,
    )

    issues_table = manifest.loc[manifest["status"] != "complete"].copy()

    issues_table.to_csv(
        ISSUES_FILE,
        sep="\t",
        index=False,
    )

    print(f"Manifest written to: {MANIFEST_FILE}")
    print(f"Issue report written to: {ISSUES_FILE}")


# %% [markdown]
# ## Show a validation summary

# %%
if not manifest.empty:
    status_counts = (
        manifest["status"]
        .value_counts()
        .reindex(["complete", "warning", "error"], fill_value=0)
    )

    print("\nValidation summary")
    print("------------------")
    print(f"Sessions scanned: {len(manifest)}")
    print(f"Complete:         {status_counts['complete']}")
    print(f"Warnings:         {status_counts['warning']}")
    print(f"Errors:           {status_counts['error']}")

    display_columns = [
        "subject_id",
        "session_id",
        "status",
        "dti_n_volumes",
        "dti_n_bvals",
        "dti_n_bvecs",
        "pa_n_volumes",
        "pa_n_bvals",
        "pa_n_bvecs",
        "issues",
    ]

    print(manifest[display_columns].to_string(index=False))


# %% [markdown]
# ## Show only problematic sessions

# %%
if not manifest.empty:
    problematic_sessions = manifest.loc[
        manifest["status"] != "complete",
        [
            "subject_id",
            "session_id",
            "session_folder",
            "status",
            "issues",
        ],
    ]

    print(problematic_sessions.to_string(index=False))

# %%
