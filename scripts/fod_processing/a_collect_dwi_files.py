"""Collect paths to all DWI files.

For generation of FOD images, the original dwi files have to be identified. For easier processing of
data further downstream, the paths to these files are documented here.

Requirements:
    - The main analysis scripts were succesfully run, specifically the collection of demographic
        data
Outputs:
    - a tsv file with basic identifiers/relevant data and dwi/bval/bvec paths relative to
        ORIGINAL_DATA_ROOT_DIR
        NOTE: The output is hidden from the repository to keep initials confidential
"""

# %%

from pathlib import Path

import pandas as pd

from mld_tbss.config import (
    CONTROL,
    ORIGINAL_DATA_ROOT_DIR,
    ORIGINAL_DIFFUSION_DATA_DIR,
    PATIENT,
    PATIENT_ID_MAPPING,
)
from mld_tbss.utils import Cols, DWIPathCols, find_unique_path

SAMPLE_DATA_CSV = Path(__file__).parents[1] / "b_collect_and_verify_data.csv"

BVAL_FILENAME = "dwis.bval"
BVEC_FILENAME = "dwis.bvec"
DWI_FILENAME = "dwis-dnc.nii.gz"

WRONG_INITIALS = ["lp", "ltu"]

# %%
# load main data df
sample_data_df = pd.read_csv(SAMPLE_DATA_CSV, sep=";")
sample_data_df = sample_data_df[sample_data_df[Cols.IMAGE_MODALITY] == "FA"]

patient_id_df = pd.read_excel(PATIENT_ID_MAPPING)
# drop invalid initials
patient_id_df = patient_id_df[~patient_id_df["Initials"].isin(WRONG_INITIALS)]


dwi_path_list = []
bval_path_list = []
bvec_path_list = []

# list all potential dwi files
bval_filepaths_list = list(ORIGINAL_DIFFUSION_DATA_DIR.rglob(BVAL_FILENAME))
bvec_filepaths_list = list(ORIGINAL_DIFFUSION_DATA_DIR.rglob(BVEC_FILENAME))
dwi_filepaths_list = list(ORIGINAL_DIFFUSION_DATA_DIR.rglob(DWI_FILENAME))

# %%

for _, row in sample_data_df.iterrows():
    if row[Cols.SUBJECT_TYPE] == PATIENT:

        patient_id = int(row[Cols.SUBJECT_ID])
        subset: pd.Series = patient_id_df.loc[patient_id_df["ID"] == patient_id, "Initials"]  # type: ignore
        if len(subset) != 1:
            raise ValueError(
                f"Expected exactly one match for {patient_id}, got {len(subset)}"
            )
        subjectname_in_path = subset.iloc[0]

        date_tag = row[Cols.DATE_TAG]

        bval_path = find_unique_path(bval_filepaths_list, subjectname_in_path, date_tag)
        bvec_path = find_unique_path(bvec_filepaths_list, subjectname_in_path, date_tag)
        dwi_path = find_unique_path(dwi_filepaths_list, subjectname_in_path, date_tag)
    elif row[Cols.SUBJECT_TYPE] == CONTROL:
        subjectname_in_path = row[Cols.SUBJECT_ID]
        if "MLD119" in subjectname_in_path:
            if "skyra" in subjectname_in_path:
                subjectname_in_path = "MLD119/skyra"
            elif "prisma" in subjectname_in_path:
                subjectname_in_path = "MLD119/prisma"
            else:
                raise ValueError(
                    f"Handling subject MLD119 failed for {subjectname_in_path}!"
                )
        bval_path = find_unique_path(bval_filepaths_list, subjectname_in_path)
        bvec_path = find_unique_path(bvec_filepaths_list, subjectname_in_path)
        dwi_path = find_unique_path(dwi_filepaths_list, subjectname_in_path)
    else:
        raise ValueError(f"Invalid subject type {row[Cols.SUBJECT_TYPE]}")

    bval_path_list.append(bval_path.relative_to(ORIGINAL_DATA_ROOT_DIR))
    bvec_path_list.append(bvec_path.relative_to(ORIGINAL_DATA_ROOT_DIR))
    dwi_path_list.append(dwi_path.relative_to(ORIGINAL_DATA_ROOT_DIR))

# %%
# assign to df and prepare output
sample_data_df[DWIPathCols.DWI_PATH] = dwi_path_list
sample_data_df[DWIPathCols.BVAL_PATH] = bval_path_list
sample_data_df[DWIPathCols.BVEC_PATH] = bvec_path_list

relevent_cols = [
    Cols.SUBJECT_ID,
    Cols.DATE_TAG,
    Cols.DTI_METHOD,
    DWIPathCols.DWI_PATH,
    DWIPathCols.BVAL_PATH,
    DWIPathCols.BVEC_PATH,
]

output_df = sample_data_df[relevent_cols].copy()

# %%
# store output
outname = Path(__file__).with_suffix(".tsv")
output_df.to_csv(outname, sep="\t", index=False)

# %%
