"""Collect paths to all DWI files.

For generation of FOD images, the original dwi files have to be identified. For easier processing of
data further downstream, the paths to these files are documented here.

Requirements:
    - The main analysis scripts were succesfully run, specifically the collection of demographic
        data
    - white matter (wm) mif images were created in scripts/fod_processing
        These mif images were chosen to improve the peak map generation. They were fetched from the
        other pipeline as the original data contained incomplete mif files.
Outputs:
    - a tsv file with basic identifiers/relevant data and dwi/bval/bvec paths relative to
        ORIGINAL_DATA_ROOT_DIR
        NOTE: The output is hidden from the repository to keep initials confidential
        NOTE: The code was copied from fod processing that used the same base data, with wm mif and
                mask identification added

"""

# %%

from pathlib import Path

import numpy as np
import pandas as pd

from mld_tbss.config import (
    CONTROL,
    ORIGINAL_DIFFUSION_DATA_DIR,
    PATIENT,
    PATIENT_ID_MAPPING,
    TEMPORARY_DATA_DIR,
)
from mld_tbss.utils import Cols, DWIPathCols, find_unique_path

SAMPLE_DATA_CSV = Path(__file__).parents[1] / "b_collect_and_verify_data.csv"

BVAL_FILENAME = "dwis.bval"
BVEC_FILENAME = "dwis.bvec"
DWI_FILENAME = "dwis-dnc.nii.gz"

WM_MIF_TAG = "_FOD_wm_norm.mif"
DWI_MASK_TAG = "_dwi_mask.mif"

WRONG_INITIALS = ["lp", "ltu"]

FOD_PROCESSING_DIR = TEMPORARY_DATA_DIR / "FOD_images"

# %%
# load main data df
sample_data_df = pd.read_csv(SAMPLE_DATA_CSV, sep=";")
sample_data_df = sample_data_df[sample_data_df[Cols.IMAGE_MODALITY] == "FA"]

patient_id_df = pd.read_excel(PATIENT_ID_MAPPING)
# drop invalid initials
patient_id_df = patient_id_df[~patient_id_df["Initials"].isin(WRONG_INITIALS)]
# drop 2 cases for which original fod files were corrupted as documented in
# TEMPORARY_DATA_DIR/FOD_images/fod_failures.tsv
sample_data_df = sample_data_df[
    ~(
        (sample_data_df[Cols.SUBJECT_ID] == "8190")
        & (sample_data_df[Cols.DATE_TAG] == "20190724")
    )
]
sample_data_df = sample_data_df[~(sample_data_df[Cols.SUBJECT_ID] == "MLD112")]


dwi_path_list = []
bval_path_list = []
bvec_path_list = []
bvals_list = []
wm_mif_path_list = []
dwi_mask_path_list = []

# list all potential dwi files
bval_filepaths_list = list(ORIGINAL_DIFFUSION_DATA_DIR.rglob(BVAL_FILENAME))
bvec_filepaths_list = list(ORIGINAL_DIFFUSION_DATA_DIR.rglob(BVEC_FILENAME))
dwi_filepaths_list = list(ORIGINAL_DIFFUSION_DATA_DIR.rglob(DWI_FILENAME))

# list potential mif files, first check that they were processed
wm_mif_filepaths_list = list(FOD_PROCESSING_DIR.rglob(f"*{WM_MIF_TAG}"))
dwi_mask_filepaths_list = list(FOD_PROCESSING_DIR.rglob(f"*{DWI_MASK_TAG}"))


# %%
# helper to extract bvals
def get_shells_from_bval(bval_path: Path, round_to: int = 100) -> list[int]:
    """Extract existing dwi b shell values from a bval file.

    Args:
        bval_path (Path): Path to a bval file.
        round_to (int, optional): Rounding resolution. Defaults to 100.

    Returns:
        list[int]: List of rounded bval values in bval file.

    """
    bvals = np.loadtxt(str(bval_path))
    shells = np.unique(np.round(bvals / round_to) * round_to)
    return shells.astype(int).tolist()


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
        mif_path = find_unique_path(wm_mif_filepaths_list, str(patient_id), date_tag)
        dwi_mask_path = find_unique_path(
            dwi_mask_filepaths_list, str(patient_id), date_tag
        )
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
        mif_path = find_unique_path(wm_mif_filepaths_list, row[Cols.SUBJECT_ID])
        dwi_mask_path = find_unique_path(dwi_mask_filepaths_list, row[Cols.SUBJECT_ID])
    else:
        raise ValueError(f"Invalid subject type {row[Cols.SUBJECT_TYPE]}")

    bval_path_list.append(bval_path)
    bvec_path_list.append(bvec_path)
    dwi_path_list.append(dwi_path)
    wm_mif_path_list.append(mif_path)
    dwi_mask_path_list.append(dwi_mask_path)
    bvals_list.append(get_shells_from_bval(bval_path))

# %%
# assign to df and prepare output
sample_data_df[DWIPathCols.DWI_PATH] = dwi_path_list
sample_data_df[DWIPathCols.BVAL_PATH] = bval_path_list
sample_data_df[DWIPathCols.BVEC_PATH] = bvec_path_list
sample_data_df[DWIPathCols.BVALS] = bvals_list
sample_data_df[DWIPathCols.MIF_PATH] = wm_mif_path_list
sample_data_df[DWIPathCols.DWI_MASK] = dwi_mask_path_list

relevant_cols = [
    Cols.SUBJECT_ID,
    Cols.DATE_TAG,
    Cols.DTI_METHOD,
    DWIPathCols.DWI_PATH,
    DWIPathCols.BVAL_PATH,
    DWIPathCols.BVEC_PATH,
    DWIPathCols.BVALS,
    DWIPathCols.MIF_PATH,
    DWIPathCols.DWI_MASK,
]

output_df = sample_data_df[relevant_cols].copy()

# %%
# store output
outname = Path(__file__).with_suffix(".tsv")
output_df.to_csv(outname, sep="\t", index=False)

# %%
