"""Collect, copy, and verify all relevant diffusion data."""

# %%
import shutil
from pathlib import Path

import nibabel as nib
import numpy as np
import pandas as pd

from mld_tbss.config import (
    COPY_FOLDER_DICT,
    ORIGINAL_DATA_PATIENTS_XLS,
    ORIGINAL_DIFFUSION_DATA_DIR,
    PATIENT_ID_MAPPING,
)
from mld_tbss.utils import (
    Cols,
    get_unique_row,
)

RELEVANT_IMAGE_TAGS = ["dti_FA", "dti_MD", "dti_MO", "dti_S0"]
PATIENT_TAG = "patients"
UNKNOWN = "Unknown"

WRONG_IDS_TO_REMOVE = ["ltu/20200114", "lp/20160715", "lp/20140627"]

IMAGE_PATH_ORIGINAL = "Image_Path_Orig"

SHEET_NAME_PATIENT_XLS = "DTI_multishell"
SHEET_NAME_PATIENT_XLS_ALL_DATA = "all_selected"

# FA data were found to include values >1 (in the range of up to ~1.2). They likely originate from
# preprocessing and are clipped at 1. Here, a threshold is set below which values are acceptable
MAX_ACCEPTABLE_FA_VAL = 1.25

# %%
# list relevant images and fetch metadata from file path

image_paths_list = [
    str(p.relative_to(ORIGINAL_DIFFUSION_DATA_DIR))
    for p in ORIGINAL_DIFFUSION_DATA_DIR.rglob("*")
    if p.is_file()
    and any(tag in p.name for tag in RELEVANT_IMAGE_TAGS)
    and PATIENT_TAG in p.as_posix()
]

# remove duplicate patients with wrong ID
image_paths_list = [
    str(p)
    for p in map(Path, image_paths_list)
    if not any(ex in p.as_posix() for ex in WRONG_IDS_TO_REMOVE)
]

patient_id_lookup_table = pd.read_excel(PATIENT_ID_MAPPING)

ids = []
date_tags = []
dti_methods = []
image_modalities = []
new_filenames = []

for path in image_paths_list:
    initial = path.split("/")[2]
    lookup_row = get_unique_row(patient_id_lookup_table, "Initials", initial)
    ids.append(lookup_row["ID"])

    method_tag = path.split("/")[1]
    dti_methods.append(method_tag)

    date_tag = path.split("/")[3]
    date_tags.append(date_tag)

    modality = Path(path).stem.split("_")[1].replace(".nii", "")
    image_modalities.append(modality)

    new_filename = f"subject_{lookup_row["ID"]}_{date_tag}_{modality}.nii.gz"
    new_filenames.append(new_filename)


data_df = pd.DataFrame(
    {
        Cols.SUBJECT_ID: ids,
        Cols.DATE_TAG: date_tags,
        Cols.DTI_METHOD: dti_methods,
        Cols.IMAGE_MODALITY: image_modalities,
        IMAGE_PATH_ORIGINAL: image_paths_list,
        Cols.FILENAME: new_filenames,
    }
)

# %%
# verify image format and copy into temporary data folder
# some images were found to be corrupted after file transfer. Here, all images are checked to be
# readable to verify integrity.
data_df["Image_Shape"] = pd.Series(dtype="str")

# Ensure all copy target directories exist
for path in COPY_FOLDER_DICT.values():
    path.mkdir(parents=True, exist_ok=True)

for index, row in data_df.iterrows():
    img_path = ORIGINAL_DIFFUSION_DATA_DIR / row[IMAGE_PATH_ORIGINAL]
    img = nib.load(img_path)

    if not isinstance(img, (nib.nifti1.Nifti1Image)):
        raise TypeError(f"Expected NIfTI, got {type(img).__name__}")
    nifti: nib.nifti1.Nifti1Image = img
    if not nifti.shape:
        msg = f"Shape cannot be read for {row[IMAGE_PATH_ORIGINAL]}"
        raise ValueError(msg)

    data_df.loc[index, "Image_Shape"] = str(nifti.shape)  # type: ignore
    data_df.loc[index, "Image_Dtype"] = np.dtype(img.get_data_dtype()).name  # type: ignore

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
    # check data range of MO data
    if row[Cols.IMAGE_MODALITY] == "MO":
        data = nifti.get_fdata()
        vmin, vmax = data.min(), data.max()
        if vmin < -1 or vmax > 1:
            msg = f"Invalid values found for MO map {row[IMAGE_PATH_ORIGINAL]}"
            raise ValueError(msg)

    # copy files into temporary data folder
    target_dir = COPY_FOLDER_DICT[row[Cols.IMAGE_MODALITY]]
    target_file = target_dir / row[Cols.FILENAME]
    orig_file = ORIGINAL_DIFFUSION_DATA_DIR / row[IMAGE_PATH_ORIGINAL]

    if row[Cols.IMAGE_MODALITY] == "FA":
        # load FA image
        img = nib.load(orig_file)

        if not isinstance(img, (nib.nifti1.Nifti1Image)):
            raise TypeError(f"Expected NIfTI, got {type(img).__name__}")
        nifti: nib.nifti1.Nifti1Image = img

        data = nifti.get_fdata(dtype=np.float32)
        # clip values >1 to 1
        data = np.clip(data, 0, 1)

        clipped_img = nib.Nifti1Image(data, nifti.affine, nifti.header)
        nib.save(clipped_img, target_file)

    else:
        shutil.copy2(orig_file, target_file)


# %%
# merge data df with original data table
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


# extract only digit sequences from unnamed column 0
patient_metadata_df[Cols.DATE_TAG] = (
    patient_metadata_df["Unnamed: 0"].astype(str).str.extract(r"(\d+)")
)
patient_metadata_df_w_mriscore[Cols.DATE_TAG] = (
    patient_metadata_df_w_mriscore["Unnamed: 0"].astype(str).str.extract(r"(\d+)")
)

for index, row in data_df.iterrows():
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

    data_df.loc[index, Cols.AGE] = relevant_row["Age at scan [Jahren]"]  # type: ignore
    data_df.loc[index, Cols.SEX] = relevant_row["Geschlecht"]  # type: ignore
    data_df.loc[index, Cols.GMFC] = relevant_row["GMFC"]  # type: ignore
    data_df.loc[index, Cols.THERAPY] = relevant_row["Therapie"]  # type: ignore
    data_df.loc[index, Cols.PATHOLOGY_TYPE] = relevant_row["Form"]  # type: ignore

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
        data_df.loc[index, Cols.MRI_SCORE] = UNKNOWN  # type: ignore
        print(f"Warning: no MRI Score found for patient {sid} {date_tag}")
    else:
        relevant_row = match.squeeze()
        data_df.loc[index, Cols.MRI_SCORE] = relevant_row["MLD-MRI-Score"]  # type: ignore

# %%
# drop original image path with confidential information from table
data_df = data_df.drop(IMAGE_PATH_ORIGINAL, axis=1)

# %%
# store data
output_name = Path(__file__).with_suffix(".csv")
data_df.to_csv(output_name, index=False, sep=";")

# %%
