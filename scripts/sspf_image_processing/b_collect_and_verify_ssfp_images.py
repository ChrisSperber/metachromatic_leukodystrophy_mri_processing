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
import shutil
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
    UNKNOWN,
)
from mld_tbss.utils import Cols

SAMPLE_DATA_CSV = Path(__file__).parents[1] / "b_collect_and_verify_data.csv"

RELEVANT_IMAGE_TAGS_SSFP = ["_ssfp.200.nii", "_ssfp.1500.nii"]
PATIENT_PATH_TAG = "patients"
CONTROLS_PATH_TAG = "controls"

SSFP_TIME = "SSFP_time"

# patients without T1 cannot be included in the main pipeline and are removed
SFFP_WITH_MISSING_T1 = [8005, 8113, 8185, 8189, 8090, 8136, 8155]
# Note: IDs 8161 and 8190 are handled separately session-wise
ID_8161_SESSIONS_MISSING_T1 = ["20140627", "20151124"]
ID_8190_SESSIONS_MISSING_T1 = ["20131115", "20140930", "20150429"]

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

    # skip if patient with missing T1
    if id in SFFP_WITH_MISSING_T1:
        continue
    if id == 8161:  # noqa: PLR2004
        date_tag = re.search(
            r"/ssfp/[a-zA-Z]{2,3}(\d+)", path
        ).group(  # pyright: ignore[reportOptionalMemberAccess]
            1
        )
        if date_tag in ID_8161_SESSIONS_MISSING_T1:
            continue
    if id == 8190:  # noqa: PLR2004
        date_tag = re.search(
            r"/ssfp/[a-zA-Z]{2,3}(\d+)", path
        ).group(  # pyright: ignore[reportOptionalMemberAccess]
            1
        )
        if date_tag in ID_8190_SESSIONS_MISSING_T1:
            continue

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

patients_data_df = pd.DataFrame(
    {
        Cols.SUBJECT_ID: id_list_patients,
        Cols.DATE_TAG: date_tags_list_patients,
        Cols.FILENAME: new_image_names_list_patients,
        SSFP_TIME: ssfp_time_list_patients,
    }
)


# %%
# collect and copy data - controls
# controls have multiple images each. The last 200μs and 1500μs image each session is taken
id_list_controls = []
ssfp_time_list_controls = []
new_image_names_list_controls = []
running_number_list_controls = []
date_tags_list_controls = []

for path in image_paths_list_ssfp_controls:
    # get ID from initials
    id = path.split("/")[2]
    id = id.replace("_", "")  # remove underscore from special case
    id_list_controls.append(id)
    # date tag is set to Unknown for consistency
    date_tag = UNKNOWN
    date_tags_list_controls.append(date_tag)
    # get SSFP time
    filename = path.split("/")[-1]
    if "200" in filename:
        usecs = 200
    elif "1500" in filename:
        usecs = 1500
    else:
        msg = f"No SSFP usecs can be derived from {path}"
        raise ValueError(msg)
    ssfp_time_list_controls.append(usecs)
    # get session running number to infer order
    running_number = re.search(r"_(\d{1,2})\.nii\.gz$", path).group(1)  # type: ignore
    running_number_list_controls.append(running_number)
    # create new image name (without copying at this point)
    new_image_name = f"subject_{id}_date_{date_tag}_SSFP_{usecs}.nii.gz"
    new_image_names_list_controls.append(new_image_name)

# select relevant controls' images
controls_data_df = pd.DataFrame(
    {
        Cols.SUBJECT_ID: id_list_controls,
        Cols.DATE_TAG: date_tags_list_controls,
        Cols.FILENAME: new_image_names_list_controls,
        "Running_number": running_number_list_controls,
        SSFP_TIME: ssfp_time_list_controls,
        "Original_image_path": image_paths_list_ssfp_controls,
    }
)
# remove erroneous/duplciated data
controls_data_df = controls_data_df[
    controls_data_df[Cols.SUBJECT_ID] != "MLD119prisma71"
]
# remove case with severe imaging artefacts
controls_data_df = controls_data_df[controls_data_df[Cols.SUBJECT_ID] != "MLD111"]

# drop unique ID/SSFP_time combinations that do not have the maximum running number
controls_data_df = (
    controls_data_df.sort_values([Cols.SUBJECT_ID, SSFP_TIME, "Running_number"])
    .drop_duplicates(subset=[Cols.SUBJECT_ID, SSFP_TIME], keep="last")
    .reset_index(drop=True)
)

# %%
# copy relevant controls' images
for _, row in controls_data_df.iterrows():
    src = ORIGINAL_DATA_ROOT_DIR / row["Original_image_path"]
    dst = SSFP_COPY_DIR / row[Cols.FILENAME]
    shutil.copy(src, dst)

# %%
# merge and store data dfs
controls_data_df = controls_data_df.drop(
    columns=["Running_number", "Original_image_path"]
)
if not controls_data_df.columns.equals(patients_data_df.columns):
    raise ValueError("Column mismatch between DataFrames")

data_df = pd.concat([patients_data_df, controls_data_df], ignore_index=True)

output_name = Path(__file__).with_suffix(".csv")
data_df.to_csv(output_name, index=False, sep=";")

# %%
# clean data created in controls folder
# files created by a_convert_dicom_ssfp.sh within the original data folder are removed again
for path in image_paths_list_ssfp_controls:
    nifti = ORIGINAL_DATA_ROOT_DIR / path
    json = ORIGINAL_DATA_ROOT_DIR / path.replace(".nii.gz", ".json")
    nifti.unlink()
    json.unlink()

# %%
