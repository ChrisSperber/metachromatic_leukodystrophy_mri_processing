"""Generate a visual QC PDF showing selected tract segmentations plotted on FA maps.

Requirements:
    - the main pipeline, notably the collection of FA images into the temporary image folder,
        was run

Behavior:
    - Masks are resampled to FA space (nearest) before overlaying.
    - Tract groups are combined by OR (np.logical_or).
    - Slice indices are chosen by quantiles over the axis-indices where the combined mask is present
      * default: axial (z)
      * if tract-group is in CORONAL_VIS_TRACTS: coronal (y) (often helpful e.g. for CST)
    - Missing/empty inputs produce a PDF page with placeholder text.

Outputs:
    - One PDF per tract (or tract-group) written to OUT_SUBFOLDER.
"""

# %%
from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

import matplotlib.pyplot as plt
import nibabel as nib
import numpy as np
from matplotlib.backends.backend_pdf import PdfPages
from matplotlib.gridspec import GridSpec
from nibabel.nifti1 import Nifti1Image
from nilearn.image import resample_to_img

from mld_tbss.config import FA_COPY_DIR, TEMPORARY_DATA_DIR

# %%
TRACT_SEGMENTATION_DIR = TEMPORARY_DATA_DIR / "TractSeg_outputs"
OUT_SUBFOLDER = Path(__file__).parent / "d_tractseg_qc_pdfs"

# Tracts that should be combined (e.g., L+R) are provided as a list
QC_TRACTS: list[list[str]] = [
    ["CST_left", "CST_right"],
    ["FPT_left", "FPT_right"],
]

BUNDLE_SEGM_SUBDIR = "bundle_segmentations"

# Tract *prefixes* to visualise in coronal view (y).
# Example: "CST_left" startswith "CST".
CORONAL_VIS_TRACTS = ["CST", "FPT"]

# plotting
N_SLICES = 3
FIGSIZE = (11.7, 8.3)  # A4 landscape inches
MASK_ALPHA = 0.55
FA_WINDOW_PCT = (1.0, 99.0)  # robust FA window


# %%
def _load_nifti(path: Path) -> Nifti1Image:
    return nib.load(str(path))  # type: ignore[no-any-return]


def _fa_path_for_subject(subject_folder_name: str) -> Path:
    return FA_COPY_DIR / f"{subject_folder_name}_FA.nii.gz"


def _mask_paths_for_subject(
    subject_dir: Path, tract_names: Sequence[str]
) -> list[Path]:
    seg_dir = subject_dir / BUNDLE_SEGM_SUBDIR
    return [seg_dir / f"{t}.nii.gz" for t in tract_names]


def _to_bool_mask(img: Nifti1Image) -> np.ndarray:
    data = np.asarray(img.get_fdata(), dtype=np.float32)
    return data > 0


def _resample_mask_to_fa(mask_img: Nifti1Image, fa_img: Nifti1Image) -> np.ndarray:
    mask_r: Nifti1Image = resample_to_img(
        mask_img,
        fa_img,
        interpolation="nearest",
        force_resample=True,
        copy_header=True,
    )  # pyright: ignore[reportAssignmentType]
    return _to_bool_mask(mask_r)


def _pick_slices(mask: np.ndarray, axis: int, n_slices: int) -> list[int]:
    """Pick slice indices using quantiles over axis-indices where the mask exists."""
    if mask.ndim != 3:  # noqa: PLR2004
        raise ValueError(f"Expected 3D mask, got shape {mask.shape}")
    if axis not in (0, 1, 2):
        raise ValueError(f"axis must be 0, 1, or 2 (got {axis})")

    other_axes = tuple(ax for ax in (0, 1, 2) if ax != axis)
    idx_any = np.where(mask.any(axis=other_axes))[0]

    if idx_any.size == 0:
        return []
    if idx_any.size == 1:
        return [int(idx_any[0])] * n_slices

    qs = np.linspace(0.15, 0.85, n_slices) if n_slices > 1 else np.array([0.5])
    iq = np.quantile(idx_any.astype(np.float32), qs, method="nearest")
    idx = sorted({int(i) for i in iq})

    # If duplicates collapsed, fall back to evenly spaced slices between min and max
    if len(idx) != n_slices:
        i_min, i_max = int(idx_any.min()), int(idx_any.max())
        if i_min == i_max:
            return [i_min] * n_slices
        i_lin = np.linspace(i_min, i_max, n_slices)
        return [int(round(i)) for i in i_lin]

    return idx


def _rgba_red_overlay(mask2d: np.ndarray, alpha: float) -> np.ndarray:
    """RGBA overlay: red where mask is True, transparent elsewhere."""
    m = mask2d.astype(np.float32, copy=False)
    overlay = np.zeros((m.shape[0], m.shape[1], 4), dtype=np.float32)
    overlay[..., 0] = 1.0  # red
    overlay[..., 3] = alpha * m  # alpha only where mask
    return overlay


def _placeholder_page(pdf: PdfPages, title: str, lines: list[str]) -> None:
    fig = plt.figure(figsize=FIGSIZE, constrained_layout=True)
    fig.suptitle(title, fontsize=14)

    ax = fig.add_subplot(1, 1, 1)
    ax.set_axis_off()
    ax.text(
        0.02,
        0.95,
        "\n".join(lines),
        va="top",
        ha="left",
        fontsize=12,
        family="monospace",
        transform=ax.transAxes,
    )

    pdf.savefig(fig, dpi=200)
    plt.close(fig)


def _should_use_coronal_view(tract_group: Sequence[str]) -> bool:
    """Visualise coronal if any tract name starts with a configured prefix."""
    return any(t.startswith(tuple(CORONAL_VIS_TRACTS)) for t in tract_group)


def _extract_slice(arr: np.ndarray, axis: int, idx: int) -> np.ndarray:
    """Extract a 2D slice from a 3D array along a given axis."""
    if axis == 0:
        return arr[idx, :, :]
    if axis == 1:
        return arr[:, idx, :]
    # axis == 2
    return arr[:, :, idx]


def _axis_label(axis: int) -> str:
    return {0: "x", 1: "y", 2: "z"}[axis]


# %%
OUT_SUBFOLDER.mkdir(parents=True, exist_ok=True)

subject_dirs = sorted([p for p in TRACT_SEGMENTATION_DIR.iterdir() if p.is_dir()])
if not subject_dirs:
    raise FileNotFoundError(f"No subject folders found in: {TRACT_SEGMENTATION_DIR}")

for tract_group in QC_TRACTS:
    tract_label = "+".join(tract_group)
    tract_label_safe = tract_label.replace("/", "_").replace(" ", "_")
    out_pdf = OUT_SUBFOLDER / f"qc_{tract_label_safe}.pdf"

    # Default: axial (z). Some tracts: coronal (y).
    view_axis = 1 if _should_use_coronal_view(tract_group) else 2
    view_axis_name = _axis_label(view_axis)

    print(
        f"\n=== Writing QC PDF for tract-group: {tract_label} (view={view_axis_name})"
    )
    print(f"-> {out_pdf}")

    with PdfPages(out_pdf) as pdf:
        for subj_dir in subject_dirs:
            subj_name = subj_dir.name  # e.g. subject_8090_date_20170814
            fa_path = _fa_path_for_subject(subj_name)
            mask_paths = _mask_paths_for_subject(subj_dir, tract_group)

            title = f"SUBJECT: {subj_name}    TRACT: {tract_label}"

            missing: list[str] = []
            if not fa_path.exists():
                missing.append(f"FA missing: {fa_path.name}")
            for mp in mask_paths:
                if not mp.exists():
                    missing.append(f"Mask missing: {mp.name}")

            if missing:
                _placeholder_page(
                    pdf,
                    title=title,
                    lines=["Missing inputs -> no overlay plotted.", "", *missing],
                )
                continue

            # Load FA
            fa_img = _load_nifti(fa_path)
            fa = np.asarray(fa_img.get_fdata(), dtype=np.float32)

            if fa.ndim != 3:  # noqa: PLR2004
                _placeholder_page(
                    pdf,
                    title=title,
                    lines=[f"Unexpected FA shape: {fa.shape} (expected 3D)."],
                )
                continue

            finite = np.isfinite(fa)
            if finite.any():
                vmin, vmax = np.percentile(fa[finite], FA_WINDOW_PCT)
                vmin_fa, vmax_fa = float(vmin), float(vmax)
            else:
                vmin_fa, vmax_fa = 0.0, 1.0

            # Load + resample + combine masks
            combined = np.zeros(fa.shape, dtype=bool)

            for mp in mask_paths:
                m_img = _load_nifti(mp)
                m_bool = _resample_mask_to_fa(m_img, fa_img)

                if m_bool.shape != combined.shape:
                    _placeholder_page(
                        pdf,
                        title=title,
                        lines=[
                            "Mask resampling produced unexpected shape.",
                            f"FA shape:   {combined.shape}",
                            f"Mask shape: {m_bool.shape}",
                            f"Mask file:  {mp.name}",
                        ],
                    )
                    combined = None  # type: ignore[assignment]
                    break

                combined |= m_bool

            if combined is None:
                continue

            if not combined.any():
                _placeholder_page(
                    pdf,
                    title=title,
                    lines=[
                        "Combined mask is empty (all zeros).",
                        "",
                        "Mask files:",
                        *[f"- {p.name}" for p in mask_paths],
                    ],
                )
                continue

            slice_idxs = _pick_slices(combined, axis=view_axis, n_slices=N_SLICES)
            if not slice_idxs:
                _placeholder_page(
                    pdf,
                    title=title,
                    lines=[
                        "Could not determine slice indices (mask had no occupied slices)."
                    ],
                )
                continue

            # Plot: 1 row × N_SLICES
            fig = plt.figure(figsize=FIGSIZE, constrained_layout=True)
            gs = GridSpec(1, len(slice_idxs), figure=fig, hspace=0.02, wspace=0.02)
            fig.suptitle(f"{title}    VIEW: {view_axis_name}", fontsize=14)

            for j, idx in enumerate(slice_idxs):
                ax = fig.add_subplot(gs[0, j])

                fa2d = np.rot90(_extract_slice(fa, axis=view_axis, idx=idx))
                m2d = np.rot90(_extract_slice(combined, axis=view_axis, idx=idx))

                ax.imshow(fa2d, cmap="gray", vmin=vmin_fa, vmax=vmax_fa)
                ax.imshow(_rgba_red_overlay(m2d, MASK_ALPHA))
                ax.set_axis_off()

                ax.set_title(
                    f"{view_axis_name}={idx}",
                    fontsize=11,
                    loc="left" if j == 0 else "center",
                )

            pdf.savefig(fig, dpi=200)
            plt.close(fig)

    print(f"Done: {out_pdf}")

# %%
