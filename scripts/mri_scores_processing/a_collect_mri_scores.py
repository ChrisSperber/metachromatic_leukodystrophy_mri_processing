"""Collect all MRI rating scores.

Collect the subratings underlying the MRIscore.

Output:
- an anonymised csv listing mri scores for all included subjects and sessions
"""

# %%

from pathlib import Path

import pandas as pd

from mld_tbss.config import MP2RAGE, ORIGINAL_DATA_PATIENTS_XLS
from mld_tbss.utils import Cols

SESSION_ID = "Basename"
SAMPLE_DATA_CSV = Path(__file__).parents[1] / "b_collect_and_verify_data.csv"

src_cols2copy = [
    Cols.SUBJECT_ID,
    Cols.DATE_TAG,
    SESSION_ID,
    "frontal_p",
    "frontal_c",
    "frontal_s",
    "parocc_p",
    "parocc_c",
    "parocc_s",
    "temp_p",
    "temp_c",
    "temp_s",
    "cc_genu",
    "cc_splenium",
    "caps_ant",
    "caps_post",
    "pons",
    "atrophy",
    "thal",
    "basganglia",
    "cerebell_wm",
    "cerebell_atr",
]

# %%
# source load patient xls
patient_df = pd.read_excel(
    ORIGINAL_DATA_PATIENTS_XLS,
    sheet_name="MP2RAGE",  # MP2RAGE sheet contains rating scores
    nrows=40,  # rows below contain junk
)

patient_df.rename(columns={"ID": Cols.SUBJECT_ID}, inplace=True)

# derive date tag from filename and create session identifier
patient_df[Cols.DATE_TAG] = patient_df.iloc[:, 0].str.extract(r"(\d{8})")
patient_df[SESSION_ID] = (
    "subject_"
    + patient_df[Cols.SUBJECT_ID].astype(str)
    + "_date_"
    + patient_df[Cols.DATE_TAG].astype(str)
)
patient_df[Cols.SUBJECT_ID] = patient_df[Cols.SUBJECT_ID].astype(str)

patient_df = patient_df[src_cols2copy].copy()

# %%
# integrate into main data df
# load main data df
sample_data_df = pd.read_csv(SAMPLE_DATA_CSV, sep=";")
# drop repeated rows for modalities
sample_data_df = sample_data_df[sample_data_df[Cols.IMAGE_MODALITY] == MP2RAGE]
# drop

sample_data_df = sample_data_df[
    [Cols.SUBJECT_ID, Cols.DATE_TAG, Cols.GMFC, Cols.MRI_SCORE]
].copy()
sample_data_df[SESSION_ID] = (
    "subject_"
    + sample_data_df[Cols.SUBJECT_ID].astype(str)
    + "_date_"
    + sample_data_df[Cols.DATE_TAG].astype(str)
)

merge_cols = [
    Cols.SUBJECT_ID,
    Cols.DATE_TAG,
    SESSION_ID,
]
patient_df = patient_df.merge(right=sample_data_df, how="left", on=merge_cols)

# %%
# drop patient with missing data
patient_df = patient_df[patient_df[Cols.SUBJECT_ID] != "9023"]

# %%
# store outputs
output_name = Path(__file__).with_suffix(".csv")
patient_df.to_csv(output_name, index=False, sep=";")

# %%
