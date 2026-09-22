# formcut-binaries

The LGPL ffmpeg builds formcut uses, published as release archives, one per
platform. formcut does not ship ffmpeg inside its installers: on first run, when
no ffmpeg is found, it downloads the archive for its machine from a release
here and checks every file against the SHA-256 recorded in
[`ffmpeg-licence.json`](ffmpeg-licence.json), a copy of which formcut carries. If
one file differs, nothing is installed.

This repository holds text only. The binaries live on the
[releases](https://github.com/nodemode-ai/formcut-binaries/releases) page, never
in the git history.

## What a release holds

A release is tagged `ffmpeg-<release>`: the FFmpeg version, as in `ffmpeg-7.1.5`, or that version with a rebuild number when the same FFmpeg is built again, as in `ffmpeg-7.1.5-2`, so a published release is never replaced. The record's `release` field holds the name, and `update_record.py` writes it with each build's files. A release carries:

| Asset | What it is |
| --- | --- |
| `ffmpeg-lgpl-7.1.5-aarch64-apple-darwin.tar.gz` | macOS, Apple silicon |
| `ffmpeg-lgpl-7.1.5-x86_64-apple-darwin.tar.gz` | macOS, Intel |
| `ffmpeg-lgpl-7.1.5-x86_64-unknown-linux-gnu.tar.gz` | Linux, x86_64 |
| `ffmpeg-lgpl-7.1.5-x86_64-pc-windows-msvc.tar.gz` | Windows, x86_64 |
| `ffmpeg-7.1.5.tar.xz`, `libopus-1.6.1.tar.gz`, `libvpx-1.17.0.tar.gz` | the source these were built from |
| `SHA256SUMS` | the SHA-256 of every asset |

Each archive holds one folder of the same name:

```
ffmpeg-lgpl-7.1.5-<triple>/
  ffmpeg-<triple>          (ffmpeg-<triple>.exe on Windows)
  ffprobe-<triple>
  lib-<triple>/            the seven FFmpeg libraries, found through a relative path
  LGPL-2.1.txt
  THIRD-PARTY-NOTICES.txt
  ffmpeg-licence.json
```

formcut builds the download address as
`https://github.com/nodemode-ai/formcut-binaries/releases/download/ffmpeg-<version>/ffmpeg-lgpl-<version>-<triple>.tar.gz`,
so the tag and the file names must be exactly these. `FORMCUT_FFMPEG_RELEASE`
points formcut at a mirror holding the same files.

## Licences

ffmpeg is built with `--disable-gpl --disable-nonfree`, so it is
**LGPL-2.1-or-later** ([`LGPL-2.1.txt`](LGPL-2.1.txt)); libopus and libvpx,
built into libavcodec, are **BSD-3-Clause**
([`THIRD-PARTY-NOTICES.txt`](THIRD-PARTY-NOTICES.txt)). The libraries are shared
and found through a relative path, so they can be replaced, as the LGPL
requires. formcut runs ffmpeg as a separate program, which is why formcut
itself stays Apache-2.0. The exact source is attached to each release, and the
record names every upstream download, its SHA-256 and the configure line of
each target.

The scripts and documents of this repository are Apache-2.0 ([`LICENSE`](LICENSE)).

## Publishing a build

1. Put the builds in one folder the way formcut's `src-tauri/binaries` holds
   them: `ffmpeg-<triple>`, `ffprobe-<triple>` and `lib-<triple>/` per target.
2. Copy formcut's `src-tauri/binaries/ffmpeg-licence.json` here if it changed.
   It must be the record formcut ships, since that is what the fetch checks.
3. Pack and check:

   ```
   python pack_release.py --binaries path/to/binaries --sources
   ```

   Every recorded file must match its SHA-256 or nothing is packed. The
   archives are reproducible, so packing the same files again gives the same
   hashes. The results go to `dist/`, which git ignores.
4. Publish, as a release rather than a draft, since formcut downloads
   anonymously:

   ```
   gh release create ffmpeg-7.1.5 dist/* --title "ffmpeg 7.1.5 (LGPL) for formcut" --notes-file dist/RELEASE_NOTES.md
   ```

   or on github.com: Releases, Draft a new release, tag `ffmpeg-7.1.5`, attach
   everything in `dist/`, Publish.

Never replace an asset under a tag that has been published. formcut pins every
file by hash, so a changed build goes out as a new record in formcut and a new
tag here.

## Checking a download

```
sha256sum -c SHA256SUMS              # Linux
shasum -a 256 -c SHA256SUMS          # macOS
```
