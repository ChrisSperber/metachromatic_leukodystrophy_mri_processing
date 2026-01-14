"""Path and configs for MLD MRI processing."""

from pathlib import Path

ORIGINAL_DATA_ROOT_DIR = Path(__file__).parents[3] / "mld_data"
TEMPORARY_DATA_DIR = Path(__file__).parents[3] / "temp_images"

ORIGINAL_DIFFUSION_DATA_DIR = ORIGINAL_DATA_ROOT_DIR / "NODDI"
ORIGINAL_MP2RAGE_PATIENTS_DATA_DIR = ORIGINAL_DATA_ROOT_DIR / "patients" / "MP2RAGE"
ORIGINAL_SSFP_PATIENTS_DATA_DIR = ORIGINAL_DATA_ROOT_DIR / "patients" / "ssfp"
ORIGINAL_MP2RAGE_CONTROLS_DATA_DIR = ORIGINAL_DATA_ROOT_DIR / "controls" / "T1_nifti"
ORIGINAL_SSFP_CONTROLS_DATA_DIR = ORIGINAL_DATA_ROOT_DIR / "controls" / "ssfp"
ORIGINAL_DATA_PATIENTS_XLS = ORIGINAL_DATA_ROOT_DIR / "Multispectral_patients.xlsx"
ORIGINAL_DATA_CONTROLS_XLS = ORIGINAL_DATA_ROOT_DIR / "Multispectral_controls.xlsx"
PATIENT_ID_MAPPING = ORIGINAL_DATA_ROOT_DIR / "initial_lookup.xlsx"

MP2RAGE = "MP2RAGE"

FA_COPY_DIR = TEMPORARY_DATA_DIR / "FA_images"
MD_COPY_DIR = TEMPORARY_DATA_DIR / "MD_images"
T1_COPY_DIR = TEMPORARY_DATA_DIR / "T1_images"
SSFP_COPY_DIR = TEMPORARY_DATA_DIR / "SSFP_images"
COPY_FOLDER_DICT = {
    "FA": FA_COPY_DIR,
    "MD": MD_COPY_DIR,
    MP2RAGE: T1_COPY_DIR,
    "SSFP": SSFP_COPY_DIR,
}
T1_SEGMENTED_DIR = TEMPORARY_DATA_DIR / "T1_images_segm"
MTR_OUTPUT_DIR = TEMPORARY_DATA_DIR / "MTR_images"
FOD_OUTPUT_DIR = TEMPORARY_DATA_DIR / "FOD_data"

UNKNOWN = "Unknown"
NOT_APPLICABLE = "Not_applicable"
PATIENT = "patient"
CONTROL = "control"

OUTPUT_METRICS_DIR = Path(__file__).parents[3] / "mld_MRI_output_metrics"

# labels that are to be ignored in the voronoi subparcellation of white matter;
# white mitter itself must also be ignored
WHITE_MATTER = "White_Matter"
CEREBELLUM = "Cerebellum"
BRAINSTEM = "Brainstem"
CSF = "Ventricle_CSF"
NON_REQUIRED_LABEL_STRUCTURES_VORONOI = [WHITE_MATTER, CEREBELLUM, BRAINSTEM, CSF]
