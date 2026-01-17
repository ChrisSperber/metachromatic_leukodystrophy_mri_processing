"""Visualisation helpers to format segmentation labels for better nifti viewing experience."""

from __future__ import annotations

from pathlib import Path

import nibabel as nib
import numpy as np
import pandas as pd

LABEL_TABLE_PATH = (
    Path(__file__).parents[2] / "scripts" / "g_fetch_freesurfer_labelmap.csv"
)


def relabel_nifti(nifti_path: Path, suffix: str = "_relabeled") -> None:
    """Relabel an integer NIfTI label map to consecutive labels.

    The background label 0 is preserved. All other unique labels are
    reassigned to consecutive integers starting at 1, in ascending
    order of the original labels.

    Example:
        [0, 1, 2, 1000, 1001] -> [0, 1, 2, 3, 4]

    The relabeled image is written to the same directory as the input
    with `suffix` appended to the filename stem.

    Parameters
    ----------
    nifti_path : Path
        Path to the input NIfTI file.
    suffix : str, optional
        Suffix to append to the output filename stem.

    """
    img = nib.load(nifti_path)  # pyright: ignore[reportPrivateImportUsage]
    data = img.get_fdata()  # pyright: ignore[reportAttributeAccessIssue]

    # --- verification: integer label map ---
    if not np.all(np.isfinite(data)):
        raise ValueError("Input NIfTI contains non-finite values.")

    if not np.all(np.equal(data, np.round(data))):
        raise ValueError("Input NIfTI is not an integer label map.")

    data = data.astype(np.int64)

    # --- determine unique labels ---
    labels = np.unique(data)

    if labels[0] != 0:
        raise ValueError("Expected background label 0, but 0 is missing.")

    # exclude background
    foreground_labels = labels[labels != 0]

    # --- build relabeling map ---
    relabel_map = {0: 0}
    for new_label, old_label in enumerate(foreground_labels, start=1):
        relabel_map[old_label] = new_label

    # --- apply relabeling ---
    relabeled = np.zeros_like(data)
    for old_label, new_label in relabel_map.items():
        relabeled[data == old_label] = new_label

    # --- write output ---
    out_path = _out_path_with_suffix(nifti_path=nifti_path, suffix=suffix)

    out_img = nib.Nifti1Image(  # pyright: ignore[reportPrivateImportUsage]
        relabeled.astype(np.int32),
        affine=img.affine,  # pyright: ignore[reportAttributeAccessIssue]
        header=img.header,
    )
    out_img.set_data_dtype(np.int32)

    nib.save(out_img, out_path)  # pyright: ignore[reportPrivateImportUsage]


def _out_path_with_suffix(nifti_path: Path, suffix: str) -> Path:
    nifti_path = Path(nifti_path)
    if nifti_path.name.endswith(".nii.gz"):
        out_name = nifti_path.name.replace(".nii.gz", f"{suffix}.nii.gz")
    else:
        out_name = nifti_path.stem + suffix + nifti_path.suffix
    return nifti_path.with_name(out_name)


def _assert_integer_labelmap(data: np.ndarray) -> np.ndarray:
    if not np.all(np.isfinite(data)):
        raise ValueError("Input NIfTI contains non-finite values.")
    if not np.all(np.equal(data, np.round(data))):
        raise ValueError("Input NIfTI is not an integer label map.")
    return data.astype(np.int64)


def _load_id_to_structure_map(
    table_path: Path,
    sep: str = ";",
    id_col: str = "id",
    structure_col: str = "Structure",
) -> dict[int, str]:
    df = pd.read_csv(table_path, sep=sep, dtype={id_col: "int64"})
    if id_col not in df.columns or structure_col not in df.columns:
        raise ValueError(
            f"Mapping table must contain columns {id_col!r} and {structure_col!r}. "
            f"Found: {list(df.columns)}"
        )

    # Drop rows without a usable meta label (empty / NaN)
    structures = df[structure_col].astype("string")
    keep = structures.notna() & (structures.str.strip() != "")
    df = df.loc[keep, [id_col, structure_col]].copy()
    df[structure_col] = df[structure_col].astype(str).str.strip()

    # Build mapping id -> Structure
    id_to_structure: dict[int, str] = dict(
        zip(df[id_col].astype(int), df[structure_col], strict=False)
    )

    # Ensure 0 is either unmapped or maps to something sensible
    id_to_structure.pop(0, None)

    return id_to_structure


def _build_structure_to_new_id(
    id_to_structure: dict[int, str],
) -> tuple[dict[str, int], dict[int, int]]:
    unique_structures = sorted(set(id_to_structure.values()))
    structure_to_new_id = {s: i for i, s in enumerate(unique_structures, start=1)}
    old_id_to_new_id = {
        old_id: structure_to_new_id[s] for old_id, s in id_to_structure.items()
    }
    return structure_to_new_id, old_id_to_new_id


def relabel_nifti_to_meta_structure(
    nifti_path: Path,
    suffix: str = "_meta",
    table_path: Path = LABEL_TABLE_PATH,
) -> None:
    """Map region IDs in a label NIfTI to meta 'Structure' labels defined in a lookup table.

    - Preserves background label 0.
    - For each voxel with value `id`, assigns the integer corresponding to the meta label
      in the table's 'Structure' column.
    - Each unique meta label gets a consecutive integer (1..K).

    Notes
    -----
    - If the NIfTI contains an ID > 0 that is not present in the table (or has empty Structure),
      the function raises an error (to avoid silently mislabeling).
    - Output is written next to the input with `suffix` added to the filename stem.

    Parameters
    ----------
    nifti_path : Path
        Input label map (.nii or .nii.gz).
    suffix : str
        Suffix for the output filename.
    table_path : Path
        Path to the mapping table with at least columns: 'id' and 'Structure'.

    """
    nifti_path = Path(nifti_path)
    table_path = Path(table_path)

    if not table_path.exists():
        raise FileNotFoundError(f"Label table not found: {table_path}")

    img = nib.load(nifti_path)  # pyright: ignore[reportPrivateImportUsage]
    data = _assert_integer_labelmap(
        img.get_fdata()  # pyright: ignore[reportAttributeAccessIssue]
    )

    id_to_structure = _load_id_to_structure_map(table_path)
    structure_to_new_id, old_id_to_new_id = _build_structure_to_new_id(id_to_structure)

    # Verify all non-zero labels in the image are known and mappable
    present = np.unique(data)
    present_fg = present[present != 0]

    present_set = set(map(int, present_fg.tolist()))
    known_set = set(old_id_to_new_id.keys())
    unknown = sorted(present_set - known_set)
    if unknown:
        raise ValueError(
            "Found label IDs in the NIfTI that are not mapped to a meta Structure in the table: "
            f"{unknown[:20]}{' ...' if len(unknown) > 20 else ''}"  # noqa: PLR2004
        )

    # Apply mapping
    max_id = int(present_fg.max()) if present_fg.size else 0
    lut = np.zeros(max_id + 1, dtype=np.int32)  # 0 stays 0
    for old_id, new_id in old_id_to_new_id.items():
        if old_id <= max_id:
            lut[old_id] = np.int32(new_id)

    relabeled = np.zeros_like(data, dtype=np.int32)
    if max_id > 0:
        mask = (data > 0) & (data <= max_id)
        relabeled[mask] = lut[data[mask]]

    out_path = _out_path_with_suffix(nifti_path, suffix)
    out_img = nib.Nifti1Image(relabeled, affine=img.affine, header=img.header)  # type: ignore
    out_img.set_data_dtype(np.int32)
    nib.save(out_img, out_path)  # pyright: ignore[reportPrivateImportUsage]
