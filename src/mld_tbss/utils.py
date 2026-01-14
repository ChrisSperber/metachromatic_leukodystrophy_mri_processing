"""Utility functions and constants for MLD MRI processing."""

from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import ndimage as ndi


@dataclass(frozen=True)
class Cols:
    """Data column names."""

    FILENAME: str = "Filename"
    AGE: str = "Age"
    SEX: str = "Sex"
    GMFC: str = "GMFC"
    PATHOLOGY_TYPE: str = "Pathology_Type"
    THERAPY: str = "Therapy"
    MRI_SCORE: str = "MRI_Score"
    SUBJECT_ID: str = "Subject_ID"
    DATE_TAG: str = "Date_Tag"
    IMAGE_MODALITY: str = "Image_Modality"
    DTI_METHOD: str = "DTI_Method"
    SUBJECT_TYPE: str = "Subject_Type"  # Column name for patient/control tag


@dataclass(frozen=True)
class DWIPathCols:
    """Data column names for DWI Paths."""

    DWI_PATH: str = "dwiPath"
    BVAL_PATH: str = "bvalPath"
    BVEC_PATH: str = "bvecPath"
    BVALS: str = "bvals"


def get_unique_row(df: pd.DataFrame, column: str, substring: str) -> pd.Series:
    """Get values of a row identified by an uid.

    Args:
        df: Dataframe
        column: Colname
        substring: String to search

    Raises:
        ValueError: substring cannot be found
        ValueError: substring appears multiple times

    Returns:
        Series: df row as Series

    """
    mask = df[column].str.contains(substring, regex=False)
    matches = df[mask]

    if len(matches) == 0:
        raise ValueError(f"No row contains '{substring}' in column '{column}'")
    elif len(matches) > 1:
        raise ValueError(
            f"Multiple rows contain '{substring}' in column '{column}': {matches.index.tolist()}"
        )
    else:
        return matches.squeeze()  # type: ignore # converts 1-row DataFrame → Series


def voronoi_subparcellate(
    to_subdivide: np.ndarray,
    seed_labels: np.ndarray,
    spacing=None,
    *,
    dtype_out=None,
) -> np.ndarray:
    """Assign each non-zero voxel in `to_subdivide` the closest label in `seed_labels`.

    Parameters
    ----------
    to_subdivide : ndarray
        Array to be subdivided (e.g., WM mask). Voxels != 0 are assigned.
    seed_labels : ndarray
        Array with region labels (>=2 unique non-zero labels required).
        Zeros are background and ignored as seeds.
    spacing : None or sequence of floats
        Physical voxel size per axis (z, y, x), passed to EDT `sampling`.
        Use this to respect anisotropic voxels. 'None' assumes isometric images.
    dtype_out : numpy dtype or None
        Output dtype. Defaults to `seed_labels.dtype`.

    Returns
    -------
    subsegmented_arr : ndarray
        Same shape as inputs. Voxels where `to_subdivide == 0` are 0.
        Other voxels carry the nearest non-zero label from `seed_labels`.

    Raises
    ------
    ValueError
        If shapes mismatch, inputs are empty, or not enough seed labels.

    """
    if to_subdivide.shape != seed_labels.shape:
        raise ValueError("Input arrays must have the same shape.")
    if to_subdivide.ndim < 2:  # noqa: PLR2004
        raise ValueError("Expect at least 2D arrays.")
    if not np.any(to_subdivide != 0):
        raise ValueError("`to_subdivide` contains no non-zero voxels to assign.")

    # Build a boolean where zeros at seed locations (so EDT returns nearest seed)
    #   EDT computes distance to the nearest zero in `edt_input`.
    #   Therefore we pass 0 at seed positions and 1 elsewhere.
    edt_input = (seed_labels == 0).astype(np.uint8)  # 1 outside seeds, 0 at seeds

    # Get indices of nearest seed voxel for every position
    nearest_idx = ndi.distance_transform_edt(
        edt_input,
        sampling=spacing,
        return_distances=False,
        return_indices=True,
    )
    # nearest_idx is shape (ndim, *shape); index into seed_labels
    nearest_labels = seed_labels[
        tuple(nearest_idx)  # pyright: ignore[reportArgumentType]
    ]

    subsegmented_arr = np.zeros_like(
        seed_labels if dtype_out is None else seed_labels.astype(dtype_out),
        dtype=dtype_out or seed_labels.dtype,
    )
    mask = to_subdivide != 0
    subsegmented_arr[mask] = nearest_labels[mask]

    return subsegmented_arr


def combine_hemispheres(
    left: np.ndarray,
    right: np.ndarray,
) -> np.ndarray:
    """Combine two labeled arrays where 0 = background."""
    if left.shape != right.shape:
        raise ValueError("Shapes must match.")
    if not np.issubdtype(left.dtype, np.integer) or not np.issubdtype(
        right.dtype, np.integer
    ):
        raise TypeError("Inputs should be integer label images.")

    lmask = left != 0
    rmask = right != 0
    overlap = lmask & rmask
    n_overlap = int(overlap.sum())

    if n_overlap:
        raise ValueError(f"Left/right overlap at {n_overlap} voxels.")

    combined = np.where(lmask, left, right)
    return combined


def find_unique_path(
    paths: list[Path], substring1: str, substring2: str | None = None
) -> Path:
    """Find a unique filepath in a list containing unique strings.

    Args:
        paths: List of path objects.
        substring1: Substring to match
        substring2: Second substring to match (optional)

    Raises:
        ValueError: More than 1 matching file exists.

    Returns:
        Unique file path.

    """
    if substring2:
        matches = [p for p in paths if substring1 in str(p) and substring2 in str(p)]
    else:
        matches = [p for p in paths if substring1 in str(p)]

    if len(matches) == 1:
        return matches[0]
    elif len(matches) > 1:
        if substring2:
            raise ValueError(
                f"Multiple matches found for {substring1} and {substring2}"
            )
        else:
            raise ValueError(f"Multiple matches found for {substring1}")
    else:  # noqa: PLR5501
        if substring2:
            raise ValueError(f"No matches found for {substring1} and {substring2}")
        else:
            raise ValueError(f"No matches found for {substring1}")
