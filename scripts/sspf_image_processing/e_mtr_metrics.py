"""Derive region-wise MTR metrics based on the T1 segmentation.

Derives MTR imaging metrics based on the SynthSeg Segmentation, including
- median
- p10

Output:
    - A long CSVs storing all variables for all subjects and sessions
        - xxx_MTR.csv for FA values
    The output is stored in a dedicated folder OUTPUT_METRICS_DIR

"""

# %%

from pathlib import Path

import nibabel as nib
import numpy as np
import pandas as pd

from mld_tbss.config import (
    MP2RAGE,
    NOT_APPLICABLE,
    OUTPUT_METRICS_DIR,
    T1_SEGMENTED_DIR,
    TEMPORARY_DATA_DIR,
)
from mld_tbss.utils import Cols

SUFFIX_LABEL_MAP = "_MP2RAGE_synthseg_labels.nii.gz"
SUFFIX_WMLABEL_MAP = "_MP2RAGE_WM_voronoi_labels.nii.gz"
SUFFIX_MTR = "_MTR_toT1.nii.gz"

OUT_PREFIX = "mri_outcome_metrics"
OUT_SUFFIX_MTR = "_MTR.csv"

MTR_DIR = TEMPORARY_DATA_DIR / "MTR_images"
FREESURFER_LABELMAP = Path(__file__).parents[1] / "g_fetch_freesurfer_labelmap.csv"

LABEL = "Label"
STRUCTURE = "Structure"
ID = "id"

BASENAME = "Basename"
VARIABLE = "Variable"
REGION_ID = "Region_ID"
VALUE = "Value"

RELEVANT_IMAGES = [MP2RAGE]

DECIMALS_TO_ROUND = 5

# %%
# load tabular data
data_df = pd.read_csv(
    Path(__file__).parents[1] / "b_collect_and_verify_data.csv", sep=";"
)
data_df = data_df[data_df[Cols.IMAGE_MODALITY].isin(RELEVANT_IMAGES)]
data_df[BASENAME] = (
    "subject_"
    + data_df[Cols.SUBJECT_ID].astype(str)
    + "_date_"
    + data_df[Cols.DATE_TAG].astype(str)
)

freesurfer_labelmap_full = pd.read_csv(FREESURFER_LABELMAP, sep=";")
freesurfer_label_id_list = freesurfer_labelmap_full[ID].tolist()
freesurfer_label_id_list.remove(0)  # drop background
freesurfer_structure_list = list(set(freesurfer_labelmap_full[STRUCTURE].tolist()))
freesurfer_structure_list = [
    x for x in freesurfer_structure_list if isinstance(x, str)
]  # remove missing

# %%
# compute data
output_list_long_mtr = []

for _, row in data_df.iterrows():
    basename = row[BASENAME]

    # create paths to relevant images
    synthseg_path = T1_SEGMENTED_DIR / f"{basename}{SUFFIX_LABEL_MAP}"
    wm_voronoi_path = T1_SEGMENTED_DIR / f"{basename}{SUFFIX_WMLABEL_MAP}"
    mtr_path = MTR_DIR / f"{basename}{SUFFIX_MTR}"

    # verify files exist
    for p in (synthseg_path, wm_voronoi_path):
        if not p.exists():
            raise FileNotFoundError(p)

    # skip ifMTR image is missing
    if not mtr_path.exists():
        print(f"No MTR image for {basename}, skipping case.")
        continue

    # load segmentation images and derived voxel volume
    synthseg_nifti = nib.load(  # pyright: ignore[reportPrivateImportUsage]
        synthseg_path
    )
    synthseg_data = np.asarray(synthseg_nifti.dataobj, dtype=np.int32)  # type: ignore

    wm_voronoi_nifti = nib.load(  # pyright: ignore[reportPrivateImportUsage]
        wm_voronoi_path
    )
    wm_voronoi_data = np.asarray(wm_voronoi_nifti.dataobj, dtype=np.int32)  # type: ignore

    # verify that segmentation and voronoi map are in the same orientation/resolution
    if not np.allclose(synthseg_nifti.affine, wm_voronoi_nifti.affine):  # type: ignore
        raise ValueError("Images differ in orientation or spatial alignment.")
    if not np.allclose(
        synthseg_nifti.header.get_zooms()[:3], wm_voronoi_nifti.header.get_zooms()[:3]  # type: ignore
    ):
        raise ValueError("Images differ in voxel resolution.")

    ##########
    # derive MTR data - median, 10th percentile
    # load MTR images and verify that orientation and resolution are aligned with the segmentation
    mtr_nifti = nib.load(mtr_path)  # pyright: ignore[reportPrivateImportUsage]
    mtr_data = np.asarray(mtr_nifti.dataobj, dtype=np.float32)  # type: ignore
    np.nan_to_num(mtr_data, copy=False)
    # verify that segmentation and voronoi map are in the same orientation/resolution
    if not np.allclose(wm_voronoi_nifti.affine, mtr_nifti.affine):  # type: ignore
        raise ValueError(
            "MTR and segmentation images differ in orientation or spatial alignment."
        )
    if not np.allclose(
        wm_voronoi_nifti.header.get_zooms()[:3], mtr_nifti.header.get_zooms()[:3]  # type: ignore
    ):
        raise ValueError("MTR and segmentation images differ in voxel resolution.")

    wm_labels_flat = wm_voronoi_data.ravel()
    mtr_data_flat = mtr_data.ravel()
    valid = (wm_labels_flat != 0) & np.isfinite(mtr_data_flat)
    if not np.any(valid):
        raise ValueError(f"No nonzero labels in {wm_voronoi_path}")

    wm_labels_flat = wm_labels_flat[valid]
    mtr_data_flat = mtr_data_flat[valid]

    max_label = wm_labels_flat.max()

    # median and 10th percentile per label
    # Sort by label once, then slice contiguous runs
    order = np.argsort(wm_labels_flat, kind="stable")
    wm_labels_sorted = wm_labels_flat[order]
    mtr_sorted = mtr_data_flat[order]
    uniq, idx_first, counts = np.unique(
        wm_labels_sorted, return_index=True, return_counts=True
    )

    med = np.empty_like(uniq, dtype=np.float32)
    p10 = np.empty_like(uniq, dtype=np.float32)
    for i, (start, cnt) in enumerate(zip(idx_first, counts, strict=True)):
        block = mtr_sorted[start : start + cnt]
        med[i] = np.quantile(block, 0.5, method="linear")
        p10[i] = np.quantile(block, 0.1, method="linear")

    for label_id in uniq:
        idx = np.where(uniq == label_id)[0].item()

        label_name = freesurfer_labelmap_full.loc[
            freesurfer_labelmap_full[ID] == label_id, LABEL
        ].item()  # pyright: ignore[reportAttributeAccessIssue]
        structure = freesurfer_labelmap_full.loc[
            freesurfer_labelmap_full[ID] == label_id, STRUCTURE
        ].item()  # pyright: ignore[reportAttributeAccessIssue]

        # store median
        variable_name = f"{label_name}_median_mtr"
        output_list_long_mtr.append(
            {
                BASENAME: basename,
                VARIABLE: variable_name,
                REGION_ID: label_id,
                STRUCTURE: structure,
                VALUE: med[idx],
            }
        )
        # store p10
        variable_name = f"{label_name}_p10_mtr"
        output_list_long_mtr.append(
            {
                BASENAME: basename,
                VARIABLE: variable_name,
                REGION_ID: label_id,
                STRUCTURE: structure,
                VALUE: p10[idx],
            }
        )

    # MTR stats per STRUCTURE
    # Build label -> structure map for labels that occur
    present_labels = set(map(int, uniq.tolist()))
    label_to_structure = freesurfer_labelmap_full.loc[
        freesurfer_labelmap_full[ID].isin(present_labels), [ID, STRUCTURE]
    ].dropna()
    label_to_structure[ID] = label_to_structure[ID].astype(int)
    label_to_structure[STRUCTURE] = label_to_structure[STRUCTURE].astype(str)

    # Encode structures as integers for fast grouping
    structures = label_to_structure[STRUCTURE].drop_duplicates().tolist()
    struct_to_id = {s: i for i, s in enumerate(structures)}
    id_to_struct = {i: s for s, i in struct_to_id.items()}

    # Make a label->struct_id lookup array (size: max_label+1), default -1 for safety
    lab2struct = np.full(int(max_label) + 1, -1, dtype=np.int32)
    for lbl, struct in zip(
        label_to_structure[ID].to_numpy(),
        label_to_structure[STRUCTURE].to_numpy(),
        strict=True,
    ):
        lab2struct[int(lbl)] = struct_to_id[struct]

    # For every voxel (already sorted by label), get its struct_id
    struct_ids = lab2struct[wm_labels_sorted]
    mtr_for_struct = mtr_sorted

    # Medians and 10th percentiles per structure:
    # sort once by struct_id, then slice contiguous runs
    order_g = np.argsort(struct_ids, kind="stable")
    g_sorted = struct_ids[order_g]
    md_g_sorted = mtr_for_struct[order_g]
    guniq, gidx, gcnt = np.unique(g_sorted, return_index=True, return_counts=True)

    med_g = np.empty_like(guniq, dtype=np.float32)
    p10_g = np.empty_like(guniq, dtype=np.float32)
    for i, (start, cnt) in enumerate(zip(gidx, gcnt, strict=True)):
        block = md_g_sorted[start : start + cnt]
        med_g[i] = np.quantile(block, 0.5, method="linear")
        p10_g[i] = np.quantile(block, 0.1, method="linear")

    # Emit per-structure rows
    for sid, i in enumerate(guniq.tolist()):
        struct_name = id_to_struct[int(i)]
        output_list_long_mtr.extend(
            [
                {
                    BASENAME: basename,
                    VARIABLE: f"{struct_name}_median_mtr",
                    REGION_ID: NOT_APPLICABLE,
                    STRUCTURE: struct_name,
                    VALUE: float(med_g[sid]),
                },
                {
                    BASENAME: basename,
                    VARIABLE: f"{struct_name}_p10_mtr",
                    REGION_ID: NOT_APPLICABLE,
                    STRUCTURE: struct_name,
                    VALUE: float(p10_g[sid]),
                },
            ]
        )

    # MD stats for entire WM mask (all labels > 0)
    mtr_wm = mtr_data_flat  # already restricted to nonzero WM + finite values above
    output_list_long_mtr.extend(
        [
            {
                BASENAME: basename,
                VARIABLE: "WM_all_median_mtr",
                REGION_ID: NOT_APPLICABLE,
                STRUCTURE: NOT_APPLICABLE,
                VALUE: float(np.quantile(mtr_wm, 0.5, method="linear")),
            },
            {
                BASENAME: basename,
                VARIABLE: "WM_all_p10_mtr",
                REGION_ID: NOT_APPLICABLE,
                STRUCTURE: NOT_APPLICABLE,
                VALUE: float(np.quantile(mtr_wm, 0.1, method="linear")),
            },
        ]
    )

# %%
# store results
OUTPUT_METRICS_DIR.mkdir(parents=True, exist_ok=True)

# create blank dfs for results
output_df_mtr = pd.DataFrame(output_list_long_mtr)
output_df_mtr[VALUE] = output_df_mtr[VALUE].round(DECIMALS_TO_ROUND)
output_name = OUTPUT_METRICS_DIR / f"{OUT_PREFIX}{OUT_SUFFIX_MTR}"
output_df_mtr.to_csv(output_name, index=False, sep=";")

# %%
