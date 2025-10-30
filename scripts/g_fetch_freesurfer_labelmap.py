"""Fetch and clean the Freesurfer Label map.

Requirements: An xls with a mapping of labels to meta structures was created as fetched by
STRUCTURE_LABEL_MAP. This file was created manually.
"""

# %%
import os
from pathlib import Path

import nibabel as nib
import numpy as np
import pandas as pd

from mld_tbss.config import T1_SEGMENTED_DIR

SUFFIX_LABEL_MAP = "_MP2RAGE_synthseg_labels.nii.gz"
STRUCTURE_LABEL_MAP = (
    Path(__file__).parents[1] / "src" / "freesurfer_labelmap_w_structure_labels.xlsx"
)

HEMISPHERE = "Hemisphere"
LABEL = "Label"

LEFT = "Left"
RIGHT = "Right"
NONE = "None"
RIGHT_TAGS = ["Right", "-rh-"]
LEFT_TAGS = ["Left", "-lh-"]

# %%
# Get Freesurfer Path and fetch label map
if "FREESURFER_HOME" in os.environ:
    freesurfer_home = Path(os.environ["FREESURFER_HOME"])
    print(f"Freesurfer Home Dir found under {freesurfer_home}")
else:
    msg = "Environment variable $FREESURFER_HOME not found"
    raise RuntimeError(msg)

freesurfer_label_lut = freesurfer_home / "FreeSurferColorLUT.txt"

# %%
# parse LUT
records = []
with open(freesurfer_label_lut) as f:
    for txt_line in f:
        line = txt_line.strip()
        # skip comments and empty lines
        if not line or line.startswith("#"):
            continue

        # split and check length
        parts = line.split()
        if len(parts) < 6:  # noqa: PLR2004
            continue  # malformed or non-data line

        # parse: ID  NAME
        try:
            idx = int(parts[0])
            name = " ".join(parts[1:-4])
        except ValueError:
            continue  # skip non-integer or invalid lines

        records.append(
            {
                "id": idx,
                "name": name,
            }
        )

lut_df = pd.DataFrame.from_records(records).sort_values("id").reset_index(drop=True)

# %%
# load existing images to identify all used label numbers
unique_values_set = set()

for file in T1_SEGMENTED_DIR.iterdir():
    if file.is_file() and SUFFIX_LABEL_MAP in file.name:
        nifti = nib.load(file)  # pyright: ignore[reportPrivateImportUsage]
        data = nifti.get_fdata()  # pyright: ignore[reportAttributeAccessIssue]
        unique_values_set.update(np.unique(data))

unique_values_list = sorted(unique_values_set)
# Convert each value to integer
unique_values_list = [int(value) for value in unique_values_list]

# %%
# drop all labels that are not used in the segmentations
lut_df_filtered = lut_df[lut_df["id"].isin(unique_values_list)]

lut_df_filtered.rename(columns={"name": LABEL}, inplace=True)

# %% get structure labels and derive hemisphere labels
structure_mapping_df = pd.read_excel(STRUCTURE_LABEL_MAP)
lut_df_filtered = lut_df_filtered.merge(
    right=structure_mapping_df, how="left", left_on=LABEL, right_on=LABEL
)
lut_df_filtered[HEMISPHERE] = NONE
for index, row in lut_df_filtered.iterrows():
    label = row[LABEL]
    if any(tag in label for tag in RIGHT_TAGS):
        lut_df_filtered.loc[index, HEMISPHERE] = RIGHT  # type: ignore
    elif any(tag in label for tag in LEFT_TAGS):
        lut_df_filtered.loc[index, HEMISPHERE] = LEFT  # type: ignore


# %%
# save in local csv
output_name = Path(__file__).with_suffix(".csv")
lut_df_filtered.to_csv(output_name, index=False, sep=";")

# %%
