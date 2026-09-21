#!/usr/bin/env python3
"""Pack formcut's LGPL ffmpeg builds into release archives, checked against the record.

    python pack_release.py --binaries path/to/binaries [--out dist] [--sources]

--binaries is a folder holding ffmpeg-<triple>, ffprobe-<triple> and
lib-<triple>/ for one or more targets, the way formcut's src-tauri/binaries
does. Every file ffmpeg-licence.json records for a target has to be there with
its SHA-256, or the run stops; a target with no files there is skipped and named.

Each archive is ffmpeg-lgpl-<version>-<triple>.tar.gz, one folder of the same
name holding the target's files, the licence texts and the record. Archives are
made reproducibly (sorted entries, fixed times and owners, no gzip timestamp),
so packing the same files again gives the same bytes, and each is opened again
and checked the way formcut's first-run fetch checks it.

With --sources, the upstream source tarballs the record names are downloaded
and checked against their SHA-256, because the LGPL expects the source to be
offered from the same place as the binaries. SHA256SUMS lists every file made,
and RELEASE_NOTES.md describes the release. Standard library only.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
DOCUMENTS = ("LGPL-2.1.txt", "THIRD-PARTY-NOTICES.txt", "ffmpeg-licence.json")


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            sha.update(block)
    return sha.hexdigest()


def problems(folder: Path, files: list[dict]) -> list[str]:
    found = []
    for entry in files:
        path = folder / entry["path"]
        if not path.is_file():
            found.append(f"missing {entry['path']}")
        elif digest(path) != entry["sha256"]:
            found.append(f"{entry['path']} does not match the record")
    return found


def member(name: str, size: int = 0, mode: int = 0o644, folder: bool = False) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE if folder else tarfile.REGTYPE
    info.size, info.mode, info.mtime = size, mode, 0
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    return info


def pack(folder: Path, triple: str, files: list[dict], version: str, out: Path) -> Path:
    name = f"ffmpeg-lgpl-{version}-{triple}"
    sources = {entry["path"]: folder / entry["path"] for entry in files}
    sources.update({document: HERE / document for document in DOCUMENTS})
    folders = sorted({str(Path(path).parent) for path in sources if str(Path(path).parent) != "."})
    archive = out / f"{name}.tar.gz"
    with archive.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.PAX_FORMAT) as bundle:
            for path in ["", *folders]:
                bundle.addfile(member(f"{name}/{path}".rstrip("/"), mode=0o755, folder=True))
            for path in sorted(sources):
                data = sources[path].read_bytes()
                executable = path not in DOCUMENTS
                bundle.addfile(member(f"{name}/{path}", len(data), 0o755 if executable else 0o644), io.BytesIO(data))
    return archive


def recheck(archive: Path, files: list[dict]) -> list[str]:
    """Open the archive as formcut's fetch does and check every recorded file."""
    with tempfile.TemporaryDirectory() as scratch:
        with tarfile.open(archive) as bundle:
            if hasattr(tarfile, "data_filter"):
                bundle.extractall(scratch, filter="data")
            else:
                bundle.extractall(scratch)  # noqa: S202 - Python older than 3.11.4; the archive was just made here
        roots = [path for path in Path(scratch).iterdir() if path.is_dir()]
        return problems(roots[0], files) if len(roots) == 1 else ["the archive does not hold exactly one folder"]


def fetch_sources(record: dict, out: Path) -> list[Path]:
    made = []
    for key, source in record.get("source", {}).items():
        if not isinstance(source, dict) or not source.get("url") or not source.get("sha256"):
            continue
        suffix = ".tar.xz" if source["url"].endswith(".tar.xz") else ".tar.gz"
        target = out / f"{key}-{source.get('version', 'source')}{suffix}"
        print(f"  downloading {source['url']}")
        with urllib.request.urlopen(source["url"], timeout=120) as response, target.open("wb") as handle:  # noqa: S310 - fixed https URLs from the record
            for block in iter(lambda response=response: response.read(1 << 20), b""):
                handle.write(block)
        if digest(target) != source["sha256"]:
            target.unlink()
            raise SystemExit(f"{key} source does not match the record's SHA-256; upstream changed it, so nothing was kept")
        made.append(target)
    return made


def notes(record: dict, version: str, packed: list[str], skipped: list[str], sources: list[Path]) -> str:
    lines = [
        f"# ffmpeg {version} (LGPL) for formcut",
        "",
        "Built with `--disable-gpl --disable-nonfree`: ffmpeg is LGPL-2.1-or-later, libopus and libvpx are BSD-3-Clause.",
        "formcut fetches the archive for its machine on first run and checks every file against the SHA-256 in",
        "`ffmpeg-licence.json`, which formcut carries; a file that differs means nothing is installed.",
        "",
        "| Target | Archive | Minimum OS |",
        "| --- | --- | --- |",
    ]
    for triple in packed:
        minimum = str(record["targets"][triple].get("minimum_os") or "").split(" (")[0]
        lines.append(f"| {triple} | `ffmpeg-lgpl-{version}-{triple}.tar.gz` | {minimum} |")
    if skipped:
        lines += ["", "Not in this upload yet: " + ", ".join(f"`{triple}`" for triple in skipped) + "."]
    if sources:
        lines += ["", "The source these were built from is attached: " + ", ".join(f"`{path.name}`" for path in sources) + "."]
    lines += ["", "Verify with `sha256sum -c SHA256SUMS` (on macOS, `shasum -a 256 -c SHA256SUMS`)."]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--binaries", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=HERE / "dist")
    parser.add_argument("--sources", action="store_true", help="download and check the upstream source tarballs too")
    args = parser.parse_args()
    record = json.loads((HERE / "ffmpeg-licence.json").read_text(encoding="utf-8"))
    for document, expected in record.get("documents", {}).items():
        if digest(HERE / document) != expected:
            raise SystemExit(f"{document} here does not match the record")
    version = record["source"]["ffmpeg"]["version"]
    args.out.mkdir(parents=True, exist_ok=True)
    packed, skipped = [], []
    for triple, target in record["targets"].items():
        files = target.get("files") or []
        if not files or not any((args.binaries / entry["path"]).is_file() for entry in files):
            skipped.append(triple)
            continue
        found = problems(args.binaries, files)
        if found:
            raise SystemExit(f"{triple}: " + "; ".join(found))
        archive = pack(args.binaries, triple, files, version, args.out)
        found = recheck(archive, files)
        if found:
            raise SystemExit(f"{archive.name}: " + "; ".join(found))
        packed.append(triple)
        print(f"  packed {archive.name}: {len(files)} files, each matching the record")
    sources = fetch_sources(record, args.out) if args.sources else []
    (args.out / "RELEASE_NOTES.md").write_text(notes(record, version, packed, skipped, sources), encoding="utf-8")
    made = sorted(path for path in args.out.iterdir() if path.name not in ("SHA256SUMS", "RELEASE_NOTES.md"))
    (args.out / "SHA256SUMS").write_text("".join(f"{digest(path)}  {path.name}\n" for path in made), encoding="utf-8")
    if skipped:
        print("  not packed, no files for: " + ", ".join(skipped))
    print(f"  wrote {len(made)} files, SHA256SUMS and RELEASE_NOTES.md to {args.out}")
    return 0 if packed else 1


if __name__ == "__main__":
    sys.exit(main())
