#!/usr/bin/env python3
"""Copy camera folders into the Swift Camera Toolkit library layout.

Does not delete sources. Never overwrites a different file.

Sony RAWs reuse names (DSC02101.ARW) and sit in a tight size band, so
name+size is not identity. A destination is skipped only when SHA-256
matches. Same name + different hash is copied beside it as name~1.ext.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import time
from pathlib import Path

LIBRARY = Path("/Volumes/nc_files_24/zurzi2/files/Media/Camera")
DRIVE = Path("/Volumes/1TB Crucial")
RCLONE = "rclone"
EXCLUDES = ["._*", ".DS_Store", ".Trashes/**", ".Spotlight-V100/**", ".fseventsd/**"]

RAW = {".arw", ".cr2", ".cr3", ".nef", ".dng", ".raf"}
PHOTOS = {".jpg", ".jpeg", ".heic", ".heif", ".hif", ".png", ".tif", ".tiff", ".webp"}
VIDEO = {".mp4", ".mov", ".m4v", ".osv", ".lrf", ".lrv", ".insv"}
AUDIO = {".wav", ".mp3", ".m4a", ".aac"}
SKIP = {".thm", ".scr", ".db"}  # camera index/preview junk; LRF is kept in VIDEO


def media_folder(path: Path, device: str) -> str | None:
    ext = path.suffix.lower()
    if ext in SKIP:
        return None
    if ext in VIDEO:
        return "Video"
    if ext in AUDIO:
        return "Audio"
    if ext in RAW:
        return "Photos" if device == "DJI Osmo 360" else "RAW"
    if ext in PHOTOS:
        return "Photos" if device == "DJI Osmo 360" else "JPEG"
    if ext in {".xml", ".xmp", ".photo-edit", ".met"}:
        return "Camera Support"
    return None


JOBS = [
    # Loose Wit Trip Utah piles — the big missing set
    {
        "name": "wit-utah-sony",
        "src": DRIVE / "Wit Trip Utah " / "SONY A7V",
        "date": "2026-07-01",
        "event": "Wit Trip Utah",
        "device": "Sony A7V",
    },
    {
        "name": "wit-utah-360",
        "src": DRIVE / "Wit Trip Utah " / "360 CAMERA",
        "date": "2026-07-01",
        "event": "Wit Trip Utah",
        "device": "DJI Osmo 360",
    },
    {
        "name": "wit-utah-nano",
        "src": DRIVE / "Wit Trip Utah " / "DJI NANO",
        "date": "2026-07-01",
        "event": "Wit Trip Utah",
        "device": "DJI Nano",
    },
    {
        "name": "july4-sony",
        "src": DRIVE / "July 4th ",
        "date": "2026-07-04",
        "event": "July 4 2026",
        "device": "Sony A7V",
    },
    {
        "name": "birthday-sony",
        "src": DRIVE / "Nevryk's 21st Birthday",
        "date": "2026-06-27",
        "event": "Birthday 2026",
        "device": "Sony A7V",
    },
    {
        "name": "kay-pocket",
        "src": DRIVE / "Kay messing around with Pocket",
        "date": "2026-07-02",
        "event": "Kay Pocket",
        "device": "DJI Nano",
    },
    # Official Camera Buffer events (Card Copy + Photomator HEICs)
    {
        "name": "buf-may15",
        "src": DRIVE / "Camera Buffer" / "2026" / "2026-05-15 may15-portrait-session",
        "date": "2026-05-15",
        "event": "may15-portrait-session",
        "device": "Sony A7V",
    },
    {
        "name": "buf-birthday",
        "src": DRIVE / "Camera Buffer" / "2026" / "2026-06-27 birthday-2026",
        "date": "2026-06-27",
        "event": "Birthday 2026",
        "device": "Sony A7V",
    },
    {
        "name": "buf-ucsc-sony",
        "src": DRIVE / "Camera Buffer" / "2026" / "2026-07-01 ucsc-library-eileen" / "Sony A7V",
        "date": "2026-07-01",
        "event": "ucsc-library-eileen",
        "device": "Sony A7V",
    },
    {
        "name": "buf-ucsc-360",
        "src": DRIVE / "Camera Buffer" / "2026" / "2026-07-01 ucsc-library-eileen" / "DJI Osmo 360",
        "date": "2026-07-01",
        "event": "ucsc-library-eileen",
        "device": "DJI Osmo 360",
    },
    {
        "name": "buf-july4-360",
        "src": DRIVE / "Camera Buffer" / "2026" / "2026-07-04 july4-2026",
        "date": "2026-07-04",
        "event": "July 4 2026",
        "device": "DJI Osmo 360",
    },
    {
        "name": "buf-vegas",
        "src": DRIVE / "Camera Buffer" / "2026" / "2026-07-13 las-vegas-july-13",
        "date": "2026-07-13",
        "event": "las-vegas-july-13",
        "device": "Sony A7V",
    },
    {
        "name": "buf-acer",
        "src": DRIVE / "Camera Buffer" / "2026" / "2026-07-17 acer32in-240hz-ghosting",
        "date": "2026-07-17",
        "event": "acer32in-240hz-ghosting",
        "device": "Sony A7V",
    },
]


def dest_dir(job: dict, media: str) -> Path:
    return LIBRARY / "Originals" / job["date"][:4] / f"{job['date']} {job['event']}" / job["device"] / media


def walk_media(src: Path, device: str) -> list[tuple[Path, str]]:
    out: list[tuple[Path, str]] = []
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames[:] = [d for d in dirnames if not d.startswith(".") and d not in {"_Trash", "Exports", "Photomator"}]
        # Photomator HEICs are still useful; include Photomator as JPEG later via a second pass
        for name in filenames:
            if name.startswith("._") or name == ".DS_Store":
                continue
            path = Path(dirpath) / name
            media = media_folder(path, device)
            if media:
                out.append((path, media))
    # Include Photomator / Exports images if we skipped those dirs
    for extra in ("Photomator", "Exports"):
        extra_root = src / extra
        if not extra_root.is_dir() and src.name != extra:
            # also look beside Card Copy
            extra_root = src.parent / extra
        if extra_root.is_dir():
            for path in extra_root.rglob("*"):
                if not path.is_file() or path.name.startswith("._") or path.name == ".DS_Store":
                    continue
                media = media_folder(path, device)
                if media:
                    out.append((path, media))
    return out


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def unused_name(directory: Path, name: str) -> Path:
    candidate = directory / name
    if not candidate.exists():
        return candidate
    stem = Path(name).stem
    suffix = Path(name).suffix
    index = 1
    while True:
        candidate = directory / f"{stem}~{index}{suffix}"
        if not candidate.exists():
            return candidate
        index += 1


def classify_existing(source: Path, dest: Path) -> str:
    """same / different / missing. Size mismatch means different; size match still hashes."""
    if not dest.exists():
        return "missing"
    if dest.stat().st_size != source.stat().st_size:
        return "different"
    if sha256_file(source) == sha256_file(dest):
        return "same"
    return "different"


def copy_job(job: dict) -> dict:
    src: Path = job["src"]
    if not src.is_dir():
        print(f"SKIP {job['name']}: missing {src}", flush=True)
        return {"name": job["name"], "status": "missing"}

    files = walk_media(src, job["device"])
    by_media: dict[str, list[Path]] = {}
    for path, media in files:
        by_media.setdefault(media, []).append(path)

    print(
        f"\n=== {job['name']}  {src}  →  {job['date']} {job['event']} / {job['device']}  "
        f"({sum(len(v) for v in by_media.values())} files) ===",
        flush=True,
    )
    copied = skipped = failed = 0
    for media, paths in sorted(by_media.items()):
        dest = dest_dir(job, media)
        dest.mkdir(parents=True, exist_ok=True)
        # Batch by source parent so a DCIM folder is one rclone copy, not thousands.
        by_parent: dict[Path, list[Path]] = {}
        for path in paths:
            by_parent.setdefault(path.parent, []).append(path)
        for parent, group in by_parent.items():
            already = 0
            to_copy: list[tuple[str, str]] = []  # (source name, dest name)
            for path in group:
                target = dest / path.name
                verdict = classify_existing(path, target)
                if verdict == "same":
                    already += 1
                    continue
                if verdict == "different":
                    renamed = unused_name(dest, path.name)
                    print(
                        f"  COLLISION {path.name} exists with different SHA-256 — keeping both as {renamed.name}",
                        flush=True,
                    )
                    to_copy.append((path.name, renamed.name))
                else:
                    to_copy.append((path.name, path.name))
            skipped += already
            if not to_copy:
                continue
            # rclone copy keeps source filenames. Same-name copies go as a
            # batch; renamed collisions use copyto so the dest name can change.
            same_name = [src_name for src_name, dest_name in to_copy if src_name == dest_name]
            renamed = [(src_name, dest_name) for src_name, dest_name in to_copy if src_name != dest_name]
            if same_name:
                list_file = dest / f".offload-{os.getpid()}.files"
                list_file.write_text("\n".join(same_name) + "\n")
                cmd = [
                    RCLONE, "copy", str(parent), str(dest),
                    "--files-from", str(list_file),
                    "--checksum", "--immutable",
                    "--transfers", "4",
                    "--stats", "30s",
                    "--stats-one-line",
                    "--log-level", "INFO",
                ]
                print(f"  rclone {len(same_name)} files  {parent} -> {dest}", flush=True)
                code = subprocess.call(cmd)
                try:
                    list_file.unlink()
                except OSError:
                    pass
                if code != 0:
                    print(f"  FAIL rclone {code} for {parent} -> {dest}", flush=True)
                    failed += len(same_name)
                else:
                    copied += len(same_name)
            for src_name, dest_name in renamed:
                cmd = [
                    RCLONE, "copyto", str(parent / src_name), str(dest / dest_name),
                    "--checksum", "--immutable",
                    "--log-level", "INFO",
                ]
                print(f"  rclone copyto {src_name} -> {dest_name}", flush=True)
                code = subprocess.call(cmd)
                if code != 0:
                    print(f"  FAIL rclone {code} for {src_name} -> {dest_name}", flush=True)
                    failed += 1
                else:
                    copied += 1
    status = "ok" if failed == 0 else "partial"
    print(f"  done {job['name']}: copied={copied} skipped={skipped} failed={failed}", flush=True)
    return {"name": job["name"], "status": status, "copied": copied, "skipped": skipped, "failed": failed}


def main() -> int:
    if not LIBRARY.is_dir():
        print("NAS library is not mounted:", LIBRARY, file=sys.stderr)
        return 2
    if not DRIVE.is_dir():
        print("Crucial is not mounted:", DRIVE, file=sys.stderr)
        return 2

    only = set(sys.argv[1:])
    jobs = [j for j in JOBS if not only or j["name"] in only]
    started = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"offload start {started}  jobs={len(jobs)}", flush=True)
    results = [copy_job(job) for job in jobs]
    print("\n===== SUMMARY =====", flush=True)
    for row in results:
        print(row, flush=True)
    failed = [r for r in results if r.get("status") not in {"ok", "missing"}]
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
