"""Collect paths to imaging files in the reorganised MLD data master folder.

The Excel master table defines which subject/session combinations are expected.
Previously excluded sessions are omitted. Source filenames may be heterogeneous.

Output:
- imaging_file_manifest.csv: one row per included subject/session, with relative paths
- imaging_file_manifest_issues.csv: missing or ambiguous files/directories

The original Excel file and imaging files are not modified.
"""

# %%
import re
from datetime import date, datetime
from pathlib import Path

import pandas as pd

from mld_tbss.config import NOT_APPLICABLE, ORIGINAL_PROJECT_ROOT_DIR

DATA_MASTER_DIR = ORIGINAL_PROJECT_ROOT_DIR / "mld_data_master_2026"
DATA_MASTER_XLS = DATA_MASTER_DIR / "data_master_2026.xlsx"
DIFFUSION_DERIVATIVES_DIR = DATA_MASTER_DIR / "derivatives" / "diffusion"
MTR_DERIVATIVES_DIR = DATA_MASTER_DIR / "derivatives" / "mtr"

OUTPUT_CSV = DATA_MASTER_DIR / "imaging_file_manifest.csv"
ISSUES_CSV = DATA_MASTER_DIR / "imaging_file_manifest_issues.csv"

# Data master columns
SUBJECT_ID = "SubjectID"
SESSION_ID = "SessionID"
EXCLUDED = "Excluded"

# Optional non-identifying clinical columns to copy into the manifest.
# Example: ADDITIONAL_MASTER_COLUMNS = ["Age", "Sex"]
ADDITIONAL_MASTER_COLUMNS = []

BIDS_ANAT_DIRNAME = "anat"
BIDS_DWI_DIRNAME = "dwi"
BIDS_MTR_DIRNAME = "mtr"

UNIQUE_SUBSTRINGS_T1 = [
    "UNI_Images",
    "MP2.MP2",
    "mprage_sag",
    "MLD105_T1",
    "MLD119_skyra_t1_mp2rage_sag",
    "MLD120_t1_mp2rage_sag_",
]
UNIQUE_SUBSTRINGS_QUANT_T1 = ["T1_Images", "MP2.T1"]
UNIQUE_SUBSTRINGS_FLAIR = ["Flair"]
UNIQUE_SUBSTRINGS_FA = ["FA"]
UNIQUE_SUBSTRINGS_MD = ["MD"]
UNIQUE_SUBSTRINGS_MASK_MIF = ["mask"]

PATH_T1 = "PathT1"
PATH_QUANT_T1 = "PathQT1"
PATH_FLAIR = "PathFLAIR"
PATH_FA = "PathFA"
PATH_MD = "PathMD"
PATH_DWI = "PathDWI"
PATH_BVAL = "PathBVAL"
PATH_BVEC = "PathBVEC"
PATH_DWI_MIF = "PathDWIMIF"
PATH_MASK_MIF = "PathMaskMIF"
PATH_MTR = "PathMTR"

NIFTI_EXT = [".nii", ".nii.gz"]
MIF_EXT = ".mif"
BVAL_EXT = ".bval"
BVEC_EXT = ".bvec"

PATH_COLUMNS = [
    PATH_T1,
    PATH_QUANT_T1,
    PATH_FLAIR,
    PATH_FA,
    PATH_MD,
    PATH_DWI,
    PATH_BVAL,
    PATH_BVEC,
    PATH_DWI_MIF,
    PATH_MASK_MIF,
    PATH_MTR,
]

# %%
# Helper functions for identification and reporting


def normalise_id(value, prefix):
    """Return an ID without its BIDS prefix, retaining leading zeros."""
    if pd.isna(value):
        raise ValueError(f"Missing {prefix} identifier")
    if isinstance(value, (date, datetime, pd.Timestamp)):
        value = value.strftime("%Y%m%d")
    elif isinstance(value, float) and value.is_integer():
        value = str(int(value))
    else:
        value = str(value).strip()

    if value.lower().startswith(f"{prefix}-"):
        value = value[len(prefix) + 1 :]
    if not re.fullmatch(r"[A-Za-z0-9]+", value):
        raise ValueError(f"Invalid {prefix} identifier: {value!r}")
    return value


def is_excluded(value):
    """Recognise common Excel exclusion markers without treating 'No' as True."""
    if pd.isna(value):
        return False
    if isinstance(value, str):
        marker = value.strip().casefold()
        if marker in {"", "0", "false", "no", "nein", "n"}:
            return False
        if marker in {"1", "true", "yes", "ja", "y", "x"}:
            return True
    elif value in (False, 0):
        return False
    elif value in (True, 1):
        return True
    raise ValueError(f"Unrecognised value in {EXCLUDED}: {value!r}")


def has_extension(path, extensions):  # noqa: D103
    if isinstance(extensions, str):
        extensions = [extensions]
    return any(path.name.casefold().endswith(ext.casefold()) for ext in extensions)


def contains_any(path, substrings):  # noqa: D103
    name = path.name.casefold()
    return any(text.casefold() in name for text in substrings)


def matches_metric(path, substrings):
    """Match FA/MD as filename tokens, not inside unrelated words."""
    return any(
        re.search(rf"(?<![A-Za-z0-9]){re.escape(text)}(?![A-Za-z0-9])", path.name, re.I)
        for text in substrings
    )


def relative_path(path):  # noqa: D103
    return path.relative_to(DATA_MASTER_DIR).as_posix()


def get_unique_path(  # noqa: PLR0913, PLR0917
    directory, column, match_fn, subject, session, issues
):
    """Return the unique matching path or record the issue and return N/A."""
    if not directory.is_dir():
        issues.append(
            {
                SUBJECT_ID: subject,
                SESSION_ID: session,
                "Column": column,
                "Problem": "missing_directory",
                "Detail": relative_path(directory),
            }
        )
        return NOT_APPLICABLE

    matches = sorted(
        [p for p in directory.iterdir() if p.is_file() and match_fn(p)],
        key=lambda p: p.name.casefold(),
    )
    if len(matches) == 1:
        return relative_path(matches[0])

    issues.append(
        {
            SUBJECT_ID: subject,
            SESSION_ID: session,
            "Column": column,
            "Problem": "missing_file" if not matches else "ambiguous_multiple_matches",
            "Detail": (
                relative_path(directory)
                if not matches
                else " | ".join(relative_path(p) for p in matches)
            ),
        }
    )
    return NOT_APPLICABLE


# %%
# Read master table, validate columns, remove excluded sessions
master_df = pd.read_excel(
    DATA_MASTER_XLS,
    dtype={SUBJECT_ID: str, SESSION_ID: str},
)

required_cols = [SUBJECT_ID, SESSION_ID, EXCLUDED, *ADDITIONAL_MASTER_COLUMNS]
missing_cols = [col for col in required_cols if col not in master_df.columns]
if missing_cols:
    raise KeyError(f"Missing columns in master table: {missing_cols}")

excluded_mask = master_df[EXCLUDED].map(is_excluded)
print(f"Excluding {excluded_mask.sum()} of {len(master_df)} master-table rows.")
master_df = master_df.loc[~excluded_mask].copy()

# Normalise IDs once so directory matching is independent of Excel cell formats.
master_df[SUBJECT_ID] = master_df[SUBJECT_ID].map(lambda x: normalise_id(x, "sub"))
master_df[SESSION_ID] = master_df[SESSION_ID].map(lambda x: normalise_id(x, "ses"))

if master_df.duplicated([SUBJECT_ID, SESSION_ID]).any():
    duplicates = master_df.loc[
        master_df.duplicated([SUBJECT_ID, SESSION_ID], keep=False),
        [SUBJECT_ID, SESSION_ID],
    ]
    raise ValueError(f"Duplicate subject/session rows in master table:\n{duplicates}")

# %%
# Collect paths for each included subject/session
records = []
issues = []

for _, master_row in master_df.iterrows():
    subject = master_row[SUBJECT_ID]
    session = master_row[SESSION_ID]
    bids_dir = Path(f"sub-{subject}") / f"ses-{session}"

    anat_dir = DATA_MASTER_DIR / bids_dir / BIDS_ANAT_DIRNAME
    raw_dwi_dir = DATA_MASTER_DIR / bids_dir / BIDS_DWI_DIRNAME
    deriv_dwi_dir = DIFFUSION_DERIVATIVES_DIR / bids_dir / BIDS_DWI_DIRNAME
    deriv_mtr_dir = MTR_DERIVATIVES_DIR / bids_dir / BIDS_MTR_DIRNAME

    record = {SUBJECT_ID: subject, SESSION_ID: session}
    for col in ADDITIONAL_MASTER_COLUMNS:
        record[col] = master_row[col] if pd.notna(master_row[col]) else NOT_APPLICABLE

    file_specs = [
        (
            PATH_T1,
            anat_dir,
            lambda p: has_extension(p, NIFTI_EXT)
            and contains_any(p, UNIQUE_SUBSTRINGS_T1),
        ),
        (
            PATH_QUANT_T1,
            anat_dir,
            lambda p: has_extension(p, NIFTI_EXT)
            and contains_any(p, UNIQUE_SUBSTRINGS_QUANT_T1),
        ),
        (
            PATH_FLAIR,
            anat_dir,
            lambda p: has_extension(p, NIFTI_EXT)
            and contains_any(p, UNIQUE_SUBSTRINGS_FLAIR),
        ),
        (
            PATH_FA,
            deriv_dwi_dir,
            lambda p: has_extension(p, NIFTI_EXT)
            and matches_metric(p, UNIQUE_SUBSTRINGS_FA),
        ),
        (
            PATH_MD,
            deriv_dwi_dir,
            lambda p: has_extension(p, NIFTI_EXT)
            and matches_metric(p, UNIQUE_SUBSTRINGS_MD),
        ),
        (PATH_DWI, raw_dwi_dir, lambda p: has_extension(p, NIFTI_EXT)),
        (PATH_BVAL, raw_dwi_dir, lambda p: has_extension(p, BVAL_EXT)),
        (PATH_BVEC, raw_dwi_dir, lambda p: has_extension(p, BVEC_EXT)),
        (
            PATH_DWI_MIF,
            deriv_dwi_dir,
            lambda p: has_extension(p, MIF_EXT)
            and not contains_any(p, UNIQUE_SUBSTRINGS_MASK_MIF),
        ),
        (
            PATH_MASK_MIF,
            deriv_dwi_dir,
            lambda p: has_extension(p, MIF_EXT)
            and contains_any(p, UNIQUE_SUBSTRINGS_MASK_MIF),
        ),
        (PATH_MTR, deriv_mtr_dir, lambda p: has_extension(p, NIFTI_EXT)),
    ]

    for column, directory, match_fn in file_specs:
        record[column] = get_unique_path(
            directory, column, match_fn, subject, session, issues
        )

    records.append(record)

# %%
# Build output tables and review matching results
manifest_df = pd.DataFrame(
    records,
    columns=[SUBJECT_ID, SESSION_ID, *ADDITIONAL_MASTER_COLUMNS, *PATH_COLUMNS],
)
issues_df = pd.DataFrame(
    issues,
    columns=[SUBJECT_ID, SESSION_ID, "Column", "Problem", "Detail"],
)

print(f"Included sessions: {len(manifest_df)}")
for column in PATH_COLUMNS:
    n_found = manifest_df[column].ne(NOT_APPLICABLE).sum()
    print(f"{column}: {n_found}/{len(manifest_df)} found")
print(f"Reported issues: {len(issues_df)}")

# %%
# Save manifests (no changes to original XLSX or image files)
manifest_df.to_csv(OUTPUT_CSV, index=False, encoding="utf-8")
issues_df.to_csv(ISSUES_CSV, index=False, encoding="utf-8")

print(f"Saved: {OUTPUT_CSV}")
print(f"Saved: {ISSUES_CSV}")

# %%
