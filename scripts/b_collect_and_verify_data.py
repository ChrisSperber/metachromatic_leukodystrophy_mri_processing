"""Collect, copy, and verify all relevant diffusion data.

Additionally, MP2RAGE T1 images required for normalisation are collected.
Only patients with all images available are included. Both patients and healthy controls are
included.

Output:
- an anonymised csv listing all included subjects and sessions including various demographics
"""

# %%
import re
import shutil
from pathlib import Path

import nibabel as nib
import numpy as np
import pandas as pd

from mld_tbss.config import (
    CONTROL,
    COPY_FOLDER_DICT,
    MP2RAGE,
    NOT_APPLICABLE,
    ORIGINAL_DATA_CONTROLS_XLS,
    ORIGINAL_DATA_PATIENTS_XLS,
    ORIGINAL_DATA_ROOT_DIR,
    ORIGINAL_DIFFUSION_DATA_DIR,
    ORIGINAL_MP2RAGE_CONTROLS_DATA_DIR,
    ORIGINAL_MP2RAGE_PATIENTS_DATA_DIR,
    PATIENT,
    PATIENT_ID_MAPPING,
    TEMPORARY_DATA_DIR,
    UNKNOWN,
)
from mld_tbss.utils import (
    Cols,
    get_unique_row,
)

RELEVANT_IMAGE_TAGS_DTI = ["dti_FA", "dti_MD"]
RELEVANT_IMAGE_TAGS_T1_PATIENTS = ["MP2.MP2"]
PATIENT_PATH_TAG = "patients"
CONTROLS_PATH_TAG = "controls"

WRONG_IDS_TO_REMOVE = ["ltu/20200114", "lp/20160715", "lp/20140627"]
WRONG_IDS_TO_REMOVE_T1 = ["lp20160715"]
CONTROL_NUMID_WITH_TWO_SESSIONS = 119
CONTROL_NUMID_WITH_MISSING_METADATA = 199

IMAGE_PATH_ORIGINAL = "Image_Path_Orig"
MALE = "Male"
FEMALE = "Female"

REQUIRED_MODALITIES = ["FA", "MD", MP2RAGE]

SHEET_NAME_PATIENT_XLS = "DTI_multishell"
SHEET_NAME_PATIENT_XLS_ALL_DATA = "all_selected"

# FA data were found to include values >1 (in the range of up to ~1.2). They likely originate from
# preprocessing and are clipped at 1. Here, a threshold is set below which values are acceptable
MAX_ACCEPTABLE_FA_VAL = 1.25

# %%
# list relevant images and fetch metadata from file path I
# i) DTI for patients

image_paths_list_dti_patients = [
    str(p.relative_to(ORIGINAL_DATA_ROOT_DIR))
    for p in ORIGINAL_DIFFUSION_DATA_DIR.rglob("*")
    if p.is_file()
    and any(tag in p.name for tag in RELEVANT_IMAGE_TAGS_DTI)
    and PATIENT_PATH_TAG in p.as_posix()
]

# remove duplicate patients with wrong ID
image_paths_list_dti_patients = [
    str(p)
    for p in map(Path, image_paths_list_dti_patients)
    if not any(ex in p.as_posix() for ex in WRONG_IDS_TO_REMOVE)
]

patient_id_lookup_table = pd.read_excel(PATIENT_ID_MAPPING)

ids = []
date_tags = []
dti_methods = []
image_modalities = []
new_filenames = []
subject_types = []
orig_paths = []

for path in image_paths_list_dti_patients:
    orig_paths.append(path)

    initial = path.split("/")[3]
    lookup_row = get_unique_row(patient_id_lookup_table, "Initials", initial)
    ids.append(lookup_row["ID"])

    method_tag = path.split("/")[2]
    dti_methods.append(method_tag)

    date_tag = path.split("/")[4]
    date_tags.append(date_tag)

    modality = Path(path).stem.split("_")[1].replace(".nii", "")
    image_modalities.append(modality)

    new_filename = f"subject_{lookup_row["ID"]}_date_{date_tag}_{modality}.nii.gz"
    new_filenames.append(new_filename)

    subject_types.append(PATIENT)


# %%
# list relevant images and fetch metadata from file path II
# ii) DTI for controls
image_paths_list_dti_controls = [
    str(p.relative_to(ORIGINAL_DATA_ROOT_DIR))
    for p in ORIGINAL_DIFFUSION_DATA_DIR.rglob("*")
    if p.is_file()
    and any(tag in p.name for tag in RELEVANT_IMAGE_TAGS_DTI)
    and CONTROLS_PATH_TAG in p.as_posix()
]

for path in image_paths_list_dti_controls:
    orig_paths.append(path)

    id = path.split("/")[3]
    # handle single subject with images from two scanners
    if id == "MLD119":
        if "prisma" in path:
            id = "MLD119prisma"
        elif "skyra" in path:
            id = "MLD119skyra"
        else:
            msg = "Error handling subject MLD119"
            raise ValueError(msg)

    ids.append(id)

    method_tag = path.split("/")[2]
    dti_methods.append(method_tag)

    date_tag = UNKNOWN
    date_tags.append(date_tag)

    modality = Path(path).stem.split("_")[1].replace(".nii", "")
    image_modalities.append(modality)

    new_filename = f"subject_{id}_date_{date_tag}_{modality}.nii.gz"
    new_filenames.append(new_filename)

    subject_types.append(CONTROL)

# %%
# list relevant images and fetch metadata from file path III
# iii) MPRAGE T1 for patients

image_paths_list_t1_patients = [
    str(p.relative_to(ORIGINAL_DATA_ROOT_DIR))
    for p in ORIGINAL_MP2RAGE_PATIENTS_DATA_DIR.rglob("*")
    if p.is_file() and any(tag in p.name for tag in RELEVANT_IMAGE_TAGS_T1_PATIENTS)
]
# remove duplicate patients with wrong ID
image_paths_list_t1_patients = [
    str(p)
    for p in map(Path, image_paths_list_t1_patients)
    if not any(ex in p.as_posix() for ex in WRONG_IDS_TO_REMOVE_T1)
]

for path in image_paths_list_t1_patients:
    orig_paths.append(path)
    old_filename = Path(path).stem

    match = re.match(r"^([A-Za-z]{2,3})(\d{8})", old_filename)
    initial = match.group(1) if match else UNKNOWN
    lookup_row = get_unique_row(patient_id_lookup_table, "Initials", initial)
    ids.append(lookup_row["ID"])

    method_tag = NOT_APPLICABLE
    dti_methods.append(method_tag)

    date_tag = match.group(2) if match else UNKNOWN
    date_tags.append(date_tag)

    modality = MP2RAGE
    image_modalities.append(modality)

    new_filename = f"subject_{lookup_row["ID"]}_date_{date_tag}_{modality}.nii.gz"
    new_filenames.append(new_filename)

    subject_types.append(PATIENT)

# %%
# list relevant images and fetch metadata from file path IV
# iv) MPRAGE T1 for controls
image_paths_list_t1_controls = [
    str(p.relative_to(ORIGINAL_DATA_ROOT_DIR))
    for p in ORIGINAL_MP2RAGE_CONTROLS_DATA_DIR.rglob("*")
    if p.is_file() and ".nii.gz" in p.name
]

for path in image_paths_list_t1_controls:
    orig_paths.append(path)

    old_filename = Path(path).stem
    id = old_filename.split("_")[0]
    # handle single subject with images from two scanners
    if id == "MLD119":
        if "prisma" in path:
            id = "MLD119prisma"
        elif "skyra" in path:
            id = "MLD119skyra"
        else:
            msg = "Error handling subject MLD119"
            raise ValueError(msg)

    ids.append(id)

    method_tag = NOT_APPLICABLE
    dti_methods.append(method_tag)

    date_tag = UNKNOWN
    date_tags.append(date_tag)

    modality = MP2RAGE
    image_modalities.append(modality)

    new_filename = f"subject_{id}_date_{date_tag}_{modality}.nii.gz"
    new_filenames.append(new_filename)

    subject_types.append(CONTROL)

# %%
# create df from collected data and verify data
data_df = pd.DataFrame(
    {
        Cols.SUBJECT_ID: ids,
        Cols.DATE_TAG: date_tags,
        Cols.DTI_METHOD: dti_methods,
        Cols.IMAGE_MODALITY: image_modalities,
        IMAGE_PATH_ORIGINAL: orig_paths,
        Cols.FILENAME: new_filenames,
        Cols.SUBJECT_TYPE: subject_types,
    }
)

# verify data - each subject needs to have 5 different images available
ct_all = pd.crosstab(
    index=[data_df[Cols.SUBJECT_ID], data_df[Cols.DATE_TAG]],
    columns=data_df[Cols.IMAGE_MODALITY],
)

## identify possible duplicates and raise exception
# Identify rows with any value > 1
invalid_rows = ct_all[ct_all[REQUIRED_MODALITIES].gt(1).any(axis=1)]
if not invalid_rows.empty:
    raise ValueError("Found rows with duplicate (>1) modality counts.")
else:
    print("No rows with duplicate (>1) modality counts found, moving on.")

## remove subjects with missing images
missing_mask = ct_all[REQUIRED_MODALITIES].eq(0).any(axis=1)
missing_cases = ct_all.reset_index().loc[
    missing_mask.to_numpy(), [Cols.SUBJECT_ID, Cols.DATE_TAG]
]
print(
    f"WARNING: Removing {len(missing_cases)} sessions due to partially missing images."
)

mask_to_drop = (
    data_df[[Cols.SUBJECT_ID, Cols.DATE_TAG]]
    .apply(tuple, axis=1)
    .isin(missing_cases[[Cols.SUBJECT_ID, Cols.DATE_TAG]].apply(tuple, axis=1))
)

data_df_clean = data_df.loc[~mask_to_drop].copy()

# %%
# verify image format and copy into temporary data folder
# some images were found to be corrupted after file transfer. Here, all images are checked to be
# readable to verify integrity.
data_df_clean["Image_Shape"] = pd.Series(dtype="str")

for path in COPY_FOLDER_DICT.values():
    path.mkdir(parents=True, exist_ok=True)

for index, row in data_df_clean.iterrows():
    img_path = ORIGINAL_DATA_ROOT_DIR / row[IMAGE_PATH_ORIGINAL]
    img = nib.load(img_path)  # pyright: ignore[reportPrivateImportUsage]

    if not isinstance(img, (nib.nifti1.Nifti1Image)):
        raise TypeError(f"Expected NIfTI, got {type(img).__name__}")
    nifti: nib.nifti1.Nifti1Image = img
    if not nifti.shape:
        msg = f"Shape cannot be read for {row[IMAGE_PATH_ORIGINAL]}"
        raise ValueError(msg)

    data_df_clean.loc[index, "Image_Shape"] = str(nifti.shape)  # type: ignore
    data_df_clean.loc[index, "Image_Dtype"] = np.dtype(img.get_data_dtype()).name  # type: ignore

    # Try lazily reading elements from image
    dataobj = img.dataobj
    mid = tuple(s // 2 for s in nifti.shape) if nifti.shape else ()
    # Verify that a value can be read from the image
    voxelvalue = np.asanyarray(dataobj[mid])

    # If array, check if any value is NaN
    if isinstance(voxelvalue, np.ndarray):
        if np.any(np.isnan(voxelvalue)):
            msg = f"Invalid voxel value for {row[IMAGE_PATH_ORIGINAL]}: contains NaN values"
            raise ValueError(msg)
    # If scalar, check if it's a float and not NaN
    elif isinstance(voxelvalue, float):
        if np.isnan(voxelvalue):
            msg = f"Invalid voxel value for {row[IMAGE_PATH_ORIGINAL]}: NaN"
            raise ValueError(msg)
    else:
        msg = f"Invalid voxel value for {row[IMAGE_PATH_ORIGINAL]}: not a float or ndarray"
        raise ValueError(msg)

    # check data range of FA data
    if row[Cols.IMAGE_MODALITY] == "FA":
        data = nifti.get_fdata()
        vmin, vmax = data.min(), data.max()
        if vmin < 0 or vmax > MAX_ACCEPTABLE_FA_VAL:
            msg = f"Invalid values found for FA map {row[IMAGE_PATH_ORIGINAL]}"
            raise ValueError(msg)

    # copy files into temporary data folder
    target_dir = COPY_FOLDER_DICT[row[Cols.IMAGE_MODALITY]]
    target_file = target_dir / row[Cols.FILENAME]
    orig_file = ORIGINAL_DATA_ROOT_DIR / row[IMAGE_PATH_ORIGINAL]

    # clip FA values >1
    if row[Cols.IMAGE_MODALITY] == "FA":
        # load FA image
        img = nib.load(orig_file)  # pyright: ignore[reportPrivateImportUsage]

        if not isinstance(img, (nib.nifti1.Nifti1Image)):
            raise TypeError(f"Expected NIfTI, got {type(img).__name__}")
        nifti: nib.nifti1.Nifti1Image = img

        data = nifti.get_fdata(dtype=np.float32)
        # clip values >1 to 1
        data = np.clip(data, 0, 1)

        clipped_img = nib.Nifti1Image(  # pyright: ignore[reportPrivateImportUsage]
            data, nifti.affine, nifti.header
        )
        nib.save(clipped_img, target_file)  # pyright: ignore[reportPrivateImportUsage]
    else:
        shutil.copy2(orig_file, target_file)


# %%
# merge data df with original data tables
# fetch age in years, scanning sequence, GMFC, Pathology-Type(Form), Sex, Therapy, MRI Score
ROWS_TO_READ = 60
print(
    f"Warning! The script only read {ROWS_TO_READ} rows in Sheet {SHEET_NAME_PATIENT_XLS}."
    " Verify manually that the relevant part of the xls is covered!"
)

patient_metadata_df = pd.read_excel(
    ORIGINAL_DATA_PATIENTS_XLS,
    sheet_name=SHEET_NAME_PATIENT_XLS,
    nrows=ROWS_TO_READ,
    header=0,
)

patient_metadata_df_w_mriscore = pd.read_excel(
    ORIGINAL_DATA_PATIENTS_XLS,
    sheet_name=SHEET_NAME_PATIENT_XLS_ALL_DATA,
    nrows=64,
    header=0,
)

control_metadata_df = pd.read_excel(
    ORIGINAL_DATA_CONTROLS_XLS,
    header=0,
)


# extract only digit sequences from unnamed column 0
patient_metadata_df[Cols.DATE_TAG] = (
    patient_metadata_df["Unnamed: 0"].astype(str).str.extract(r"(\d+)")
)
patient_metadata_df_w_mriscore[Cols.DATE_TAG] = (
    patient_metadata_df_w_mriscore["Unnamed: 0"].astype(str).str.extract(r"(\d+)")
)

for index, row in data_df_clean.iterrows():
    ### fetch data for patients
    if row[Cols.SUBJECT_TYPE] == PATIENT:
        date_tag = row[Cols.DATE_TAG]
        sid = row[Cols.SUBJECT_ID]

        mask = (patient_metadata_df["ID"] == sid) & (
            patient_metadata_df[Cols.DATE_TAG] == date_tag
        )
        match = patient_metadata_df.loc[mask]

        if len(match) != 1:
            raise ValueError(
                f"Expected exactly 1 row for patient {sid} {date_tag}, found {len(match)}"
            )
        relevant_row = match.squeeze()

        data_df_clean.loc[index, Cols.AGE] = relevant_row["Age at scan [Jahren]"]  # type: ignore
        data_df_clean.loc[index, Cols.GMFC] = relevant_row["GMFC"]  # type: ignore
        data_df_clean.loc[index, Cols.THERAPY] = relevant_row["Therapie"]  # type: ignore
        data_df_clean.loc[index, Cols.PATHOLOGY_TYPE] = relevant_row["Form"]  # type: ignore

        if relevant_row["Geschlecht"] == "w":
            data_df_clean.loc[index, Cols.SEX] = FEMALE  # type: ignore
        elif relevant_row["Geschlecht"] == "m":
            data_df_clean.loc[index, Cols.SEX] = MALE  # type: ignore
        else:
            msg = f"Unknown Sex in {relevant_row}"
            raise ValueError(msg)

        # MRI Score is only available in another sheet
        mask = (patient_metadata_df_w_mriscore["ID"] == sid) & (
            patient_metadata_df_w_mriscore[Cols.DATE_TAG] == date_tag
        )
        match = patient_metadata_df_w_mriscore.loc[mask]

        if len(match) > 1:
            raise ValueError(
                f"All_data: Expected exactly 1 row for patient {sid} {date_tag}, found {len(match)}"
            )
        elif len(match) == 0:
            data_df_clean.loc[index, Cols.MRI_SCORE] = UNKNOWN  # type: ignore
            print(f"Warning: no MRI Score found for patient {sid} {date_tag}")
        else:
            relevant_row = match.squeeze()
            data_df_clean.loc[index, Cols.MRI_SCORE] = relevant_row["MLD-MRI-Score"]  # type: ignore

    ### fetch data for controls
    elif row[Cols.SUBJECT_TYPE] == CONTROL:
        match = re.search(r"\d{3}", row[Cols.SUBJECT_ID])
        if match:
            control_sid_numeric = match.group()
        else:
            msg = f"No patient ID could be extracted for {row}"
            raise ValueError(msg)
        control_sid_numeric = int(control_sid_numeric)

        relevant_row = control_metadata_df[
            control_metadata_df["study-ID"] == control_sid_numeric
        ].reset_index(drop=True)
        # ensure that exactly one row in the table matches the subject;
        # handle special case MLD119 with two sessions with the same metadata
        # and special case MLD199 without metadata
        if len(relevant_row) == 1:
            pass
        elif control_sid_numeric == CONTROL_NUMID_WITH_TWO_SESSIONS:
            relevant_row = relevant_row.iloc[:1]
        elif control_sid_numeric == CONTROL_NUMID_WITH_MISSING_METADATA:
            data_df_clean.loc[index, Cols.AGE] = UNKNOWN  # type: ignore
            data_df_clean.loc[index, Cols.GMFC] = 0  # type: ignore
            data_df_clean.loc[index, Cols.THERAPY] = NOT_APPLICABLE  # type: ignore
            data_df_clean.loc[index, Cols.PATHOLOGY_TYPE] = NOT_APPLICABLE  # type: ignore
            data_df_clean.loc[index, Cols.MRI_SCORE] = 0  # type: ignore
            data_df_clean.loc[index, Cols.SEX] = UNKNOWN  # type: ignore
            continue
        else:
            msg = (
                f"Control {control_sid_numeric} has {len(relevant_row)} entries in csv."
            )
            raise ValueError(msg)

        if relevant_row.loc[0, "gender"] == 1:
            data_df_clean.loc[index, Cols.SEX] = FEMALE  # type: ignore
        elif relevant_row.loc[0, "gender"] == 0:
            data_df_clean.loc[index, Cols.SEX] = MALE  # type: ignore
        else:
            msg = f"Unknown Gender {relevant_row["gender"]}"
            raise ValueError()

        data_df_clean.loc[index, Cols.AGE] = relevant_row.loc[0, "age"]  # type: ignore
        data_df_clean.loc[index, Cols.GMFC] = 0  # type: ignore
        data_df_clean.loc[index, Cols.THERAPY] = NOT_APPLICABLE  # type: ignore
        data_df_clean.loc[index, Cols.PATHOLOGY_TYPE] = NOT_APPLICABLE  # type: ignore
        data_df_clean.loc[index, Cols.MRI_SCORE] = 0  # type: ignore

    else:
        msg = f"Invalid subject type for {row}"
        raise ValueError(msg)

# %%
# format df columns
# round age to two decimals
data_df_clean[Cols.AGE] = data_df_clean[Cols.AGE].apply(
    lambda x: round(x, 2) if isinstance(x, float) else x
)

# convert float
cols_to_convert2int = [Cols.THERAPY, Cols.GMFC, Cols.PATHOLOGY_TYPE]
for col in cols_to_convert2int:
    data_df_clean[col] = data_df_clean[col].apply(
        lambda x: int(x) if isinstance(x, float) else x
    )

# %%
# drop original image path with confidential information from table
data_df_clean_redacted = data_df_clean.drop(IMAGE_PATH_ORIGINAL, axis=1)

# %%
# store data in repo for documentation
output_name = Path(__file__).with_suffix(".csv")
data_df_clean_redacted.to_csv(output_name, index=False, sep=";")

# %%
# store full data in temp images folder for follow up projects
output_name = TEMPORARY_DATA_DIR / "full_dti_datasets_pats_controls.csv"
data_df_clean.to_csv(output_name, index=False, sep=";")

# %%
