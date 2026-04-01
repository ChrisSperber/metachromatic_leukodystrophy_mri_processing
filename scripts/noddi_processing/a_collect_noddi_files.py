"""Collect NODDI files in temp images directory.

Original paths to original NODDI files - ficvf, fiso, odi - are documented and images are copied
into the temporary images folder.

Requirements:
    - The main analysis scripts were succesfully run, specifically the collection of demographic
        data
Outputs:
    - folder of all downstream NODDI outputs - IDO, FISO, FICVF - in temp images folder at
        NODDI_COPY_DIR
"""

# %%

import shutil
from pathlib import Path

import pandas as pd

from mld_tbss.config import (
    CONTROL,
    NODDI_COPY_DIR,
    ORIGINAL_DATA_ROOT_DIR,
    ORIGINAL_DIFFUSION_DATA_DIR,
    PATIENT,
    PATIENT_ID_MAPPING,
)
from mld_tbss.utils import Cols, NODDIPathCols, find_unique_path

SAMPLE_DATA_CSV = Path(__file__).parents[1] / "b_collect_and_verify_data.csv"

NODDI_FICVF_FILENAME = "noddi_ficvf.nii.gz"
NODDI_FISO_FILENAME = "noddi_fiso.nii.gz"
NODDI_ODI_FILENAME = "noddi_odi.nii.gz"

WRONG_INITIALS = ["lp", "ltu"]

# %%
# load main data df
sample_data_df = pd.read_csv(SAMPLE_DATA_CSV, sep=";")
sample_data_df = sample_data_df[sample_data_df[Cols.IMAGE_MODALITY] == "FA"]

patient_id_df = pd.read_excel(PATIENT_ID_MAPPING)
# drop invalid initials
patient_id_df = patient_id_df[~patient_id_df["Initials"].isin(WRONG_INITIALS)]

ficvf_path_list = []
fiso_path_list = []
odi_path_list = []

# list all potential noddi files
ficvf_filepaths_list = list(ORIGINAL_DIFFUSION_DATA_DIR.rglob(NODDI_FICVF_FILENAME))
fiso_filepaths_list = list(ORIGINAL_DIFFUSION_DATA_DIR.rglob(NODDI_FISO_FILENAME))
odi_filepaths_list = list(ORIGINAL_DIFFUSION_DATA_DIR.rglob(NODDI_ODI_FILENAME))

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

        ficvf_path = find_unique_path(
            ficvf_filepaths_list, subjectname_in_path, date_tag
        )
        fiso_path = find_unique_path(fiso_filepaths_list, subjectname_in_path, date_tag)
        odi_path = find_unique_path(odi_filepaths_list, subjectname_in_path, date_tag)
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
        ficvf_path = find_unique_path(ficvf_filepaths_list, subjectname_in_path)
        fiso_path = find_unique_path(fiso_filepaths_list, subjectname_in_path)
        odi_path = find_unique_path(odi_filepaths_list, subjectname_in_path)
    else:
        raise ValueError(f"Invalid subject type {row[Cols.SUBJECT_TYPE]}")

    ficvf_path_list.append(ficvf_path.relative_to(ORIGINAL_DATA_ROOT_DIR))
    fiso_path_list.append(fiso_path.relative_to(ORIGINAL_DATA_ROOT_DIR))
    odi_path_list.append(odi_path.relative_to(ORIGINAL_DATA_ROOT_DIR))

# %%
# assign to df and prepare output
sample_data_df[NODDIPathCols.FICVF_PATH] = ficvf_path_list
sample_data_df[NODDIPathCols.FISO_PATH] = fiso_path_list
sample_data_df[NODDIPathCols.ODI_PATH] = odi_path_list

relevent_cols = [
    Cols.SUBJECT_ID,
    Cols.DATE_TAG,
    Cols.DTI_METHOD,
    NODDIPathCols.FICVF_PATH,
    NODDIPathCols.FISO_PATH,
    NODDIPathCols.ODI_PATH,
]

output_df = sample_data_df[relevent_cols].copy()

# %%
# store output
outname = Path(__file__).with_suffix(".csv")
output_df.to_csv(outname, sep="\t", index=False)

# %%
# copy images
NODDI_COPY_DIR.mkdir(exist_ok=True)

for _, row in sample_data_df.iterrows():
    basename = f"subject_{row[Cols.SUBJECT_ID]}_date_{row[Cols.DATE_TAG]}"
    ficvf_out = NODDI_COPY_DIR / f"{basename}_ficvf.nii.gz"
    fiso_out = NODDI_COPY_DIR / f"{basename}_fiso.nii.gz"
    odi_out = NODDI_COPY_DIR / f"{basename}_odi.nii.gz"

    shutil.copy(ORIGINAL_DATA_ROOT_DIR / row[NODDIPathCols.FICVF_PATH], ficvf_out)
    shutil.copy(ORIGINAL_DATA_ROOT_DIR / row[NODDIPathCols.FISO_PATH], fiso_out)
    shutil.copy(ORIGINAL_DATA_ROOT_DIR / row[NODDIPathCols.ODI_PATH], odi_out)

# %%
