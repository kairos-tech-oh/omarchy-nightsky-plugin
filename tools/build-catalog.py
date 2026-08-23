#!/usr/bin/env python3
"""Regenerate data/Catalog.js from the pinned d3-celestial snapshot.

The night-sky plugin draws the entire sky offline, which means the star
positions, constellation figures, Milky Way outline and planetary elements ship
with the plugin rather than arriving over the network. This script is how those
bytes are produced, and it exists so a reviewer never has to take the generated
file on faith: it downloads the six upstream files at one immutable commit,
refuses to continue if any of them hashes differently than recorded, and writes
a deterministic Catalog.js whose own SHA-256 is printed at the end.

    python3 tools/build-catalog.py            # rebuild and verify
    python3 tools/build-catalog.py --check    # rebuild to a temp file and diff

Upstream: https://github.com/ofrohn/d3-celestial  (BSD-3-Clause, (c) 2015 Olaf Frohn)
"""

import argparse
import hashlib
import json
import math
import os
import sys
import tempfile
import urllib.request

# An immutable 40-character commit, never a branch name. A branch would let the
# bytes this script produces change without the pinned digests below changing,
# which is precisely the provenance gap the marketplace rejects submissions for.
UPSTREAM_REPO = "ofrohn/d3-celestial"
UPSTREAM_COMMIT = "7e720a3de062059d4c5400a379146a601d9010e0"
RAW_BASE = "https://raw.githubusercontent.com/%s/%s/data/" % (UPSTREAM_REPO, UPSTREAM_COMMIT)

# SHA-256 of each upstream input as fetched at UPSTREAM_COMMIT. Run with
# --record to regenerate this block after a deliberate upstream bump.
INPUT_DIGESTS = {
    "stars.6.json": "0297b8fa3adfbce1dc26566f61c4abcc1df4f29c6a28729ca06b56d1c6d25602",
    "starnames.json": "19c84bc885f8a97c3b8e1f6a380084c575a9758dedfe35256e911a823ec3a695",
    "constellations.lines.json": "294f66bef5d5cf50b1e17f16d2efa1d97a15131612c68dd935adef6e7373e13c",
    "constellations.json": "ab4ae692027cbc042c0d6791a84456a65eb7c55656107fd00c58ff6e55d4d8b2",
    "mw.json": "aee221a7a0e879418e685de00c3e68fbdfac5667c0a8aab74929ef9cf4aab4fb",
    "planets.json": "5fca7ea95880f6feeaab75f306a058aa36f86deedd45ec82cd37e48d20899953",
}

# Retention ceilings. These are the same numbers Catalog.js asserts and
# SkyChart.qml re-checks at load: a cap that only exists in the generator is a
# cap the running shell does not have.
MAX_STARS = 6000
MAX_SEGMENTS = 1200
MAX_MW_VERTICES = 5000

# Douglas-Peucker tolerance for the Milky Way contours, in degrees. The chart is
# an all-sky circle roughly 380px across, so 90 degrees of altitude span ~190px
# and a quarter degree is about half a pixel -- below what anyone can resolve.
#
# This value was tuned by eye rather than guessed. At 1.0 degrees the band is
# visibly faceted along its edges; 0.25 renders smooth, keeps the Great Rift,
# the Sagittarius star clouds and both Magellanic Clouds, and still cuts 30,676
# upstream vertices to 2,441 -- half the MAX_MW_VERTICES ceiling.
MW_TOLERANCE_DEG = 0.25

# Naked-eye planets, plus Earth -- which is not drawn but is required to convert
# heliocentric positions to geocentric ones. Uranus and Neptune are omitted
# deliberately: at magnitude 5.7 and 7.8 they are not "naked-eye" in any sky a
# desktop user is standing under.
PLANET_IDS = ["mer", "ven", "ter", "mar", "jup", "sat"]

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(HERE, os.pardir, "data", "Catalog.js")


# --------------------------------------------------------------------------
# fetching
# --------------------------------------------------------------------------

def fetch(name):
    """Download one upstream file and return its raw bytes."""
    url = RAW_BASE + name
    sys.stderr.write("  fetching %s\n" % name)
    request = urllib.request.Request(url, headers={"User-Agent": "night-sky-build-catalog"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def load_inputs(record):
    """Fetch every input, verify its digest, and return the parsed JSON."""
    parsed = {}
    digests = {}
    for name in INPUT_DIGESTS:
        raw = fetch(name)
        digest = hashlib.sha256(raw).hexdigest()
        digests[name] = digest
        expected = INPUT_DIGESTS[name]
        if not record:
            if not expected:
                sys.exit("no recorded digest for %s -- run with --record first" % name)
            if digest != expected:
                sys.exit(
                    "digest mismatch for %s\n  expected %s\n  got      %s\n"
                    "Upstream content changed under the pinned commit, which should be "
                    "impossible; do not ship this output." % (name, expected, digest))
        parsed[name] = json.loads(raw.decode("utf-8"))

    if record:
        sys.stderr.write("\nrecorded digests -- paste into INPUT_DIGESTS:\n\n")
        for name in sorted(digests):
            sys.stderr.write('    "%s": "%s",\n' % (name, digests[name]))
        sys.stderr.write("\n")
    return parsed


# --------------------------------------------------------------------------
# geometry helpers
# --------------------------------------------------------------------------

def to_vector(lon_deg, lat_deg):
    """Spherical degrees to a unit vector.

    Simplification runs in 3D rather than on raw longitude/latitude for two
    reasons: the upstream rings cross the +/-180 seam (consecutive vertices
    differing by 359.88 degrees are really 0.12 degrees apart), and a degree of
    longitude near the pole is a tiny fraction of a degree on the sky. Chord
    distance between unit vectors has neither problem.
    """
    lon = math.radians(lon_deg)
    lat = math.radians(lat_deg)
    cos_lat = math.cos(lat)
    return (cos_lat * math.cos(lon), cos_lat * math.sin(lon), math.sin(lat))


def perpendicular_chord(point, start, end):
    """Distance from `point` to the great-circle segment start->end, as a chord."""
    normal = (
        start[1] * end[2] - start[2] * end[1],
        start[2] * end[0] - start[0] * end[2],
        start[0] * end[1] - start[1] * end[0],
    )
    norm = math.sqrt(normal[0] ** 2 + normal[1] ** 2 + normal[2] ** 2)
    if norm < 1e-12:
        # Degenerate segment: the endpoints coincide, so fall back to the
        # straight-line distance to the start point.
        return math.dist(point, start)
    unit = (normal[0] / norm, normal[1] / norm, normal[2] / norm)
    return abs(point[0] * unit[0] + point[1] * unit[1] + point[2] * unit[2])


def simplify(ring, tolerance_chord):
    """Iterative Douglas-Peucker. Iterative rather than recursive so a
    pathological ring cannot exhaust the interpreter stack."""
    if len(ring) < 3:
        return list(ring)
    vectors = [to_vector(lon, lat) for lon, lat in ring]
    keep = [False] * len(ring)
    keep[0] = keep[-1] = True
    stack = [(0, len(ring) - 1)]
    while stack:
        first, last = stack.pop()
        if last <= first + 1:
            continue
        worst_index, worst = -1, 0.0
        for i in range(first + 1, last):
            distance = perpendicular_chord(vectors[i], vectors[first], vectors[last])
            if distance > worst:
                worst_index, worst = i, distance
        if worst > tolerance_chord:
            keep[worst_index] = True
            stack.append((first, worst_index))
            stack.append((worst_index, last))
    return [ring[i] for i in range(len(ring)) if keep[i]]


def round_pair(lon, lat):
    """Three decimals is 3.6 arcseconds -- far finer than a one-pixel chart cell,
    and it cuts the emitted file roughly in half against full float repr."""
    return [round(float(lon), 3), round(float(lat), 3)]


def flatten(points):
    flat = []
    for lon, lat in points:
        flat.extend(round_pair(lon, lat))
    return flat


# --------------------------------------------------------------------------
# transforms
# --------------------------------------------------------------------------

def build_stars(stars_json, names_json):
    """Flat [ra, dec, mag, bv] quadruples, brightest first.

    Sorting by magnitude is not cosmetic: it lets the renderer honour a
    magnitude limit by stopping the loop early instead of testing all 5,044
    entries every repaint.
    """
    records = []
    for feature in stars_json["features"]:
        properties = feature["properties"]
        magnitude = properties.get("mag")
        longitude, latitude = feature["geometry"]["coordinates"]
        if magnitude is None:
            continue
        try:
            # Two upstream entries carry an empty B-V. 0.0 is the colour of an
            # A0 star -- plain white, the least wrong guess for an unknown.
            colour_index = float(properties.get("bv") or 0.0)
        except (TypeError, ValueError):
            colour_index = 0.0
        records.append((float(magnitude), float(longitude), float(latitude),
                        colour_index, str(feature.get("id"))))

    records.sort(key=lambda record: record[0])
    if len(records) > MAX_STARS:
        sys.exit("star count %d exceeds MAX_STARS %d" % (len(records), MAX_STARS))

    flat = []
    named_index = []
    named_text = []
    for index, (magnitude, longitude, latitude, colour_index, hip) in enumerate(records):
        flat.extend(round_pair(longitude, latitude))
        flat.append(round(magnitude, 2))
        flat.append(round(colour_index, 3))
        entry = names_json.get(hip)
        if entry:
            proper = (entry.get("name") or "").strip()
            if proper:
                named_index.append(index)
                named_text.append(proper)
    return len(records), flat, named_index, named_text


def build_constellation_lines(lines_json):
    """One entry per constellation: [abbreviation, flatSegment, flatSegment, ...]."""
    out = []
    segments = 0
    for feature in lines_json["features"]:
        entry = [str(feature["id"])]
        for segment in feature["geometry"]["coordinates"]:
            if len(segment) < 2:
                continue
            entry.append(flatten(segment))
            segments += 1
        if len(entry) > 1:
            out.append(entry)
    if segments > MAX_SEGMENTS:
        sys.exit("segment count %d exceeds MAX_SEGMENTS %d" % (segments, MAX_SEGMENTS))
    return out, segments


def build_constellations(constellations_json):
    """[abbreviation, English name, labelRA, labelDec, rank].

    Only the English name survives. Upstream carries about 25 translations per
    constellation, which is most of that file's 49 KiB and none of its use here.
    """
    out = []
    for feature in constellations_json["features"]:
        properties = feature["properties"]
        longitude, latitude = feature["geometry"]["coordinates"]
        try:
            rank = int(properties.get("rank", 3))
        except (TypeError, ValueError):
            rank = 3
        out.append([
            str(feature["id"]),
            str(properties.get("en") or properties.get("name") or feature["id"]),
            round(float(longitude), 2),
            round(float(latitude), 2),
            rank,
        ])
    return out


def build_milky_way(mw_json):
    """Nested brightness contours, simplified, outermost (faintest) first."""
    tolerance_chord = 2.0 * math.sin(math.radians(MW_TOLERANCE_DEG) / 2.0)
    layers = []
    before = 0
    after = 0
    for feature in mw_json["features"]:
        geometry = feature["geometry"]
        if geometry["type"] == "MultiPolygon":
            polygons = geometry["coordinates"]
        elif geometry["type"] == "Polygon":
            polygons = [geometry["coordinates"]]
        else:
            continue
        rings = []
        for polygon in polygons:
            for ring in polygon:
                before += len(ring)
                reduced = simplify(ring, tolerance_chord)
                # A ring that simplifies below a triangle encloses no area worth
                # filling; dropping it is cheaper than drawing a degenerate path.
                if len(reduced) < 3:
                    continue
                after += len(reduced)
                rings.append(flatten(reduced))
        if rings:
            layers.append(rings)
    if after > MAX_MW_VERTICES:
        sys.exit("Milky Way vertex count %d exceeds MAX_MW_VERTICES %d -- raise "
                 "MW_TOLERANCE_DEG" % (after, MAX_MW_VERTICES))
    return layers, before, after


def build_planets(planets_json):
    """JPL approximate Keplerian elements for the naked-eye planets plus Earth."""
    out = []
    for identifier in PLANET_IDS:
        source = planets_json.get(identifier)
        if not source:
            sys.exit("planet %s missing from upstream planets.json" % identifier)
        elements = source["elements"][0]
        required = ("a", "e", "i", "L", "W", "N", "da", "de", "di", "dL", "dW", "dN")
        missing = [key for key in required if key not in elements]
        if missing:
            sys.exit("planet %s missing elements %s" % (identifier, missing))
        if elements.get("ep") != "2000-01-01":
            sys.exit("planet %s is not on the J2000 epoch this build assumes" % identifier)
        out.append({
            "id": identifier,
            "name": str(source.get("en") or source.get("name") or identifier),
            "sym": str(source.get("sym") or ""),
            "h": float(source.get("H", 0.0)),
            "a": float(elements["a"]), "e": float(elements["e"]),
            "i": float(elements["i"]), "l": float(elements["L"]),
            "w": float(elements["W"]), "n": float(elements["N"]),
            "da": float(elements["da"]), "de": float(elements["de"]),
            "di": float(elements["di"]), "dl": float(elements["dL"]),
            "dw": float(elements["dW"]), "dn": float(elements["dN"]),
        })
    return out


# --------------------------------------------------------------------------
# emit
# --------------------------------------------------------------------------

def compact(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def render(data):
    """Assemble Catalog.js.

    `.pragma library` matters twice over. It makes this a shared, engine-loaded
    JavaScript resource -- so the catalogue is parsed once for the whole shell
    rather than per widget instance -- and it means the plugin never reads a
    file at runtime. The plugin directory sits under $HOME and is therefore
    user-writable, which is exactly where FileView is disallowed for having no
    bounded read; importing the data as code removes the question rather than
    answering it.
    """
    lines = []
    add = lines.append
    add(".pragma library")
    add("")
    add("// GENERATED FILE -- do not edit by hand.")
    add("// Rebuild with:  python3 tools/build-catalog.py")
    add("//")
    add("// Source: https://github.com/%s" % UPSTREAM_REPO)
    add("// Commit: %s" % UPSTREAM_COMMIT)
    add("// License: BSD-3-Clause, (c) 2015 Olaf Frohn. Full text in data/PROVENANCE.md,")
    add("// which also records the SHA-256 of every upstream input.")
    add("")
    add('var UPSTREAM_COMMIT = "%s"' % UPSTREAM_COMMIT)
    add("")
    add("// Retention ceilings, restated here so the values the renderer clamps")
    add("// against travel with the data instead of drifting from it.")
    add("var MAX_STARS = %d" % MAX_STARS)
    add("var MAX_SEGMENTS = %d" % MAX_SEGMENTS)
    add("var MAX_MW_VERTICES = %d" % MAX_MW_VERTICES)
    add("")
    add("// Stars, brightest first, four numbers each:")
    add("//   right ascension (degrees, -180..180), declination (degrees),")
    add("//   visual magnitude, B-V colour index.")
    add("// Magnitude order lets a magnitude limit stop the draw loop early.")
    add("var STAR_COUNT = %d" % data["star_count"])
    add("var STARS = %s" % compact(data["stars"]))
    add("")
    add("// Proper names, as parallel arrays indexed by star record number.")
    add("var NAMED_INDEX = %s" % compact(data["named_index"]))
    add("var NAMED_TEXT = %s" % compact(data["named_text"]))
    add("")
    add("// Constellation figures: [abbreviation, flatSegment, flatSegment, ...]")
    add("// where each segment is a flat run of ra,dec pairs to be polylined.")
    add("var CONSTELLATION_LINES = %s" % compact(data["lines"]))
    add("")
    add("// Label anchors: [abbreviation, name, labelRA, labelDec, rank]")
    add("var CONSTELLATIONS = %s" % compact(data["constellations"]))
    add("")
    add("// Milky Way brightness contours, faintest layer first; each layer is a")
    add("// list of closed rings of flat ra,dec pairs. Simplified at %.1f degrees." % MW_TOLERANCE_DEG)
    add("var MILKY_WAY = %s" % compact(data["milky_way"]))
    add("")
    add("// JPL approximate Keplerian elements, epoch J2000, rates per Julian")
    add("// century. Earth ('ter') is present to convert heliocentric positions")
    add("// to geocentric ones and is never drawn.")
    add("var PLANETS = %s" % compact(data["planets"]))
    add("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", action="store_true",
                        help="print the digests of the fetched inputs instead of verifying them")
    parser.add_argument("--check", action="store_true",
                        help="build to a temporary file and report whether it matches the committed one")
    args = parser.parse_args()

    sys.stderr.write("d3-celestial @ %s\n" % UPSTREAM_COMMIT[:12])
    inputs = load_inputs(args.record)
    if args.record:
        return 0

    star_count, stars, named_index, named_text = build_stars(
        inputs["stars.6.json"], inputs["starnames.json"])
    lines, segment_count = build_constellation_lines(inputs["constellations.lines.json"])
    constellations = build_constellations(inputs["constellations.json"])
    milky_way, mw_before, mw_after = build_milky_way(inputs["mw.json"])
    planets = build_planets(inputs["planets.json"])

    text = render({
        "star_count": star_count, "stars": stars,
        "named_index": named_index, "named_text": named_text,
        "lines": lines, "constellations": constellations,
        "milky_way": milky_way, "planets": planets,
    })
    encoded = text.encode("utf-8")

    sys.stderr.write("\n")
    sys.stderr.write("  stars                %d (%d named)\n" % (star_count, len(named_index)))
    sys.stderr.write("  constellations       %d figures, %d segments\n" % (len(lines), segment_count))
    sys.stderr.write("  labels               %d\n" % len(constellations))
    sys.stderr.write("  milky way            %d layers, %d vertices (from %d, %.1fx)\n"
                     % (len(milky_way), mw_after, mw_before, mw_before / float(max(1, mw_after))))
    sys.stderr.write("  planets              %d (incl. Earth)\n" % len(planets))
    sys.stderr.write("  Catalog.js           %.1f KiB\n" % (len(encoded) / 1024.0))
    sys.stderr.write("  sha256               %s\n" % hashlib.sha256(encoded).hexdigest())

    if args.check:
        with tempfile.NamedTemporaryFile("wb", suffix=".js", delete=False) as handle:
            handle.write(encoded)
            temporary = handle.name
        try:
            with open(OUT_PATH, "rb") as handle:
                committed = handle.read()
        except OSError:
            sys.stderr.write("\ncommitted Catalog.js is missing\n")
            return 1
        matches = committed == encoded
        sys.stderr.write("\n%s\n" % ("committed Catalog.js matches this build"
                                     if matches else
                                     "committed Catalog.js DIFFERS -- rebuilt copy at " + temporary))
        return 0 if matches else 1

    with open(OUT_PATH, "wb") as handle:
        handle.write(encoded)
    sys.stderr.write("\nwrote %s\n" % os.path.normpath(OUT_PATH))
    return 0


if __name__ == "__main__":
    sys.exit(main())
