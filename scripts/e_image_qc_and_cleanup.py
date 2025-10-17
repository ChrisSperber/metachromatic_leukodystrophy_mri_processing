"""Visualise images for quality control and clean up preprocessing files.

Visualise the skulls-stripped images in a pdf to verify:
- general image quality
- quality of skullstripping
- fit of T1 and FA images

Additionally, leftover files from the T1 preprocessing pipeline are removed.
"""

# %%

import re
from pathlib import Path

import matplotlib.pyplot as plt
import nibabel as nib
import numpy as np
import pandas as pd
from matplotlib.backends.backend_pdf import PdfPages
from nilearn.image import resample_to_img

from mld_tbss.config import COPY_FOLDER_DICT, MP2RAGE, T1_PREPROC_DIR
from mld_tbss.utils import Cols

DO_CLEANUP = False

IMAGE_SUFFIXES_TO_DELETE = [
    "_den.nii.gz",  # denoised raw image
    "_den_head.nii.gz",  # Loose preliminary BET result
    "_den_head_mask.nii.gz",  # Mask from the loose BET pre-pass
    "_bc.nii.gz",  # Bias-corrected image after N4
    "_bc_crop.nii.gz",  # same, but cropped
    "_brain.nii.gz",  # final output before intensity normnalisation
    "_brain_mask.nii.gz",  # Binary BET mask original
]

T1_SUFFIX = "_norm.nii.gz"

# overlay settings
FA_ALPHA = 0.45  # transparency of FA overlay
AXIAL_SLICES_FRAC = (0.30, 0.50, 0.70)  # relative positions through z
PANEL_ROWS, PANEL_COLS = 2, 3  # 2x3 subjects per page
FIGSIZE = (11.7, 8.3)  # A4 landscape inches

FA = "FA"
RELEVANT_IMAGES = [MP2RAGE, FA]
FULL_PATH_TO_IMAGE = "Full_Image_Path"

# %%
# collect file links
data_df = pd.read_csv(Path(__file__).parent / "b_collect_and_verify_data.csv", sep=";")
data_df = data_df[data_df[Cols.IMAGE_MODALITY].isin(RELEVANT_IMAGES)]
for _, row in data_df.iterrows():
    if row[Cols.IMAGE_MODALITY] == FA:
        data_df[FULL_PATH_TO_IMAGE] = COPY_FOLDER_DICT[FA] / row[Cols.FILENAME]
    elif row[Cols.IMAGE_MODALITY] == MP2RAGE:
        data_df[FULL_PATH_TO_IMAGE] = COPY_FOLDER_DICT[MP2RAGE] / row[Cols.FILENAME]
    else:
        raise ValueError(f"Invalid modality {row[Cols.IMAGE_MODALITY]}")


# %%
# Cleanup
if DO_CLEANUP:
    for file in T1_PREPROC_DIR.iterdir():
        if not file.is_file():
            continue
        if any(file.name.endswith(suf) for suf in IMAGE_SUFFIXES_TO_DELETE):
            print(f"Deleting {file.name}")
            file.unlink()
else:
    print("Cleanup not performed; set DO_CLEANUP if cleanup desired.")

# %%
