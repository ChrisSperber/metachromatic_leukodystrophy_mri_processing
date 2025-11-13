"""Sub-segment the white matter parcel in SynthSeg segmentation of the example ch2 template."""

# %%
from pathlib import Path

import nibabel as nib
import numpy as np
import pandas as pd

from mld_tbss.config import NON_REQUIRED_LABEL_STRUCTURES_VORONOI, TEMPORARY_DATA_DIR
from mld_tbss.utils import combine_hemispheres, voronoi_subparcellate

CH2_TEMPLATE_DIR = TEMPORARY_DATA_DIR / "ch2_pipeline_demo"

HEMISPHERE = "Hemisphere"
LABEL = "Label"
STRUCTURE = "Structure"
ID = "id"

FREESURFER_LABELMAP = Path(__file__).parent / "g_fetch_freesurfer_labelmap.csv"
SUFFIX_LABEL_MAP = "_synthseg_labels.nii.gz"
SUFFIX_LABEL_OUTPUT = "_WM_voronoi_labels.nii.gz"

LEFT = "Left"
RIGHT = "Right"
LEFT_CEREBRAL_WM = "Left-Cerebral-White-Matter"
RIGHT_CEREBRAL_WM = "Right-Cerebral-White-Matter"

REQUIRED_WM_LABELS_LEFT = [LEFT_CEREBRAL_WM]
REQUIRED_WM_LABELS_RIGHT = [RIGHT_CEREBRAL_WM]

# %%
# get label map and identify labels for right/left hemisphere
freesurfer_labelmap_full = pd.read_csv(FREESURFER_LABELMAP, sep=";")
# drop non required structure (like wm)
# drop non required structure (like wm)
freesurfer_labelmap = freesurfer_labelmap_full[
    ~freesurfer_labelmap_full[STRUCTURE].isin(NON_REQUIRED_LABEL_STRUCTURES_VORONOI)
]
# drop background
freesurfer_labelmap = freesurfer_labelmap[freesurfer_labelmap[LABEL] != "Unknown"]
# create left/right label maps
freesurfer_labelmap_left = freesurfer_labelmap[freesurfer_labelmap[HEMISPHERE] != RIGHT]
freesurfer_labelmap_right = freesurfer_labelmap[freesurfer_labelmap[HEMISPHERE] != LEFT]

freesurfer_labelmap_wm_left = freesurfer_labelmap_full[
    freesurfer_labelmap_full[LABEL].isin(REQUIRED_WM_LABELS_LEFT)
]
freesurfer_labelmap_wm_right = freesurfer_labelmap_full[
    freesurfer_labelmap_full[LABEL].isin(REQUIRED_WM_LABELS_RIGHT)
]

# %%
# create Vonoroi mapping

for file in CH2_TEMPLATE_DIR.iterdir():
    if file.is_file() and SUFFIX_LABEL_MAP in file.name:
        nifti = nib.load(file)  # pyright: ignore[reportPrivateImportUsage]
        data = nifti.get_fdata(dtype=np.float32).round().astype(np.int32)  # type: ignore
        voxel_size = nifti.header.get_zooms()[:3]  # type: ignore

        # create maps for left hemisphere
        segm_labels_to_keep = freesurfer_labelmap_left[ID].tolist()
        segmentation_left_arr = np.where(np.isin(data, segm_labels_to_keep), data, 0)

        wm_labels_to_keep = freesurfer_labelmap_wm_left[ID].tolist()
        white_matter_left_arr = np.where(np.isin(data, wm_labels_to_keep), data, 0)

        # create maps for right hemisphere
        segm_labels_to_keep = freesurfer_labelmap_right[ID].tolist()
        segmentation_right_arr = np.where(np.isin(data, segm_labels_to_keep), data, 0)

        wm_labels_to_keep = freesurfer_labelmap_wm_right[ID].tolist()
        white_matter_right_arr = np.where(np.isin(data, wm_labels_to_keep), data, 0)

        # subsegment left hemisphere
        voronoi_segm_left = voronoi_subparcellate(
            to_subdivide=white_matter_left_arr,
            seed_labels=segmentation_left_arr,
            spacing=voxel_size,
            dtype_out=np.int32,
        )
        # subsegment right hemisphere
        voronoi_segm_right = voronoi_subparcellate(
            to_subdivide=white_matter_right_arr,
            seed_labels=segmentation_right_arr,
            spacing=voxel_size,
            dtype_out=np.int32,
        )

        # re-combine hemispheres
        voronoi_segm_wholebrain = combine_hemispheres(
            voronoi_segm_left, voronoi_segm_right
        )

        new_nifti = nib.Nifti1Image(  # pyright: ignore[reportPrivateImportUsage]
            voronoi_segm_wholebrain,
            affine=nifti.affine,  # pyright: ignore[reportAttributeAccessIssue]
            header=nifti.header,
        )
        new_nifti.set_data_dtype(np.int32)

        output_filename = file.name.replace(SUFFIX_LABEL_MAP, SUFFIX_LABEL_OUTPUT)
        output_path = CH2_TEMPLATE_DIR / output_filename
        nib.save(  # pyright: ignore[reportPrivateImportUsage]
            new_nifti, str(output_path)
        )

print("Done. Subparcellated ch2.")

# %%
