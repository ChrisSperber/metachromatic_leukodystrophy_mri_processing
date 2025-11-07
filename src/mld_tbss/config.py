"""Path and configs for MLD MRI processing."""

from pathlib import Path

ORIGINAL_DATA_ROOT_DIR = Path(__file__).parents[3] / "mld_data"
TEMPORARY_DATA_DIR = Path(__file__).parents[3] / "temp_images"

ORIGINAL_DIFFUSION_DATA_DIR = ORIGINAL_DATA_ROOT_DIR / "NODDI"
ORIGINAL_MP2RAGE_PATIENTS_DATA_DIR = ORIGINAL_DATA_ROOT_DIR / "patients" / "MP2RAGE"
ORIGINAL_MP2RAGE_CONTROLS_DATA_DIR = ORIGINAL_DATA_ROOT_DIR / "controls" / "T1_nifti"
ORIGINAL_DATA_PATIENTS_XLS = ORIGINAL_DATA_ROOT_DIR / "Multispectral_patients.xlsx"
ORIGINAL_DATA_CONTROLS_XLS = ORIGINAL_DATA_ROOT_DIR / "Multispectral_controls.xlsx"
PATIENT_ID_MAPPING = ORIGINAL_DATA_ROOT_DIR / "initial_lookup.xlsx"

MP2RAGE = "MP2RAGE"

FA_COPY_DIR = TEMPORARY_DATA_DIR / "FA_images"
MD_COPY_DIR = TEMPORARY_DATA_DIR / "MD_images"
T1_COPY_DIR = TEMPORARY_DATA_DIR / "T1_images"
COPY_FOLDER_DICT = {
    "FA": FA_COPY_DIR,
    "MD": MD_COPY_DIR,
    MP2RAGE: T1_COPY_DIR,
}
T1_SEGMENTED_DIR = TEMPORARY_DATA_DIR / "T1_images_segm"

UNKNOWN = "Unknown"
NOT_APPLICABLE = "Not_applicable"
PATIENT = "patient"
CONTROL = "control"

OUTPUT_METRICS_DIR = Path(__file__).parents[3] / "mld_MRI_output_metrics"
