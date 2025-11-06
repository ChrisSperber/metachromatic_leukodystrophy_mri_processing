"""Derive volumetric/FA/MD metrics bases on the segmentation.

Derived various imaging metrics based on the SynthSeg Segmentation, including
- TIV
- region/structure-wise relative volume
- WM structure-wise
    - relative volume
    - FA median/90th percentile/% of volume >0.2
    - MD median/10th precentile

Output:
    - 3 long CSVs storing all variables for all subjects and sessions
        - xxx_volumetric.csv for brain volumes
        - xxx_A.csv for FA values
        - xxx_MD.csv for MD values
    All outputs are stored in a dedicated folder OUTPUT_METRICS_DIR

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
SUFFIX_REGISTERED_FA = "_FA_toT1.nii.gz"
SUFFIX_REGISTERED_MD = "_MD_toT1.nii.gz"

OUT_PREFIX = "mri_outcome_metrics"
OUT_SUFFIX_VOLUMETRIC = "_volumetric.csv"
OUT_SUFFIX_FA = "_FA.csv"
OUT_SUFFIX_MD = "_MD.csv"

DIFFUSION_MOVED_TO_T1_DIR = TEMPORARY_DATA_DIR / "DTI_images_moved_to_T1"
FREESURFER_LABELMAP = Path(__file__).parent / "g_fetch_freesurfer_labelmap.csv"

LABEL = "Label"
STRUCTURE = "Structure"
ID = "id"

BASENAME = "Basename"
VARIABLE = "Variable"
REGION_ID = "Region_ID"
VALUE = "Value"

TIV_VOXEL = "Total_Intracranial_Volume_nVoxel"
VOXEL_VOL_ML = "Voxel_Volume_ml"
TIV_ML = "Total_Intracranial_Volume_ml"

RELEVANT_IMAGES = [MP2RAGE]

FA_MASKING_CUTOFF = 0.2
DECIMALS_TO_ROUND = 5

# %%
# load tabular data
data_df = pd.read_csv(Path(__file__).parent / "b_collect_and_verify_data.csv", sep=";")
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
output_list_long_volumetry = []
output_list_long_fa = []
output_list_long_md = []

for _, row in data_df.iterrows():
    basename = row[BASENAME]

    # create paths to relevant images
    synthseg_path = T1_SEGMENTED_DIR / f"{basename}{SUFFIX_LABEL_MAP}"
    wm_voronoi_path = T1_SEGMENTED_DIR / f"{basename}{SUFFIX_WMLABEL_MAP}"
    fa_moved_to_t1_path = (
        DIFFUSION_MOVED_TO_T1_DIR / f"{basename}{SUFFIX_REGISTERED_FA}"
    )
    md_moved_to_t1_path = (
        DIFFUSION_MOVED_TO_T1_DIR / f"{basename}{SUFFIX_REGISTERED_MD}"
    )

    # verify files exist
    for p in (synthseg_path, wm_voronoi_path, fa_moved_to_t1_path, md_moved_to_t1_path):
        if not p.exists():
            raise FileNotFoundError(p)

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
    # derive volumetric data
    voxel_sizes = np.abs(synthseg_nifti.header.get_zooms())[:3]  # type: ignore
    voxel_volume_synthseg_ml = np.prod(voxel_sizes) / 1000  # mm³ per voxel / 1000
    tiv_n_voxels = np.count_nonzero(synthseg_data)

    # tiv and voxel volume
    output_list_long_volumetry.append(
        {
            BASENAME: basename,
            VARIABLE: TIV_VOXEL,
            REGION_ID: NOT_APPLICABLE,
            STRUCTURE: NOT_APPLICABLE,
            VALUE: tiv_n_voxels,
        }
    )
    output_list_long_volumetry.append(
        {
            BASENAME: basename,
            VARIABLE: VOXEL_VOL_ML,
            REGION_ID: NOT_APPLICABLE,
            STRUCTURE: NOT_APPLICABLE,
            VALUE: voxel_volume_synthseg_ml,
        }
    )
    output_list_long_volumetry.append(
        {
            BASENAME: basename,
            VARIABLE: TIV_ML,
            REGION_ID: NOT_APPLICABLE,
            STRUCTURE: NOT_APPLICABLE,
            VALUE: tiv_n_voxels * voxel_volume_synthseg_ml,
        }
    )

    labels, counts = np.unique(synthseg_data, return_counts=True)
    voxel_count_map = dict(zip(labels.tolist(), counts.tolist(), strict=True))

    for label_id in freesurfer_label_id_list:
        label_voxel_count = voxel_count_map.get(label_id, 0)

        label_name = freesurfer_labelmap_full.loc[
            freesurfer_labelmap_full[ID] == label_id, LABEL
        ].item()  # pyright: ignore[reportAttributeAccessIssue]
        structure = freesurfer_labelmap_full.loc[
            freesurfer_labelmap_full[ID] == label_id, STRUCTURE
        ].item()  # pyright: ignore[reportAttributeAccessIssue]

        variable_name = f"{label_name}_percent_tiv"
        output_list_long_volumetry.append(
            {
                BASENAME: basename,
                VARIABLE: variable_name,
                REGION_ID: label_id,
                STRUCTURE: structure,
                VALUE: label_voxel_count / tiv_n_voxels * 100,
            }
        )

    for structure in freesurfer_structure_list:
        mask = freesurfer_labelmap_full[STRUCTURE].eq(structure)
        region_ids = freesurfer_labelmap_full.loc[mask, ID].to_numpy()

        total_voxels = sum(voxel_count_map.get(int(rid), 0) for rid in region_ids)

        variable_name = f"{structure}_structure_percent_tiv"
        output_list_long_volumetry.append(
            {
                BASENAME: basename,
                VARIABLE: variable_name,
                REGION_ID: NOT_APPLICABLE,
                STRUCTURE: structure,
                VALUE: total_voxels / tiv_n_voxels * 100,
            }
        )

    ##########
    # derive FA data - median, 90th percentile, % of voxels above threshold
    # load FA images and verify that orientation and resolution are aligned with the segmentation
    fa_nifti = nib.load(  # pyright: ignore[reportPrivateImportUsage]
        fa_moved_to_t1_path
    )
    fa_data = fa_nifti.get_fdata(dtype=np.float32)  # type: ignore
    # verify that segmentation and voronoi map are in the same orientation/resolution
    if not np.allclose(wm_voronoi_nifti.affine, fa_nifti.affine):  # type: ignore
        raise ValueError(
            "FA and segmenetation images differ in orientation or spatial alignment."
        )
    if not np.allclose(
        wm_voronoi_nifti.header.get_zooms()[:3], fa_nifti.header.get_zooms()[:3]  # type: ignore
    ):
        raise ValueError("FA and segmenetation images differ in voxel resolution.")

    wm_labels_flat = wm_voronoi_data.ravel()
    fa_data_flat = fa_data.ravel()
    valid = wm_labels_flat != 0
    if not np.any(valid):
        raise ValueError(f"No nonzero labels in {wm_voronoi_path}")

    wm_labels_flat = wm_labels_flat[valid]
    fa_data_flat = fa_data_flat[valid]

    # percentage of volume > threshold via bincount
    max_label = wm_labels_flat.max()
    # total voxels per label
    n_total = np.bincount(wm_labels_flat, minlength=max_label + 1)

    # voxels with FA > threshold per label
    over_mask = fa_data_flat > FA_MASKING_CUTOFF
    n_over = np.bincount(wm_labels_flat[over_mask], minlength=max_label + 1)

    # median and 90th percentile per label
    # Sort by label once, then slice contiguous runs
    order = np.argsort(wm_labels_flat, kind="stable")
    wm_labels_sorted = wm_labels_flat[order]
    fa_sorted = fa_data_flat[order]
    uniq, idx_first, counts = np.unique(
        wm_labels_sorted, return_index=True, return_counts=True
    )

    med = np.empty_like(uniq, dtype=np.float32)
    p90 = np.empty_like(uniq, dtype=np.float32)
    for i, (start, cnt) in enumerate(zip(idx_first, counts, strict=True)):
        block = fa_sorted[start : start + cnt]
        med[i] = np.quantile(block, 0.5, method="linear")
        p90[i] = np.quantile(block, 0.9, method="linear")

    # align bincount results (present) with uniq
    # both represent the same set of labels; uniq is sorted ascending
    n_total_arr = n_total[uniq]
    n_over_arr = n_over[uniq]
    pct_over = (n_over_arr / n_total_arr) * 100.0

    for label_id in uniq:
        idx = np.where(uniq == label_id)[0].item()

        label_name = freesurfer_labelmap_full.loc[
            freesurfer_labelmap_full[ID] == label_id, LABEL
        ].item()  # pyright: ignore[reportAttributeAccessIssue]
        structure = freesurfer_labelmap_full.loc[
            freesurfer_labelmap_full[ID] == label_id, STRUCTURE
        ].item()  # pyright: ignore[reportAttributeAccessIssue]

        # store median
        variable_name = f"{label_name}_median_fa"
        output_list_long_fa.append(
            {
                BASENAME: basename,
                VARIABLE: variable_name,
                REGION_ID: label_id,
                STRUCTURE: structure,
                VALUE: med[idx],
            }
        )
        # store p90
        variable_name = f"{label_name}_p90_fa"
        output_list_long_fa.append(
            {
                BASENAME: basename,
                VARIABLE: variable_name,
                REGION_ID: label_id,
                STRUCTURE: structure,
                VALUE: p90[idx],
            }
        )
        # store % over threshold
        variable_name = f"{label_name}_percent_above_thres_fa"
        output_list_long_fa.append(
            {
                BASENAME: basename,
                VARIABLE: variable_name,
                REGION_ID: label_id,
                STRUCTURE: structure,
                VALUE: pct_over[idx],
            }
        )

    # FA stats per STRUCTURE
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
    fa_for_struct = fa_sorted

    # Percent > threshold per structure
    n_total_struct = np.bincount(struct_ids, minlength=len(structures))
    n_over_struct = np.bincount(
        struct_ids[fa_for_struct > FA_MASKING_CUTOFF], minlength=len(structures)
    )
    pct_over_struct = (n_over_struct / n_total_struct) * 100.0

    # Medians and 90th percentiles per structure:
    # sort once by struct_id, then slice contiguous runs
    order_g = np.argsort(struct_ids, kind="stable")
    g_sorted = struct_ids[order_g]
    fa_g_sorted = fa_for_struct[order_g]
    guniq, gidx, gcnt = np.unique(g_sorted, return_index=True, return_counts=True)

    med_g = np.empty_like(guniq, dtype=np.float32)
    p90_g = np.empty_like(guniq, dtype=np.float32)
    for i, (start, cnt) in enumerate(zip(gidx, gcnt, strict=True)):
        block = fa_g_sorted[start : start + cnt]
        med_g[i] = np.quantile(block, 0.5, method="linear")
        p90_g[i] = np.quantile(block, 0.9, method="linear")

    # Emit per-structure rows
    for sid, i in enumerate(guniq.tolist()):
        struct_name = id_to_struct[int(i)]
        output_list_long_fa.extend(
            [
                {
                    BASENAME: basename,
                    VARIABLE: f"{struct_name}_median_fa",
                    REGION_ID: NOT_APPLICABLE,
                    STRUCTURE: struct_name,
                    VALUE: float(med_g[sid]),
                },
                {
                    BASENAME: basename,
                    VARIABLE: f"{struct_name}_p90_fa",
                    REGION_ID: NOT_APPLICABLE,
                    STRUCTURE: struct_name,
                    VALUE: float(p90_g[sid]),
                },
                {
                    BASENAME: basename,
                    VARIABLE: f"{struct_name}_percent_above_thres_fa",
                    REGION_ID: NOT_APPLICABLE,
                    STRUCTURE: struct_name,
                    VALUE: float(pct_over_struct[i]),
                },
            ]
        )

    # FA stats for entire WM mask (all labels > 0)
    fa_wm = fa_data_flat
    output_list_long_fa.extend(
        [
            {
                BASENAME: basename,
                VARIABLE: "WM_all_median_fa",
                REGION_ID: NOT_APPLICABLE,
                STRUCTURE: NOT_APPLICABLE,
                VALUE: float(np.quantile(fa_wm, 0.5, method="linear")),
            },
            {
                BASENAME: basename,
                VARIABLE: "WM_all_p90_fa",
                REGION_ID: NOT_APPLICABLE,
                STRUCTURE: NOT_APPLICABLE,
                VALUE: float(np.quantile(fa_wm, 0.9, method="linear")),
            },
            {
                BASENAME: basename,
                VARIABLE: "WM_all_percent_above_thres_fa",
                REGION_ID: NOT_APPLICABLE,
                STRUCTURE: NOT_APPLICABLE,
                VALUE: float((fa_wm > FA_MASKING_CUTOFF).mean() * 100.0),
            },
        ]
    )

    ##########
    # derive MD data - median, 10th percentile
    # NOTE: variables from the FA block are not re-used to keep modularity
    # load MD images and verify that orientation and resolution are aligned with the segmentation
    md_nifti = nib.load(  # pyright: ignore[reportPrivateImportUsage]
        md_moved_to_t1_path
    )
    md_data = np.asarray(md_nifti.dataobj, dtype=np.float32)  # type: ignore
    np.nan_to_num(md_data, copy=False)
    # verify that segmentation and voronoi map are in the same orientation/resolution
    if not np.allclose(wm_voronoi_nifti.affine, md_nifti.affine):  # type: ignore
        raise ValueError(
            "MD and segmenetation images differ in orientation or spatial alignment."
        )
    if not np.allclose(
        wm_voronoi_nifti.header.get_zooms()[:3], md_nifti.header.get_zooms()[:3]  # type: ignore
    ):
        raise ValueError("MD and segmenetation images differ in voxel resolution.")

    wm_labels_flat = wm_voronoi_data.ravel()
    md_data_flat = md_data.ravel()
    valid = (wm_labels_flat != 0) & np.isfinite(md_data_flat)
    if not np.any(valid):
        raise ValueError(f"No nonzero labels in {wm_voronoi_path}")

    wm_labels_flat = wm_labels_flat[valid]
    md_data_flat = md_data_flat[valid]

    max_label = wm_labels_flat.max()

    # median and 10th percentile per label
    # Sort by label once, then slice contiguous runs
    order = np.argsort(wm_labels_flat, kind="stable")
    wm_labels_sorted = wm_labels_flat[order]
    md_sorted = md_data_flat[order]
    uniq, idx_first, counts = np.unique(
        wm_labels_sorted, return_index=True, return_counts=True
    )

    med = np.empty_like(uniq, dtype=np.float32)
    p10 = np.empty_like(uniq, dtype=np.float32)
    for i, (start, cnt) in enumerate(zip(idx_first, counts, strict=True)):
        block = md_sorted[start : start + cnt]
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
        variable_name = f"{label_name}_median_md"
        output_list_long_md.append(
            {
                BASENAME: basename,
                VARIABLE: variable_name,
                REGION_ID: label_id,
                STRUCTURE: structure,
                VALUE: med[idx],
            }
        )
        # store p10
        variable_name = f"{label_name}_p10_md"
        output_list_long_md.append(
            {
                BASENAME: basename,
                VARIABLE: variable_name,
                REGION_ID: label_id,
                STRUCTURE: structure,
                VALUE: p10[idx],
            }
        )

    # MD stats per STRUCTURE
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
    md_for_struct = md_sorted

    # Medians and 10th percentiles per structure:
    # sort once by struct_id, then slice contiguous runs
    order_g = np.argsort(struct_ids, kind="stable")
    g_sorted = struct_ids[order_g]
    md_g_sorted = md_for_struct[order_g]
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
        output_list_long_md.extend(
            [
                {
                    BASENAME: basename,
                    VARIABLE: f"{struct_name}_median_md",
                    REGION_ID: NOT_APPLICABLE,
                    STRUCTURE: struct_name,
                    VALUE: float(med_g[sid]),
                },
                {
                    BASENAME: basename,
                    VARIABLE: f"{struct_name}_p10_md",
                    REGION_ID: NOT_APPLICABLE,
                    STRUCTURE: struct_name,
                    VALUE: float(p10_g[sid]),
                },
            ]
        )

    # MD stats for entire WM mask (all labels > 0)
    md_wm = md_data_flat  # already restricted to nonzero WM + finite values above
    output_list_long_md.extend(
        [
            {
                BASENAME: basename,
                VARIABLE: "WM_all_median_md",
                REGION_ID: NOT_APPLICABLE,
                STRUCTURE: NOT_APPLICABLE,
                VALUE: float(np.quantile(md_wm, 0.5, method="linear")),
            },
            {
                BASENAME: basename,
                VARIABLE: "WM_all_p10_md",
                REGION_ID: NOT_APPLICABLE,
                STRUCTURE: NOT_APPLICABLE,
                VALUE: float(np.quantile(md_wm, 0.1, method="linear")),
            },
        ]
    )


# %%
# store results
OUTPUT_METRICS_DIR.mkdir(parents=True, exist_ok=True)

# create blank dfs for results
output_df_volumetry = pd.DataFrame(output_list_long_volumetry)
output_df_volumetry[VALUE] = output_df_volumetry[VALUE].round(DECIMALS_TO_ROUND)
output_name = OUTPUT_METRICS_DIR / f"{OUT_PREFIX}{OUT_SUFFIX_VOLUMETRIC}"
output_df_volumetry.to_csv(output_name, index=False, sep=";")

output_df_fa = pd.DataFrame(output_list_long_fa)
output_df_fa[VALUE] = output_df_fa[VALUE].round(DECIMALS_TO_ROUND)
output_name = OUTPUT_METRICS_DIR / f"{OUT_PREFIX}{OUT_SUFFIX_FA}"
output_df_fa.to_csv(output_name, index=False, sep=";")

output_df_md = pd.DataFrame(output_list_long_md)
output_df_md[VALUE] = output_df_md[VALUE].round(DECIMALS_TO_ROUND)
output_name = OUTPUT_METRICS_DIR / f"{OUT_PREFIX}{OUT_SUFFIX_MD}"
output_df_md.to_csv(output_name, index=False, sep=";")

# %%
