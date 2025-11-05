"""Derive volumetric/FA/MD metrics bases on the segmentation.

Derived various imaging metrics based on the SynthSeg Segmentation, including
- TIV
- region/structure-wise relative volume
- WM structure-wise
    - relative volume
    - FA median/90th percentile/% of volume >0.2
    - MD median/10th precentile

Output:
    - 3 CSVs storing all variables for all subjects and sessions
        - xxx_metrics_volumetric.csv for brain volumes
        - xxx_metrics_FA.csv for FA values
        - xxx_metrics_MD.csv for MD values

"""

# %%

from pathlib import Path

import nibabel as nib
import numpy as np
import pandas as pd

from mld_tbss.config import (
    MP2RAGE,
    NOT_APPLICABLE,
    T1_SEGMENTED_DIR,
    TEMPORARY_DATA_DIR,
)
from mld_tbss.utils import Cols

SUFFIX_LABEL_MAP = "_MP2RAGE_synthseg_labels.nii.gz"
SUFFIX_WMLABEL_MAP = "_MP2RAGE_WM_voronoi_labels.nii.gz"
SUFFIX_REGISTERED_FA = "_FA_toT1.nii.gz"
SUFFIX_REGISTERED_MD = "_MD_toT1.nii.gz"

OUT_SUFFIX_VOLUMETRIC = "_metrics_volumetric.csv"
OUT_SUFFIX_FA = "_metrics_FA.csv"
OUT_SUFFIX_MD = "_metrics_MD.csv"

DIFFUSION_MOVED_TO_T1_DIR = TEMPORARY_DATA_DIR / "DTI_images_moved_to_T1"
FREESURFER_LABELMAP = Path(__file__).parent / "g_fetch_freesurfer_labelmap.csv"

HEMISPHERE = "Hemisphere"
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
    synthseg_data = (
        synthseg_nifti.get_fdata(dtype=np.float32).round().astype(np.int32)  # type: ignore
    )

    wm_voronoi_nifti = nib.load(  # pyright: ignore[reportPrivateImportUsage]
        wm_voronoi_path
    )
    wm_voronoi_data = (
        wm_voronoi_nifti.get_fdata(dtype=np.float32).round().astype(np.int32)  # type: ignore
    )

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
        label_to_index = {lbl: i for i, lbl in enumerate(labels.tolist())}

        # indices of region IDs that exist in `labels` (None for missing)
        indices_in_labels = [label_to_index.get(int(rid), None) for rid in region_ids]

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

# %%

# create blank dfs for results
output_df_volumetry = (
    data_df[[Cols.SUBJECT_ID, Cols.DATE_TAG, BASENAME]].copy().set_index(BASENAME)
)
output_df_fa = (
    data_df[[Cols.SUBJECT_ID, Cols.DATE_TAG, BASENAME]].copy().set_index(BASENAME)
)
output_df_md = (
    data_df[[Cols.SUBJECT_ID, Cols.DATE_TAG, BASENAME]].copy().set_index(BASENAME)
)

# %%
