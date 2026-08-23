# Submission notes

Working notes for the marketplace listing. Not part of the plugin's runtime.

`omarchy plugin validate .` exits 0. `scripts/preflight.sh` reports three areas;
all three are explained below rather than silenced, because each is either the
accepted pattern or a false positive on a comment.

## Suggested listing metadata

| Field | Value |
|---|---|
| Category | `Widgets` |
| Tags | `bar, quickshell` |
| Title | `[Plugin]: Night Sky` |

**The submission issue has not been opened.** The marketplace's guidance for
agents is that only the owner may confirm the ownership statement and the
checklist, so that step is left to you.

The repository is `https://github.com/kairos-tech-oh/omarchy-nightsky-plugin`,
which is what the README install instructions and the Nominatim User-Agent in
`Panel.qml:78` both point at. Submit the **root** URL — no trailing slash and no
`/tree/main`, both of which the marketplace rejects.

If the repository is ever renamed or moved, the User-Agent has to move with it:
OpenStreetMap's policy requires it to identify the application, and a link to a
repository that no longer exists does not.

## Preflight area 1 — text crossing into shell-owned AutoText sinks

    ./BarWidget.qml:65  WidgetButton { text: ... .label }
    ./BarWidget.qml:66  WidgetButton { tooltipText: ... .tooltip }
    ./Panel.qml:658     Button { text: root.settingsOpen ? "⚙ Close" : "⚙ Settings" }
    ./Panel.qml:919     Button { text: modelData.label }
    ./Panel.qml:1010    Button { text: root.searching ? "⌕ …" : "⌕ Search" }

Confirmed and handled. This was verified on this system, not assumed:
`/usr/share/omarchy/shell/Ui/PanelToolTip.qml:38` renders `contentItem: Text`
with no `textFormat` at all, so it falls back to `Text.AutoText`. The same is
true of `Ui/WidgetButton.qml` and `plugins/bar/Bar.qml`. `textFormat:
Text.PlainText` on the plugin's own elements does not cover any of them.

Taking the five lines in turn:

- **`Panel.qml:658` and `:1010`** are plugin-authored string literals with no
  input of any kind. `Panel.qml:919` reads `modelData.label` from a literal array
  declared four lines above it in the same file (`"Lines"`, `"Names"`,
  `"Planets"`, `"Milky Way"`). None of the three can carry upstream data.
- **`BarWidget.qml:65` and `:66`** are the real boundary. `label` and `tooltip`
  are both wrapped wholesale in `Sanitise.plainOneLine()` at the point they are
  exported — not field by field — so a part added to either later is covered
  without anyone having to remember. Today only `tooltip` actually carries remote
  text (the city name from ipwho.is, the `display_name` from Nominatim); `label`
  is wrapped anyway, because the point is that the boundary is guarded rather
  than that the current contents happen to be safe.

The values are additionally sanitised **at ingestion**, in all four places where
remote text enters (`Panel.qml`, in the ipwho.is, Nominatim and Open-Meteo
handlers), so the panel's own `Text` elements receive clean strings too.

`Sanitise.plainOneLine()` strips `<`, `>` **and** `&`. The ampersand is not
incidental: removing only the brackets still leaves `&#60;` and `&lt;`, which the
rich-text engine decodes back into a bracket. It also collapses control
characters — which would otherwise let one field forge what looks like a second
line of the display — and length-caps the result.

It lives in its own file specifically so it can be tested, and it is, under both
engines, against the payload from marketplace issue #1566:

    <img src="http://127.0.0.1:9/x.png" width="300" height="40">Springfield

`tools/check-skymath.js` runs 12 sanitiser assertions under Node;
`tools/check-qml-engine.qml` re-runs the same payloads under Qt's V4 engine,
because Node passing is not evidence about V4. Both confirm no `<`, `>`, `&`, or
newline survives, that ordinary place names (`Westerville, Ohio`, `Tromsø`,
`東京都`, `Saint-Étienne`) pass through byte-identical, and that `null` and
`undefined` flatten rather than throw.

## Preflight area 2 — `StdioCollector`

    ./Panel.qml:449, :502, :533

This is the accepted pattern, not an unbounded read. Every one of the three
processes is launched through `cappedCurl()` (`Panel.qml:274`), which caps at the
**producer**:

```sh
timeout -k 2 <deadline> sh -c 'cap="$1"; shift; curl "$@" | head -c "$cap"' sh <cap+1> -fsSL --max-time <inner>
```

- `head -c` closes the pipe at the byte ceiling before `StdioCollector` can hold
  more than that, so no check inside `onStreamFinished` is being relied on.
- `cap+1` bytes are requested, not `cap`, so a body sitting exactly at the
  ceiling stays distinguishable from one that was truncated.
- `timeout` is the deadline that still applies while curl is blocked in a
  syscall; curl's `--max-time` is the inner limit. Both are clamped to a minimum
  of 1, because `timeout 0` means *no limit*.
- The URL and every curl option travel as argv entries. Nothing is spliced into
  the script text.

Caps are 64 KiB each, sized from measured replies: ipwho.is returns 963 bytes,
Nominatim 3.0 KiB at `limit=5`, Open-Meteo 180 bytes for a bare timezone lookup.
That is at least twenty times the largest.

Collections are bounded independently of bytes: the Nominatim handler applies
`.slice(0, 5)` to whatever comes back, because `limit=5` is a request to the
server and not a guarantee.

`Panel.qml:280` is a comment explaining the above, matched by the same grep.

## Preflight area 3 — `FileView`

    ./tools/build-catalog.py:351

False positive. That line is prose in a docstring explaining *why this plugin
does not use `FileView`*. The plugin performs **no runtime file I/O at all** —
no `FileView`, no state file, no cache, no temporary directory.

The bundled sky data is a `.pragma library` JavaScript resource loaded by the QML
engine, precisely because the plugin directory lives under `$HOME` and is
therefore user-writable, which is where `FileView` is disallowed for exposing no
bounded read. Shipping the data as code removes the question rather than
answering it. Full reasoning in `data/PROVENANCE.md`.

## Review capabilities: none

No installer, no package manager, no privilege escalation, no remote build, no
bundled executable binary, no service management, no sudoers modification. No
`sudo`, no systemd units, no Hyprland keybind edits.

Because the plugin writes nothing to disk, the findings around predictable paths,
symlink-redirected truncation, TOCTOU check-then-reopen, and untrusted fields
becoming path components have no surface here. There are no PIDs stored and no
signals sent.

Settings persist through the shell's own config store via `updateEntryInline`,
the same mechanism every other widget uses.

## Bundled data provenance

`data/Catalog.js` (197,017 bytes) is generated, not authored. It is **text, not a
binary**, so it does not trigger `bundled-executable-binary`.

- Source: [d3-celestial](https://github.com/ofrohn/d3-celestial), BSD-3-Clause,
  © 2015 Olaf Frohn — one permissively licensed upstream for all four datasets.
- Pinned at the full 40-character commit
  `7e720a3de062059d4c5400a379146a601d9010e0`, never a branch.
- SHA-256 of all six upstream inputs recorded in `tools/build-catalog.py` and
  verified on every run; the generator refuses to continue on a mismatch.
- SHA-256 of the output recorded in `data/PROVENANCE.md`:
  `d12cbc06c2141a4e8c13cb5898be06430c920baebbda55ed27ea4b690d67bc75`
- `python3 tools/build-catalog.py --check` rebuilds from upstream and exits 0
  only on a byte-for-byte match. `tools/run-checks.sh` runs it first.

Stellarium's `constellationship.fab` (GPLv2) and the HYG database (CC BY-SA) were
both rejected as sources on licence-compatibility grounds.

## Rate limits

Three endpoints, all key-free. Documented in the README with the published limit
against the actual call rate for each.

The Nominatim ceiling of one request per second is the strictest, and is kept
three ways: search fires only on Enter or the Search button and never per
keystroke (the policy forbids client-side auto-complete outright); a 1,100 ms
floor queues anything sooner, with a single queued flag so repeated clicks
collapse to one request; and an identical repeat query is answered from the
results already held rather than re-sent, as the policy requires. The request
carries a User-Agent identifying the plugin and linking to the repository.

Measured: with the panel open for 90 seconds, sampling the shell's child
processes twice a second, this plugin issued **zero** requests. The chart redraw,
the sun and moon times, and every setting are entirely local.

## Verification performed

- `omarchy plugin validate .` → exit 0
- `tools/run-checks.sh` → 77/77, plus all V4 engine checks
- Sunrise/sunset within 63 s of Open-Meteo across 30 events, latitudes −34° to
  +64°; planets within 5.0 arcmin of JPL Horizons; Moon within 28 arcmin
- Polar day and polar night at Tromsø report a state rather than a NaN time
- Loaded in a hard-refreshed shell (qmlcache dropped, `omarchy restart shell`)
  and confirmed: bar label, panel, chart, IP geolocation, hover identification
- Charts cross-checked against known sky positions for Ohio in August and
  January and for Sydney — Summer Triangle at zenith, Orion in winter, Southern
  Cross and Scorpius from the southern hemisphere
