"""Record a staged build of one target in ffmpeg-licence.json.

Everything is read from the staged files themselves, so no checksum or
dependency is typed by hand: each shipped file's size and SHA-256, the
configure line FFmpeg compiles into libavutil, the system libraries the
programs and libraries import (the bundled ones left out), and the SHA-256 of
the licence documents shipped beside them. The release name, which tags the
GitHub release and names its archives, is set with --release.

  python update_record.py --binaries STAGED --triple x86_64-unknown-linux-gnu \\
      --release 7.1.5-2 --toolchain "gcc 11.4.0 (Ubuntu 22.04, GitHub Actions)" \\
      --check "ran ffmpeg -version" --check "every library loads from the bundle"

STAGED holds ffmpeg-<triple>, ffprobe-<triple>, lib-<triple>/ and the
documents, as pack_release.py expects. Needs objdump, and for Windows
x86_64-w64-mingw32-objdump.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
RECORD = HERE / "ffmpeg-licence.json"
DOCUMENTS = ("LGPL-2.1.txt", "THIRD-PARTY-NOTICES.txt")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def shipped(folder: Path, triple: str) -> list[Path]:
    """The programs, then every library in lib-<triple>/, as they ship."""
    suffix = ".exe" if "windows" in triple else ""
    programs = [folder / f"{name}-{triple}{suffix}" for name in ("ffmpeg", "ffprobe")]
    missing = [path.name for path in programs if not path.is_file()]
    if missing:
        raise SystemExit(f"not staged: {', '.join(missing)}")
    return programs + sorted(path for path in (folder / f"lib-{triple}").iterdir() if path.is_file())


def configure_line(libraries: list[Path]) -> str:
    """The configure line FFmpeg compiles into libavutil."""
    avutil = next(path for path in libraries if "avutil" in path.name)
    found = re.search(rb"--prefix=[^\x00]+", avutil.read_bytes())
    if not found:
        raise SystemExit(f"no configure line in {avutil.name}")
    return found.group(0).decode("utf-8", "replace")


def imports(paths: list[Path], triple: str) -> list[str]:
    """System libraries imported by the shipped files, the bundled ones left out."""
    windows = "windows" in triple
    tool = "x86_64-w64-mingw32-objdump" if windows else "objdump"
    pattern = re.compile(r"DLL Name: (\S+)" if windows else r"NEEDED\s+(\S+)")
    bundled = {path.name.lower() for path in paths}
    found = set()
    for path in paths:
        dump = subprocess.run([tool, "-p", str(path)], capture_output=True, text=True, check=True).stdout
        found.update(name for name in pattern.findall(dump) if name.lower() not in bundled)
    return sorted(found, key=str.lower)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binaries", type=Path, required=True)
    parser.add_argument("--triple", required=True)
    parser.add_argument("--release", required=True, help="the release name: tags the release and names its archives")
    parser.add_argument("--toolchain", required=True)
    parser.add_argument("--check", action="append", default=[], help="a verification made on this build; repeat for each")
    args = parser.parse_args()

    record = json.loads(RECORD.read_text(encoding="utf-8"))
    target = record["targets"].get(args.triple)
    if target is None:
        raise SystemExit(f"{args.triple} is not a target in the record")
    paths = shipped(args.binaries, args.triple)
    libraries = paths[2:]
    target["files"] = [
        {"path": path.relative_to(args.binaries).as_posix(), "sha256": digest(path), "bytes": path.stat().st_size} for path in paths
    ]
    target["configure"] = configure_line(libraries)
    target["system_libraries_needed"] = imports(paths, args.triple)
    target["toolchain"] = args.toolchain
    target["verification"] = {"method": "executed" if "windows" not in args.triple else "inspected", "checks": args.check}
    target["status"] = "shipped"
    record["release"] = args.release
    record["documents"] = {name: digest(args.binaries / name) for name in DOCUMENTS}
    record["written_utc"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    RECORD.write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"recorded {args.triple}: {len(paths)} files, {len(target['system_libraries_needed'])} system imports, release {args.release}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
