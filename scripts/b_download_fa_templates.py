"""Download and extract SACT pediatric FA template candidates.

The script downloads two possible candidates: the general SACT FA template for all their subjects
between 6 and 12 years (i.e. with the largest underlying sample), and the FA template for the 11 to
12 years subsample, which is closer to the mean age of the current sample (~13years).

"""

# %%
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from contextlib import suppress
from pathlib import Path

from mld_tbss.config import FA_TEMPLATES_DIR

FIGSHARE_URL = "https://figshare.com/ndownloader/files/27622940"
ZIP_NAME = "SACT_templates.zip"
TEMPLATE_SACT_6_12 = "SACT_06_12_DT_fa.nii.gz"
TEMPLATE_SACT_11_12 = "SACT_11_12_DT_fa.nii.gz"
TEMPLATE_README = "SACT_README.txt"

# %%

FA_TEMPLATES_DIR.mkdir(parents=True, exist_ok=True)

REQUIRED_FILES = [
    FA_TEMPLATES_DIR / TEMPLATE_SACT_6_12,
    FA_TEMPLATES_DIR / TEMPLATE_SACT_11_12,
    FA_TEMPLATES_DIR / TEMPLATE_README,
]

missing = [p for p in REQUIRED_FILES if not p.exists()]

if not missing:
    print("[skip] All required files already exist.")
    sys.exit(0)
else:
    print("[info] Missing required files:")
    for m in missing:
        print("   -", m.name)

### DOWNLOAD ###
# the ZIP is placed in the system's temp folder
tmp_zip = Path(tempfile.gettempdir()) / ZIP_NAME

print(f"[info] Downloading ZIP from {FIGSHARE_URL} ...")
try:
    req = urllib.request.Request(  # noqa: S310
        FIGSHARE_URL, headers={"User-Agent": "python-downloader"}
    )
    with (
        urllib.request.urlopen(req, timeout=60) as r,  # noqa: S310
        tmp_zip.open("wb") as f,
    ):
        shutil.copyfileobj(r, f, length=1024 * 1024)
except Exception:
    # best-effort cleanup of a partial file
    with suppress(Exception):
        if tmp_zip.exists():
            tmp_zip.unlink()
print(f"[ok] Downloaded to {tmp_zip}")

### EXTRACTION ###
members_map = {}
with zipfile.ZipFile(tmp_zip, "r") as zf:
    members_map = {Path(m).name: m for m in zf.namelist()}
    for target in REQUIRED_FILES:
        name = target.name
        if name not in members_map:
            print(f"[warn] Missing in ZIP: {name}")
            continue
        print(f"[info] Extracting {name} -> {target}")
        with zf.open(members_map[name]) as src, target.open("wb") as out:
            shutil.copyfileobj(src, out)

# remove the ZIP when done
with suppress(Exception):
    if tmp_zip.exists():
        tmp_zip.unlink()


### VERIFICATION ###
# Verify everything is present now
still_missing = [p for p in REQUIRED_FILES if not p.exists()]
if still_missing:
    print("[error] After extraction, some required files are still missing:")
    for p in still_missing:
        print("   -", p.name)
    sys.exit(1)

print("[done] Templates ready in:", FA_TEMPLATES_DIR)
for p in REQUIRED_FILES:
    print("   -", p.name)

# %%
