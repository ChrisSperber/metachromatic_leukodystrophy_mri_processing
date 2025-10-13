"""Utility functions and constants for MLD TBSS project."""

from dataclasses import dataclass

import pandas as pd


@dataclass(frozen=True)
class Cols:
    """Data column names."""

    FILENAME: str = "Filename"
    AGE: str = "Age"
    SEX: str = "Sex"
    GMFC: str = "GMFC"
    PATHOLOGY_TYPE: str = "Pathology_Type"
    THERAPY: str = "Therapy"
    MRI_SCORE: str = "MRI_Score"
    SUBJECT_ID: str = "Subject_ID"
    DATE_TAG: str = "Date_Tag"
    IMAGE_MODALITY: str = "Image_Modality"
    DTI_METHOD: str = "DTI_Method"
    SUBJECT_TYPE: str = "Subject_Type"  # Column name for patient/control tag


def get_unique_row(df: pd.DataFrame, column: str, substring: str) -> pd.Series:
    """Get values of a row identified by an uid.

    Args:
        df: Dataframe
        column: Colname
        substring: String to search

    Raises:
        ValueError: substring cannot be found
        ValueError: substring appears multiple times

    Returns:
        Series: df row as Series

    """
    mask = df[column].str.contains(substring, regex=False)
    matches = df[mask]

    if len(matches) == 0:
        raise ValueError(f"No row contains '{substring}' in column '{column}'")
    elif len(matches) > 1:
        raise ValueError(
            f"Multiple rows contain '{substring}' in column '{column}': {matches.index.tolist()}"
        )
    else:
        return matches.squeeze()  # type: ignore # converts 1-row DataFrame → Series
