# A Study on Brain MRI Markers in Metachromatic Leukodystrophy - Data Processing

This repository contains the Python and Bash code for a research project analysing various volumetric and DTI-based brain imaging markers in metachromatic leukodystrophy.

> ⚠️ **Note**: This repository does not contain any raw clinical or imaging data.
---

## Repository Contents

| Folder/File                           | Description                                                     |
|---------------------------------------|-----------------------------------------------------------------|
| `scripts/`                            | Main processing and analysis scripts (Python + Bash)            |
| `src/`                                |                                                                 |
| └──`mld_tbss/`                        | Installable Python toolbox (utilities, config paths)            |
| └──`tbss_pipeline/`                   | Legacy TBSS-related configuration (retained for reference)      |
| └──`freesurfer_labelmap_*.xlsx`       | Mapping of segmentation labels to larger brain structures       |
|                                       | (manually generated)                                            |
| `reports/`                            | Environment logs (e.g., Freesurfer, ANTs, FSL versions)         |
| `requirements.txt`                    | Python dependencies (from `venv`)                               |
| `LICENSE`                             | MIT License                                                     |

---

## Reproducing the Analysis

This project was developed and run using Python 3.12.12 in a local `venv` environment in Ubuntu 22.04.5
All dependency versions outside of Python (Freesurfer, ANTs, FSL) are tracked in ./reports
> ⚠️ **Note**: Freesurfer 8.1.0 does **not** run in an Ubuntu OS version >22.x

### 1. Clone the repository
```bash
git clone https://github.com/ChrisSperber/metachromatic_leukodystrophy_mri_processing
cd metachromatic_leukodystrophy_mri_processing
```
### 2. Set up environment
```bash
python -m venv .venv
source .venv/bin/activate
```
### 3. Install dependencies
```bash
pip install -r requirements.txt
# install the local package in editable mode
pip install -e .
```
### 4. Run Analysis

The main analysis scripts are sequentially ordered with alphabetic prefixes. See docstrings for further information.
Scripts with a "xx_" prefix are legacy scripts that are retained to document prior iterations of the workflow. These are not part of the current processing pipeline.

---
## Input data
The repository is intended to reside in the same parent directory as the data folder that contains the original data directory. The original data directory is intended to be called "mld_data" and contains the MRI and NODDI data of controls and patients, excel tables with demographic/clinical data and a lookup table for patient initials.

```bash
<parent>/
├─ mld_data/          # MRI, NODDI, demographic and clinical tables (not included)
└─ metachromatic_leukodystrophy_mri_processing/   # this repository
```

---
## Outputs
### Intermediate Outputs
The code collects relevant imaging data - either by copying existing NIFTIs or by creating them from DICOMs - and demographic/clinical data. Imaging data are stored in a "temp_images" folder. All segmentations and processed/registered images are created in subfolders in "temp_images".
### Final outputs
The final outputs are volumetric segmentation data and connected local FA/MD values stored in long CSVs in an "mld_MRI_output_metrics" folder.

---
### References
TBA

---
### License
This project is licensed under the MIT License — see [Project License](LICENSE) for details.
