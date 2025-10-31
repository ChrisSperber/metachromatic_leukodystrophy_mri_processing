"""Sub-segment the white matter parcel in SynthSeg segmentations.

Perform a Voronoi labeling of the white matter mask, i.e. sub-segment white matter according to
proximity to the nearest GM label.
"""

# %%
from pathlib import Path

import nibabel as nib
import numpy as np
import pandas as pd

from mld_tbss.config import T1_SEGMENTED_DIR

DEBUG_TEST_FOLDER = T1_SEGMENTED_DIR.parent / "test"

FREESURFER_LABELMAP = Path(__file__).parent / "g_fetch_freesurfer_labelmap.csv"
SUFFIX_LABEL_MAP = "_MP2RAGE_synthseg_labels.nii.gz"

HEMISPHERE = "Hemisphere"
LABEL = "Label"
STRUCTURE = "Structure"
ID = "id"

LEFT = "Left"
RIGHT = "Right"
LEFT_CEREBRAL_WM = "Left-Cerebral-White-Matter"
RIGHT_CEREBRAL_WM = "Right-Cerebral-White-Matter"

# some labels that need to be removed for the present task
WHITE_MATTER = "White_Matter"
CEREBELLUM = "Cerebellum"
BRAINSTEM = "Brainstem"
NON_REQUIRED_LABEL_STRUCTURES = [WHITE_MATTER, CEREBELLUM, BRAINSTEM]
REQUIRED_WM_LABELS_LEFT = [LEFT_CEREBRAL_WM]
REQUIRED_WM_LABELS_RIGHT = [RIGHT_CEREBRAL_WM]

# %%
# get label map and identify labels for right/left hemisphere
freesurfer_labelmap_full = pd.read_csv(FREESURFER_LABELMAP, sep=";")
# drop non required structure (like wm)
freesurfer_labelmap = freesurfer_labelmap_full[
    ~freesurfer_labelmap_full[STRUCTURE].isin(NON_REQUIRED_LABEL_STRUCTURES)
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
for file in DEBUG_TEST_FOLDER.iterdir():
    if file.is_file() and SUFFIX_LABEL_MAP in file.name:
        nifti = nib.load(file)  # pyright: ignore[reportPrivateImportUsage]
        data = nifti.get_fdata()  # pyright: ignore[reportAttributeAccessIssue]

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


# %%
