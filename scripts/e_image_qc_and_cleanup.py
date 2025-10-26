"""Visualise images for quality control and clean up intermediate segmentation files.

Visualise the images in a pdf to verify:
- general image quality
- quality of skullstripping
- fit of T1 and FA images

Additionally, leftover files from the T1 segmentation pipeline are removed.
"""

# %%

from pathlib import Path

import matplotlib.pyplot as plt
import nibabel as nib
import numpy as np
import pandas as pd
from matplotlib.backends.backend_pdf import PdfPages
from matplotlib.colors import ListedColormap
from matplotlib.gridspec import GridSpec
from nilearn.image import resample_to_img

from mld_tbss.config import COPY_FOLDER_DICT, MP2RAGE, T1_SEGMENTED_DIR
from mld_tbss.utils import Cols

DO_CLEANUP = False
QC_PDF_PATH = Path(__file__).parent / "e_image_qc.pdf"

IMAGE_SUFFIXES_TO_DELETE = [
    "_den.nii.gz",  # denoised raw image
    "_den_rfov.nii.gz",  # same with cropped neck region
]

T1_SKULLSTRIPPED_SUFFIX = "_brain.nii.gz"
SYNTHSEG_LABEL_SUFFIX = "_synthseg_labels.nii.gz"
SYNTHSEG_LABEL_PATH = "Full_Image_Path_Synthseg_Labels"
BRAIN_SKULLSTRIPPED_PATH = "Full_Image_Path_Brain_Skullstripped"

# overlay settings
FA_ALPHA = 0.7  # transparency of FA overlays
SEGMENTATION_ALPHA = 0.65  # transparency of segmentation overlays
AXIAL_SLICES_FRAC = (0.30, 0.50, 0.70)  # relative positions through z
FIGSIZE = (11.7, 8.3)  # A4 landscape inches
FA_HIDE_CUTOFF = 0.15  # cutoff below which FA values are set to zero for visualisation

FA = "FA"
RELEVANT_IMAGES = [MP2RAGE, FA]
FULL_PATH_TO_IMAGE = "Full_Image_Path"

# %%
# collect file links
data_df = pd.read_csv(Path(__file__).parent / "b_collect_and_verify_data.csv", sep=";")
data_df = data_df[data_df[Cols.IMAGE_MODALITY].isin(RELEVANT_IMAGES)]
for _, row in data_df.iterrows():
    if row[Cols.IMAGE_MODALITY] == FA:
        data_df[FULL_PATH_TO_IMAGE] = COPY_FOLDER_DICT[FA] / row[Cols.FILENAME]
    elif row[Cols.IMAGE_MODALITY] == MP2RAGE:
        data_df[FULL_PATH_TO_IMAGE] = COPY_FOLDER_DICT[MP2RAGE] / row[Cols.FILENAME]
    else:
        raise ValueError(f"Invalid modality {row[Cols.IMAGE_MODALITY]}")

data_df_wide = data_df.pivot(
    index=[Cols.SUBJECT_ID, Cols.DATE_TAG, Cols.SUBJECT_TYPE],
    columns=Cols.IMAGE_MODALITY,
    values=[FULL_PATH_TO_IMAGE, Cols.FILENAME],
).reset_index()
# flatten MultiIndex colnames
data_df_wide.columns = [
    (
        col
        if isinstance(col, str)
        else "_".join([c for c in col if c])  # pyright: ignore[reportGeneralTypeIssues]
    )
    for col in data_df_wide.columns
]

# create file paths to segmentation images - skull stripped brain & synth seg labels
data_df_wide[SYNTHSEG_LABEL_PATH] = (
    data_df_wide["Filename_MP2RAGE"]
    .str.replace(".nii.gz", SYNTHSEG_LABEL_SUFFIX, regex=False)
    .apply(lambda name: T1_SEGMENTED_DIR / name)
)
data_df_wide[BRAIN_SKULLSTRIPPED_PATH] = (
    data_df_wide["Filename_MP2RAGE"]
    .str.replace(".nii.gz", T1_SKULLSTRIPPED_SUFFIX, regex=False)
    .apply(lambda name: T1_SEGMENTED_DIR / name)
)

# %%
# PDF creation helpers
n_slices = len(AXIAL_SLICES_FRAC)


def _pick_axial_indices(shape, fracs):
    z = shape[-1]
    return [max(0, min(z - 1, int(round(frac * (z - 1))))) for frac in fracs]


def _load_nifti(path: Path):
    img = nib.load(str(path))  # type: ignore
    data = np.asarray(img.get_fdata(), dtype=np.float32)  # type: ignore
    return img, data


def _resample_like(moving_img, target_img, interpolation: str = "continuous"):
    return resample_to_img(
        moving_img,
        target_img,
        interpolation=interpolation,
        force_resample=True,
        copy_header=True,
    )


def _relabel_to_ordinal(labels_3d: np.ndarray) -> np.ndarray:
    """Map Freesurfer label integers to 0,1,2,... preserving 0 as background."""
    labels = labels_3d.astype(np.int64, copy=False)
    uniq = np.unique(labels)
    uniq = uniq[uniq != 0]
    if uniq.size == 0:
        return np.zeros_like(labels, dtype=np.int32)
    out = np.zeros_like(labels, dtype=np.int32)
    for k, val in enumerate(uniq, start=1):
        out[labels == val] = k
    return out


def _make_discrete_cmap(n_classes: int):
    """Background transparent; other classes from a qualitative palette."""
    base = plt.get_cmap("tab20")
    # transparent background (0)
    colors: list[tuple[float, float, float, float]] = [(0.0, 0.0, 0.0, 0.0)]
    for i in range(max(1, n_classes)):
        colors.append(base(i % base.N))
    return ListedColormap(colors)


# %%
# create PDF
n_total = len(data_df_wide)

with PdfPages(QC_PDF_PATH) as pdf:
    for _, row in data_df_wide.iterrows():
        sub = row[Cols.SUBJECT_ID]
        date = row[Cols.DATE_TAG]

        path_mp2 = Path(row["Full_Image_Path_MP2RAGE"])
        path_fa = Path(row["Full_Image_Path_FA"])
        path_t1b = Path(row[BRAIN_SKULLSTRIPPED_PATH])
        path_lab = Path(row[SYNTHSEG_LABEL_PATH])

        # Skip if any file missing
        paths = [
            ("MP2RAGE", path_mp2),
            ("FA", path_fa),
            ("T1_brain", path_t1b),
            ("SynthSeg", path_lab),
        ]
        missing = [name for name, p in paths if not p.exists()]
        if missing:
            print(f"[{sub} {date}: missing {missing} -> skipped")
            continue

        # Load
        mp2_img, mp2 = _load_nifti(path_mp2)
        fa_img, fa = _load_nifti(path_fa)
        t1b_img, t1b = _load_nifti(path_t1b)
        lab_img, lab = _load_nifti(path_lab)

        # Resample overlays
        fa_r = _resample_like(fa_img, mp2_img, interpolation="continuous")
        lab_r = _resample_like(lab_img, t1b_img, interpolation="nearest")
        fa_r_d = np.asarray(fa_r.get_fdata(), dtype=np.float32)  # type: ignore
        lab_r_d = np.asarray(lab_r.get_fdata(), dtype=np.int32)  # type: ignore

        # create mask to hide very low FA values
        fa_mask = fa_r_d > FA_HIDE_CUTOFF
        fa_display = np.ma.masked_where(~fa_mask, fa_r_d)
        # Robust FA window
        if fa_mask.any():
            fa_vmin, fa_vmax = np.percentile(fa_r_d[fa_mask], [1, 99])
        else:
            fa_vmin, fa_vmax = float(fa_r_d.min()), float(fa_r_d.max())

        # remap Synthseg Freesurfer labels to ordinal scale
        lab_r_d = _relabel_to_ordinal(lab_r_d)

        # Colormap for labels (0 transparent)
        n_classes = int(lab_r_d.max())
        lab_cmap = _make_discrete_cmap(n_classes)

        # Slice indices
        z_mp2 = _pick_axial_indices(mp2.shape, AXIAL_SLICES_FRAC)
        z_t1b = _pick_axial_indices(t1b.shape, AXIAL_SLICES_FRAC)

        # Figure: 2 rows × N_SLICES cols
        fig = plt.figure(figsize=FIGSIZE, constrained_layout=True)
        gs = GridSpec(2, n_slices, figure=fig, hspace=0.06, wspace=0.02)
        fig.suptitle(f"SUBJECT: {sub}    DATE: {date}", fontsize=14)

        # Row 1: MP2RAGE + FA
        mp2_vmin, mp2_vmax = float(mp2.min()), float(mp2.max())
        fa_vmin, fa_vmax = float(fa_r_d.min()), float(fa_r_d.max())
        for j, z in enumerate(z_mp2):
            ax = fig.add_subplot(gs[0, j])
            ax.imshow(np.rot90(mp2[:, :, z]), cmap="gray", vmin=mp2_vmin, vmax=mp2_vmax)
            ax.imshow(
                np.rot90(mp2[:, :, z]),
                cmap="gray",
                vmin=float(mp2.min()),
                vmax=float(mp2.max()),
            )
            ax.imshow(
                np.rot90(fa_display[:, :, z]),
                cmap="inferno",
                vmin=fa_vmin,
                vmax=fa_vmax,
                alpha=FA_ALPHA,
            )
            ax.set_axis_off()
            if j == 0:
                ax.set_title("MP2RAGE + FA", fontsize=11, loc="left")

        # Row 2: skull-stripped T1 + SynthSeg labels
        t1b_vmin, t1b_vmax = float(t1b.min()), float(t1b.max())
        for j, z in enumerate(z_t1b):
            ax = fig.add_subplot(gs[1, j])
            ax.imshow(np.rot90(t1b[:, :, z]), cmap="gray", vmin=t1b_vmin, vmax=t1b_vmax)
            ax.imshow(
                np.rot90(lab_r_d[:, :, z]),
                cmap=lab_cmap,
                vmin=0,
                vmax=n_classes,
                alpha=SEGMENTATION_ALPHA,
            )
            ax.set_axis_off()
            if j == 0:
                ax.set_title(
                    "Skull-stripped T1 + SynthSeg labels", fontsize=11, loc="left"
                )

        pdf.savefig(fig, dpi=200)
        plt.close(fig)

print(f"QC PDF written to: {QC_PDF_PATH}")

# %%
# Cleanup
if DO_CLEANUP:
    for file in T1_SEGMENTED_DIR.iterdir():
        print("Doing cleanup of intermediate segmentation image files.")
        if not file.is_file():
            continue
        if any(file.name.endswith(suf) for suf in IMAGE_SUFFIXES_TO_DELETE):
            print(f"Deleting {file.name}")
            file.unlink()
else:
    print("Cleanup not performed; set DO_CLEANUP if cleanup desired.")

# %%
