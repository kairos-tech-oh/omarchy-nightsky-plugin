# Where `Catalog.js` comes from

`Catalog.js` is generated, not hand-written, and nothing in it originates with
this project. This file records exactly what went into it and how to reproduce
it, so the bundled bytes can be verified rather than trusted.

## Upstream

| | |
|---|---|
| Project | [d3-celestial](https://github.com/ofrohn/d3-celestial) |
| Author | Olaf Frohn |
| Licence | BSD-3-Clause (full text below) |
| Commit | `7e720a3de062059d4c5400a379146a601d9010e0` |

The commit is pinned as a full 40-character SHA, never a branch. A branch would
let the generated output change without anything in this repository changing,
which is the provenance gap the marketplace rejects submissions over.

d3-celestial was chosen because one permissively licensed project covers all
four datasets this plugin needs. The alternatives each carry a complication:
Stellarium's `constellationship.fab` is GPLv2, and the HYG database is
CC BY-SA — both awkward to combine with MIT-licensed code, and neither supplies
constellation figures, Milky Way contours and planetary elements together.

## Inputs and their digests

Verified on every run of `tools/build-catalog.py`, which refuses to continue on
a mismatch.

| File | SHA-256 |
|---|---|
| `stars.6.json` | `0297b8fa3adfbce1dc26566f61c4abcc1df4f29c6a28729ca06b56d1c6d25602` |
| `starnames.json` | `19c84bc885f8a97c3b8e1f6a380084c575a9758dedfe35256e911a823ec3a695` |
| `constellations.lines.json` | `294f66bef5d5cf50b1e17f16d2efa1d97a15131612c68dd935adef6e7373e13c` |
| `constellations.json` | `ab4ae692027cbc042c0d6791a84456a65eb7c55656107fd00c58ff6e55d4d8b2` |
| `mw.json` | `aee221a7a0e879418e685de00c3e68fbdfac5667c0a8aab74929ef9cf4aab4fb` |
| `planets.json` | `5fca7ea95880f6feeaab75f306a058aa36f86deedd45ec82cd37e48d20899953` |

## Output

| | |
|---|---|
| File | `data/Catalog.js` |
| Size | 197,017 bytes |
| SHA-256 | `d12cbc06c2141a4e8c13cb5898be06430c920baebbda55ed27ea4b690d67bc75` |

Contents: 5,044 stars to magnitude 6.0 (493 with proper names), 89 constellation
figures across 150 line segments, 89 label anchors, the Milky Way as 5 nested
brightness contours totalling 2,441 vertices, and JPL Keplerian elements for
Mercury through Saturn plus Earth.

## Reproducing it

```sh
python3 tools/build-catalog.py --check   # rebuild and diff against the committed file
python3 tools/build-catalog.py           # rebuild in place
```

`--check` exits 0 only when a fresh build from the pinned commit is byte-for-byte
identical to what is committed here. `tools/run-checks.sh` runs it as its first
step.

## What the generator does

Nothing is invented and nothing is corrected; the transformations are all
reductions.

- **Discards** the roughly 25 translated name fields per constellation, HD and
  Gliese cross-identifiers, and every field the renderer does not read.
- **Rounds** coordinates to three decimal places — 3.6 arcseconds, far finer
  than the chart's one-pixel-per-degree resolution.
- **Reorders** stars brightest first, so the renderer can honour a magnitude
  limit by stopping its loop rather than testing all 5,044 entries per repaint.
- **Simplifies** the Milky Way contours with Douglas–Peucker at a 0.25° tolerance,
  measured in 3D chord distance so the ±180° seam and the poles need no special
  case. This takes 30,676 vertices to 2,441. The tolerance was set by eye: at
  1.0° the band is visibly faceted, while 0.25° renders smooth and keeps the
  Great Rift, the Sagittarius star clouds and both Magellanic Clouds.
- **Asserts** the retention ceilings (`MAX_STARS`, `MAX_SEGMENTS`,
  `MAX_MW_VERTICES`) and fails the build rather than emitting more than them.

## Why a `.js` file rather than JSON

`Catalog.js` is a `.pragma library` JavaScript resource, imported by
`SkyChart.qml` and loaded by the QML engine. It is never read from disk at
runtime.

That is deliberate. The plugin directory lives under `$HOME` and is therefore
user-writable, which is exactly where `FileView` is disallowed for exposing no
bounded read — and a bounded read through a helper process would mean spawning
a subprocess and parsing 190 KiB of JSON on every load. Shipping the data as an
engine-loaded library removes the question instead of answering it: there is no
runtime file read, no `StdioCollector`, and nothing to bound.

`.pragma library` additionally means the catalogue is parsed once and shared
across every importer rather than per widget instance.

## Upstream licence

```
Copyright (c) 2015, Olaf Frohn
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the copyright holder nor the names of its contributors
  may be used to endorse or promote products derived from this software
  without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

The underlying astronomical data d3-celestial itself assembles comes from the
Hipparcos catalogue and other public sources.
