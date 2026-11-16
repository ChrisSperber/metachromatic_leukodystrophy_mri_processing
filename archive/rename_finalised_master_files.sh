#!/usr/bin/env bash
set -euo pipefail
# Rename images documented in the imaging_file_manifest.csv before forwarding the data master to statistical analysis.
#
# During the current pipeline, original filenames for existing MPRAGE, qT1, FLAIR, DWI (incl reverse b0), DWI brain mask,
# preprocessed DWI, FA, and MD were not changed. All processing (DKI,NODDI,FOD, derivation of fiber tract ROIs) was performed
# on the originally named files. The current script aligns the naming with BIDS naming scheme.
#
# WARNING: The current script is intended to run only after the pipeline was finalised. It changes filenames and may break code.
#
# All naming changes are documented in a log that allows changes to be reversed with the --undo flag.
# --dry-run (default) highlights changes, --apply employs them, --undo can reverse changes given a change log

DATA_MASTER="${DATA_MASTER:-/home/chris/projects/mld_data_master_2026}"
exec python3 - "$DATA_MASTER" "$@" <<'PY'
import csv
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import uuid
from pathlib import Path

root = Path(sys.argv[1]).expanduser().resolve()
args = sys.argv[2:]
if args not in ([], ["--dry-run"], ["--apply"], ["--undo"]) and not (
    len(args) == 2 and args[0] == "--undo"
):
    sys.exit("Usage: bash rename_analysis_files.sh [--dry-run | --apply | --undo [BATCH_ID]]")
mode = "apply" if args == ["--apply"] else "undo" if args and args[0] == "--undo" else "dry-run"
manifest = root / "imaging_file_manifest.csv"
history = root / "derivatives" / "file_rename_history"
logpath = root / "file_rename_log.csv"
missing_markers = {"", "not_applicable", "n/a", "na", "none", "nan", "missing"}
log_fields = ["Timestamp", "BatchID", "Event", "OldPath", "NewPath", "Detail"]


def now():
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1048576), b""):
            h.update(chunk)
    return h.hexdigest()


def atomic_json(path, obj):
    temp = path.with_name(path.name + ".tmp")
    with temp.open("w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp, path)


def journal(batch, event, old="", new="", detail=""):
    logpath.parent.mkdir(parents=True, exist_ok=True)
    with logpath.open("a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=log_fields, lineterminator="\n")
        if f.tell() == 0:
            writer.writeheader()
        writer.writerow(dict(Timestamp=now(), BatchID=batch, Event=event,
                             OldPath=old, NewPath=new, Detail=detail))
        f.flush()
        os.fsync(f.fileno())


def relative(value):
    # Inventory paths must be relative and stay within the data master.
    value = value.strip().replace("\\", "/")
    if not value or value.lower() in missing_markers:
        return None
    p = Path(value)
    if p.is_absolute() or ".." in p.parts:
        raise ValueError(f"Unsafe inventory path: {value}")
    return p.as_posix()


def nifti_stem(name):
    for suffix in (".nii.gz", ".nii"):
        if name.endswith(suffix):
            return name[:-len(suffix)], suffix
    return None, None


def one_file(src_rel, target_name, planned, warnings, reason):
    src = root / src_rel
    dst_rel = str(Path(src_rel).with_name(target_name))
    dst = root / dst_rel
    if src_rel == dst_rel:
        return
    if not src.is_file() or src.is_symlink():
        warnings.append(f"MISSING/NOT REGULAR ({reason}): {src_rel}")
        return
    old = planned.get(src_rel)
    if old and old["new"] != dst_rel:
        raise ValueError(f"Two targets for the same file: {src_rel}")
    planned[src_rel] = {"old": src_rel, "new": dst_rel, "reason": reason}


def add_image_sidecar(path_rel, suffix, planned, warnings):
    src = root / path_rel
    stem, _ = nifti_stem(src.name)
    if stem is None:
        return
    sidecar = src.with_name(stem + ".json")
    if sidecar.is_file():
        name = suffix[:-len(".nii.gz")] if suffix.endswith(".nii.gz") else suffix[:-4]
        one_file(sidecar.relative_to(root).as_posix(), name + ".json", planned,
                 warnings, "image JSON sidecar")


def build_plan():
    with manifest.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        fields = reader.fieldnames
        rows = list(reader)
    if not fields:
        raise ValueError("Inventory has no header")
    required = {"SubjectID", "SessionID", "PathT1", "PathQT1", "PathFLAIR",
                "PathFA", "PathMD", "PathDWI", "PathBVAL", "PathBVEC",
                "PathDWIMIF", "PathMaskMIF"}
    missing_cols = required - set(fields)
    if missing_cols:
        raise ValueError(f"Inventory missing columns: {sorted(missing_cols)}")
    planned = {}
    warnings = []
    updates = []
    visited = set()
    field_spec = {
        "PathT1": "UNIT1", "PathQT1": "T1map", "PathFLAIR": "FLAIR",
        "PathFA": "FA", "PathMD": "MD", "PathDWI": "dwi",
        "PathDWIMIF": None, "PathMaskMIF": "desc-brain_mask",
    }
    for i, row in enumerate(rows):
        sub, ses = row["SubjectID"].strip(), row["SessionID"].strip()
        if not re.fullmatch(r"[A-Za-z0-9]+", sub) or not re.fullmatch(r"[A-Za-z0-9]+", ses):
            raise ValueError(f"Invalid subject/session on row {i+2}: {sub!r}, {ses!r}")
        key = (sub, ses)
        if key in visited:
            raise ValueError(f"Duplicate inventory subject/session: {key}")
        visited.add(key)
        prefix = f"sub-{sub}_ses-{ses}"
        dwi_stems = set()
        for col, suffix in field_spec.items():
            src_rel = relative(row.get(col, ""))
            if src_rel is None:
                continue
            path = Path(src_rel)
            if f"sub-{sub}" not in path.parts or f"ses-{ses}" not in path.parts:
                raise ValueError(f"Path inconsistent with subject/session in {col}: {src_rel}")
            if col == "PathDWIMIF":
                fname = path.name.lower()
                suffix = "desc-preproc_dwi" if "preproc" in fname else "desc-input_dwi"
            extension = ".nii.gz" if path.name.endswith(".nii.gz") else path.suffix
            if col in ("PathDWIMIF", "PathMaskMIF") and extension != ".mif":
                raise ValueError(f"Expected .mif for {col}: {src_rel}")
            if col not in ("PathDWIMIF", "PathMaskMIF") and extension not in (".nii", ".nii.gz"):
                raise ValueError(f"Expected NIfTI for {col}: {src_rel}")
            new_name = f"{prefix}_{suffix}{extension}"
            if (root / src_rel).is_file() and src_rel != str(path.with_name(new_name)):
                updates.append([i, col, src_rel, str(path.with_name(new_name))])
            one_file(src_rel, new_name, planned, warnings, col)
            if col in ("PathT1", "PathQT1", "PathFLAIR"):
                add_image_sidecar(src_rel, new_name, planned, warnings)
            if col == "PathDWI":
                stem, _ = nifti_stem(path.name)
                dwi_stems.add(stem)
                add_image_sidecar(src_rel, new_name, planned, warnings)
        for col, ext in (("PathBVAL", ".bval"), ("PathBVEC", ".bvec")):
            src_rel = relative(row.get(col, ""))
            if src_rel is None:
                continue
            path = Path(src_rel)
            if f"sub-{sub}" not in path.parts or f"ses-{ses}" not in path.parts:
                raise ValueError(f"Path inconsistent with subject/session in {col}: {src_rel}")
            if path.suffix != ext:
                raise ValueError(f"Unexpected extension in {col}: {src_rel}")
            new_name = f"{prefix}_dwi{ext}"
            if (root / src_rel).is_file() and src_rel != str(path.with_name(new_name)):
                updates.append([i, col, src_rel, str(path.with_name(new_name))])
            one_file(src_rel, new_name, planned, warnings, col)
            dwi_stems.add(path.stem)
        # A JSON sidecar sometimes follows the bval/bvec stem, not the NIfTI stem.
        dwi_dir = root / f"sub-{sub}" / f"ses-{ses}" / "dwi"
        for stem in dwi_stems:
            candidate = dwi_dir / (stem + ".json")
            if candidate.is_file():
                one_file(candidate.relative_to(root).as_posix(), f"{prefix}_dwi.json",
                         planned, warnings, "DWI JSON sidecar")
        # Only reverse-encoding fieldmaps with identifiable direction are renamed.
        fmap_dir = root / f"sub-{sub}" / f"ses-{ses}" / "fmap"
        if fmap_dir.is_dir():
            for fmap in sorted(fmap_dir.iterdir()):
                stem, ext = nifti_stem(fmap.name)
                if stem is None or not fmap.is_file():
                    continue
                match = re.search(r"(?:^|[_-])(PA|AP|RL|LR)(?=[_.-]|$)", stem, re.I)
                if not match:
                    warnings.append(f"UNRECOGNISED FIELDMAP DIRECTION: {fmap.relative_to(root)}")
                    continue
                direction = match.group(1).upper()
                target_stem = f"{prefix}_dir-{direction}_epi"
                one_file(fmap.relative_to(root).as_posix(), target_stem + ext,
                         planned, warnings, "fmap NIfTI")
                for side_ext in (".json", ".bval", ".bvec"):
                    sidecar = fmap_dir / (stem + side_ext)
                    if sidecar.is_file():
                        one_file(sidecar.relative_to(root).as_posix(),
                                 target_stem + side_ext, planned, warnings,
                                 "fmap sidecar")
    # Preflight: do not rename if a destination is already occupied, or targets collide.
    destinations = {}
    for entry in planned.values():
        old, new = entry["old"], entry["new"]
        if new in destinations and destinations[new] != old:
            raise ValueError(f"Destination collision: {new} from {old} and {destinations[new]}")
        destinations[new] = old
        if (root / new).exists() or (root / new).is_symlink():
            raise ValueError(f"Destination already exists: {new}")
    return fields, rows, list(planned.values()), updates, warnings


def write_inventory(fields, rows, updates):
    for i, col, old, new in updates:
        if relative(rows[i][col]) != old:
            raise ValueError(f"Inventory changed during renaming: row {i+2}, {col}")
        rows[i][col] = new
    fd, tmp = tempfile.mkstemp(prefix=".manifest_", suffix=".csv", dir=manifest.parent)
    try:
        with os.fdopen(fd, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, manifest)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def apply():
    fields, rows, moves, updates, warnings = build_plan()
    print(f"Planned file renames: {len(moves)}; inventory path updates: {len(updates)}")
    for item in moves:
        print(f"  {item['old']} -> {item['new']}")
    for msg in warnings:
        print("WARNING:", msg, file=sys.stderr)
    if mode == "dry-run":
        print("DRY RUN only. Use --apply to rename files.")
        return
    if not moves and not updates:
        print("Nothing to rename.")
        return
    batch = dt.datetime.now().strftime("%Y%m%dT%H%M%S") + "_" + uuid.uuid4().hex[:8]
    batch_dir = history / batch
    batch_dir.mkdir(parents=True, exist_ok=False)
    before = batch_dir / "imaging_file_manifest_before.csv"
    shutil.copy2(manifest, before)
    plan = dict(batch=batch, state="started", moves=moves, updates=updates,
                manifest_before_sha256=sha(before), manifest_after_sha256=None,
                warnings=warnings)
    atomic_json(batch_dir / "plan.json", plan)
    journal(batch, "BATCH_STARTED", detail=f"{len(moves)} planned renames")
    for item in moves:
        old, new = item["old"], item["new"]
        journal(batch, "RENAME_INTENT", old, new, item["reason"])
        (root / old).rename(root / new)
        journal(batch, "RENAMED", old, new, item["reason"])
    write_inventory(fields, rows, updates)
    plan["manifest_after_sha256"] = sha(manifest)
    plan["state"] = "applied"
    atomic_json(batch_dir / "plan.json", plan)
    journal(batch, "BATCH_APPLIED", detail=f"{len(moves)} renamed; {len(updates)} inventory paths updated")
    print(f"Applied batch: {batch}")
    print(f"Undo with: bash rename_analysis_files.sh --undo {batch}")


def undo():
    if not history.is_dir():
        sys.exit("No rename history found.")
    active = []
    for directory in history.iterdir():
        p = directory / "plan.json"
        if p.is_file():
            info = json.loads(p.read_text(encoding="utf-8"))
            if info.get("state") != "undone":
                active.append((directory.name, directory, info))
    if not active:
        sys.exit("No active batches to undo.")
    active.sort()
    batch, directory, info = active[-1]
    if len(args) == 2 and args[1] != batch:
        sys.exit(f"Can only undo latest active batch ({batch}) to preserve history order.")
    backup = directory / "imaging_file_manifest_before.csv"
    current_sha = sha(manifest)
    permitted = {info["manifest_before_sha256"], info.get("manifest_after_sha256")}
    if current_sha not in permitted:
        sys.exit("Inventory has changed since this batch. Undo stopped to protect manual edits.")
    moves = info["moves"]
    for item in reversed(moves):
        old, new = root / item["old"], root / item["new"]
        if old.exists() and new.exists():
            sys.exit(f"Undo blocked (both names exist): {old} / {new}")
        if not old.exists() and not new.exists():
            sys.exit(f"Undo blocked (both names missing): {old} / {new}")
    for item in reversed(moves):
        old, new = root / item["old"], root / item["new"]
        if new.exists():
            journal(batch, "UNDO_INTENT", item["new"], item["old"])
            new.rename(old)
            journal(batch, "UNDONE", item["new"], item["old"])
    if current_sha != info["manifest_before_sha256"]:
        fd, tmp = tempfile.mkstemp(prefix=".manifest_restore_", dir=manifest.parent)
        os.close(fd)
        try:
            shutil.copy2(backup, tmp)
            os.replace(tmp, manifest)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    info["state"] = "undone"
    atomic_json(directory / "plan.json", info)
    journal(batch, "BATCH_UNDONE")
    print(f"Undone batch: {batch}; inventory restored.")


if not root.is_dir() or not manifest.is_file():
    sys.exit(f"Data master or inventory not found: {root}")
try:
    if mode == "undo":
        undo()
    else:
        apply()
except (OSError, ValueError, csv.Error) as e:
    sys.exit(f"ERROR: {e}\nIf an --apply run was interrupted, inspect the last batch and use --undo.")
PY
