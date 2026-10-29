"""Derive NODDI images via amico python tool.

Intermediate/temporary files are only created in the noddi_temp folder

Output:
- a new derivatives/diffusion/sub-SubjectID/ses-SessionID/noddi folder with NIFTIs for
    NDI (formerly ICVF): Neurite density index
    ODI: Orientation dispersion index
    FWF (formerly FISO): Free-water fraction

Requirements: DWI/Mask .mif files in the BIDS folder were converted into NIFTI files in the
    temporary mld_data_master_2026/derivatives/noddi_temp folder via
    convert_mif2nifti_for_noddi_proc.sh
"""

# %%
# Imports and configuration

import shutil
import time

import amico
import pandas as pd
from amico.util import fsl2scheme

from mld_tbss.config import ORIGINAL_PROJECT_ROOT_DIR

DATA_MASTER_DIR = ORIGINAL_PROJECT_ROOT_DIR / "mld_data_master_2026"
DIFFUSION_DERIVATIVES_DIR = DATA_MASTER_DIR / "derivatives" / "diffusion"
NODDI_TEMP_DIR = DATA_MASTER_DIR / "derivatives" / "noddi_temp"
INVENTORY_FILE = DATA_MASTER_DIR / "imaging_file_manifest.csv"

TEST_MODE = False
OVERWRITE = False

NODDI_MAPS = ("NDI", "ODI", "FWF")


# %%
# Load inventory and select sessions

inventory = pd.read_csv(INVENTORY_FILE)

if TEST_MODE:
    inventory = inventory.head(1)

print(f"Selected sessions: {len(inventory)}")


# %%
# Initialize AMICO

amico.setup()


# %%
# Run NODDI fitting

completed = 0
skipped = 0
failed = []

for _, row in inventory.iterrows():
    subject = f"sub-{str(row["SubjectID"])}"
    session = f"ses-{str(row["SessionID"])}"

    input_dir = NODDI_TEMP_DIR / subject / session / "dwi"
    output_dir = DIFFUSION_DERIVATIVES_DIR / subject / session / "noddi"

    output_files = {
        name: output_dir / f"{subject}_{session}_model-NODDI_param-{name}_dwimap.nii.gz"
        for name in NODDI_MAPS
    }

    if not OVERWRITE and all(p.exists() for p in output_files.values()):
        print(f"SKIP: {subject}/{session} (outputs exist)")
        skipped += 1
        continue

    required_files = [
        input_dir / "dwi.nii.gz",
        input_dir / "dwi.bval",
        input_dir / "dwi.bvec",
        input_dir / "mask.nii.gz",
    ]

    if not all(p.is_file() for p in required_files):
        print(f"SKIP: {subject}/{session} (missing input files)")
        skipped += 1
        continue

    print(f"\nProcessing {subject}/{session}")
    start = time.perf_counter()

    try:
        # Create AMICO acquisition scheme
        fsl2scheme(
            str(input_dir / "dwi.bval"),
            str(input_dir / "dwi.bvec"),
            str(input_dir / "dwi.scheme"),
            bStep=[0, 700, 2000],  # pyright: ignore[reportArgumentType]
        )

        # Initialize evaluation
        ae = amico.Evaluation(
            str(NODDI_TEMP_DIR),
            f"{subject}/{session}/dwi",
        )

        ae.load_data(
            dwi_filename="dwi.nii.gz",
            scheme_filename="dwi.scheme",
            mask_filename="mask.nii.gz",
            b0_thr=0,
        )

        # Fit NODDI
        ae.set_model("NODDI")
        ae.generate_kernels(regenerate=False)
        ae.load_kernels()
        ae.fit()
        ae.save_results()

        # Locate and copy final parameter maps
        result_files = {}

        for name in NODDI_MAPS:
            matches = list((input_dir / "AMICO").rglob(f"fit_{name}.nii.gz"))

            if len(matches) != 1:
                raise RuntimeError(
                    f"Expected one fit_{name}.nii.gz, " f"found {len(matches)}"
                )

            result_files[name] = matches[0]

        output_dir.mkdir(parents=True, exist_ok=True)

        for name, source in result_files.items():
            shutil.copy2(source, output_files[name])

        completed += 1
        elapsed = (time.perf_counter() - start) / 60
        print(f"DONE: {subject}/{session} ({elapsed:.1f} min)")

    except Exception as exc:
        print(f"FAILED: {subject}/{session}: {exc}")
        failed.append((subject, session, str(exc)))


# %%
# Summary

print(f"Completed: {completed}")
print(f"Skipped:   {skipped}")
print(f"Failed:    {len(failed)}")

for subject, session, error in failed:
    print(f"  {subject}/{session}: {error}")

# %%
