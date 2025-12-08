"""Collect, copy, and verify all SSFP images.

The processing of SSFP images for the derivation of (pesudo-)magnet transfer ratio images was a
secondary aim and was only followed up after the main analysis were finished. Hence, the code lives
in a subfolder putside the main pipeline, but relies on the availability of the main data.
Here, all images are identified, copied into the temporary images folder, and documented.

Requirements:
    - The main analysis scripts were succesfully run, specifically the collection of demographic
        data and the collection and first preprocessing of images

Outputs:
    - a new folder in the temporary images directory containing the included SSFP images
    - a csv listing the files and IDs
"""

# %%
import re
from pathlib import Path

import nibabel as nib
import pandas as pd

from mld_tbss.config import (
    MP2RAGE,
    ORIGINAL_DATA_ROOT_DIR,
    ORIGINAL_SSFP_CONTROLS_DATA_DIR,
    ORIGINAL_SSFP_PATIENTS_DATA_DIR,
    PATIENT_ID_MAPPING,
    SSFP_COPY_DIR,
)
from mld_tbss.utils import Cols

SAMPLE_DATA_CSV = Path(__file__).parents[1] / "b_collect_and_verify_data.csv"

RELEVANT_IMAGE_TAGS_SSFP = ["_ssfp.200.nii", "_ssfp.1500.nii"]
PATIENT_PATH_TAG = "patients"
CONTROLS_PATH_TAG = "controls"

# %%
sample_df = pd.read_csv(SAMPLE_DATA_CSV, sep=";")
# for simplicity, only keep T1 images as reference for included cases
sample_df = sample_df[sample_df[Cols.IMAGE_MODALITY] == MP2RAGE]

patient_id_lookup_table = pd.read_excel(PATIENT_ID_MAPPING)

SSFP_COPY_DIR.mkdir(parents=True, exist_ok=True)

# %%
# list relevant images
# i) SSFP for patients

image_paths_list_ssfp_patients = [
    str(p.relative_to(ORIGINAL_DATA_ROOT_DIR))
    for p in ORIGINAL_SSFP_PATIENTS_DATA_DIR.rglob("*")
    if p.is_file()
    and any(tag in p.name for tag in RELEVANT_IMAGE_TAGS_SSFP)
    and PATIENT_PATH_TAG in p.as_posix()
]
# filter out a mis-labelled image with wrong initials, bad images, and test images
image_paths_list_ssfp_patients = [
    s
    for s in image_paths_list_ssfp_patients
    if "rsa20202401" not in str(s)
    and "Test_spm_coregistration" not in str(s)
    and "sehr_verwackelt"
]

# ii) SSFP for patients
image_paths_list_ssfp_controls = [
    str(p.relative_to(ORIGINAL_DATA_ROOT_DIR))
    for p in ORIGINAL_SSFP_CONTROLS_DATA_DIR.rglob("*")
    if p.is_file() and ".nii.gz" in p.name
]

# %%
# collect and copy data - patients
id_list_patients = []
ssfp_time_list_patients = []
date_tags_list_patients = []
new_image_names_list_patients = []

for path in image_paths_list_ssfp_patients:
    # get ID from initials
    initials = re.search(
        r"/ssfp/([a-zA-Z]+)", path
    ).group(  # pyright: ignore[reportOptionalMemberAccess]
        1
    )

    id = patient_id_lookup_table.loc[
        patient_id_lookup_table["Initials"] == initials, "ID"
    ].iloc[0]
    id_list_patients.append(int(id))

    # get SSFP time
    usecs = path.split(".")[1]
    ssfp_time_list_patients.append(usecs)

    # get date
    date_tag = re.search(
        r"/ssfp/[a-zA-Z]{2,3}(\d+)", path
    ).group(  # pyright: ignore[reportOptionalMemberAccess]
        1
    )
    date_tags_list_patients.append(date_tag)

    # create new image name and copy as .nii.gz with nibabel
    new_image_name = f"subject_{id}_date_{date_tag}_SSFP_{usecs}.nii.gz"
    new_image_names_list_patients.append(new_image_name)

    outpath = SSFP_COPY_DIR / new_image_name
    nifti_path = ORIGINAL_DATA_ROOT_DIR / path

    img = nib.load(nifti_path)  # pyright: ignore[reportPrivateImportUsage]
    nib.save(img, outpath)  # pyright: ignore[reportPrivateImportUsage]


# %%
# collect and copy data - controls
# controls have multiple images each. The last 200μs and 1500μs image each session is taken
id_list_controls = []
ssfp_time_list_controls = []
new_image_names_list_controls = []


# %%
# clean data created in controls folder

# %%
