"""Compute pseudo magnetic transfer ratio images from aligned SSFP images.

Outputs:
    - MTR images are created under MTR_OUTPUT_DIR.

"""

# %%
from pathlib import Path

import nibabel as nib
import numpy as np
from nibabel.nifti1 import Nifti1Image

from mld_tbss.config import MTR_OUTPUT_DIR, TEMPORARY_DATA_DIR

SSFP_DIR = TEMPORARY_DATA_DIR / "SSFP_images_moved_to_T1"

# %%
# search local SSFP images
ssfp_image_name_list = [str(p.name) for p in SSFP_DIR.rglob("*") if p.is_file()]

# verify completeness of matching 200/1500 images
for filename in ssfp_image_name_list:
    if "SSFP_200" in filename:
        matching_image_name = filename.replace("SSFP_200", "SSFP_1500")
    elif "SSFP_1500" in filename:
        matching_image_name = filename.replace("SSFP_1500", "SSFP_200")
    else:
        raise ValueError(f"No SSFP tag in {filename}")
    matching_image_path = SSFP_DIR / matching_image_name
    if not matching_image_path.is_file():
        raise FileNotFoundError(f"File {matching_image_name} does not exist")

print(
    f"{len(ssfp_image_name_list)} files were found with complete matches for 200us and 1500u images"
)

ssfp_200_images = [name for name in ssfp_image_name_list if "SSFP_200" in name]

# %%
# define function for computation of MTR


def compute_pseudo_mtr(  # noqa: PLR0913
    ssfp_200_path: Path | str,
    ssfp_1500_path: Path | str,
    out_path: Path | str,
    *,
    affine_rtol: float = 1e-5,
    affine_atol: float = 1e-6,
    eps: float = 1e-8,
) -> None:
    """Compute pseudo-MTR = (SSFP200 - SSFP1500) / SSFP200 on a voxelwise basis and write NIfTI.

    Assumes both images are already in the same space.

    Checks performed:
      - same voxel grid shape (x, y, z)
      - affine matrices are identical

    Args:
        ssfp_200_path: Path to SSFP 200 µs image (M0-like image in pseudo-MTR).
        ssfp_1500_path: Path to SSFP 1500 µs image (Msat-like image in pseudo-MTR).
        out_path: Output path. Must end with ".nii" or ".nii.gz".
        affine_rtol: Tolerance for affine comparison.
        affine_atol: Tolerance for affine comparison.
        eps: Small value used to avoid division-by-zero.

    Raises:
        FileNotFoundError: if any input doesn't exist.
        ValueError: if alignment checks fail or output suffix is invalid.

    """
    ssfp_200_path = Path(ssfp_200_path)
    ssfp_1500_path = Path(ssfp_1500_path)
    out_path = Path(out_path)

    if not ssfp_200_path.is_file():
        raise FileNotFoundError(f"SSFP200 not found: {ssfp_200_path}")
    if not ssfp_1500_path.is_file():
        raise FileNotFoundError(f"SSFP1500 not found: {ssfp_1500_path}")

    if out_path.suffix not in {".nii", ".gz"}:
        raise ValueError(
            f"Output must be a NIfTI path ending with .nii or .nii.gz, got: {out_path}"
        )
    if out_path.suffix == ".gz" and not out_path.name.endswith(".nii.gz"):
        raise ValueError(f"Output ends with .gz but is not .nii.gz: {out_path}")

    img200 = nib.load(str(ssfp_200_path))  # pyright: ignore[reportPrivateImportUsage]
    img1500 = nib.load(str(ssfp_1500_path))  # pyright: ignore[reportPrivateImportUsage]

    # --- grid checks ---
    if img200.shape != img1500.shape:  # type: ignore
        raise ValueError(f"Shape mismatch: {img200.shape} vs {img1500.shape}")  # type: ignore

    # --- affine checks ---
    if not np.allclose(img200.affine, img1500.affine, rtol=affine_rtol, atol=affine_atol):  # type: ignore
        raise ValueError("Affine mismatch (images not on the same voxel grid).\n")

    # zooms is often the quickest proxy for same spacing; should match if on same grid
    if img200.header.get_zooms() != img1500.header.get_zooms():  # type: ignore
        raise ValueError(
            f"Zooms mismatch: {img200.header.get_zooms()} vs {img1500.header.get_zooms()}"  # type: ignore
        )

    # --- compute voxelwise pseudo-MTR ---
    data200 = np.asanyarray(img200.dataobj).astype(np.float32, copy=False)  # type: ignore
    data1500 = np.asanyarray(img1500.dataobj).astype(np.float32, copy=False)  # type: ignore

    # Avoid division by zero / near zero: mark as NaN (or change to 0 if you prefer).
    denom = data200
    mtr = np.empty_like(data200, dtype=np.float32)
    with np.errstate(divide="ignore", invalid="ignore"):
        mtr[:] = (data200 - data1500) / denom
        mtr[np.abs(denom) <= eps] = np.nan

    # --- write output ---
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # Keep geometry from SSFP200 (identical to SSFP1500 after checks)
    out_img = Nifti1Image(mtr, affine=img200.affine, header=img200.header.copy())  # type: ignore
    # Ensure datatype is float32 in header
    out_img.set_data_dtype(np.float32)
    nib.save(out_img, str(out_path))  # pyright: ignore[reportPrivateImportUsage]

    print(f"Saved MTR image {str(out_path)}")


# %%
# compute MTR images
for ssfp_200_img_name in ssfp_200_images:
    ssfp_200_img_path = SSFP_DIR / ssfp_200_img_name
    ssfp_1500_img_name = ssfp_200_img_name.replace("SSFP_200", "SSFP_1500")
    ssfp_1500_img_path = SSFP_DIR / ssfp_1500_img_name

    mtr_out_name = ssfp_200_img_name.replace("SSFP_200", "MTR")
    mtr_out_path = MTR_OUTPUT_DIR / mtr_out_name

    compute_pseudo_mtr(
        ssfp_200_path=ssfp_200_img_path,
        ssfp_1500_path=ssfp_1500_img_path,
        out_path=mtr_out_path,
    )

print("Done!")

# %%
