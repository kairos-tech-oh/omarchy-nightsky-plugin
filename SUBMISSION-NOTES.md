# Submission notes

Working notes for the marketplace listing. Not part of the plugin's runtime.

`omarchy plugin validate .` exits 0. `scripts/preflight.sh` reports six areas and
two capability triggers; every one is explained below rather than silenced,
because each is either the accepted pattern, a false positive on a comment, or a
hit on this notes file itself.

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
    ./Panel.qml:671     Button { text: root.settingsOpen ? "⚙ Close" : "⚙ Settings" }
    ./Panel.qml:932     Button { text: modelData.label }
    ./Panel.qml:1023    Button { text: root.searching ? "⌕ …" : "⌕ Search" }

Confirmed and handled. This was verified on this system, not assumed:
`/usr/share/omarchy/shell/Ui/PanelToolTip.qml:38` renders `contentItem: Text`
with no `textFormat` at all, so it falls back to `Text.AutoText`. The same is
true of `Ui/WidgetButton.qml` and `plugins/bar/Bar.qml`. `textFormat:
Text.PlainText` on the plugin's own elements does not cover any of them.

Taking the five lines in turn:

- **`Panel.qml:671` and `:1023`** are plugin-authored string literals with no
  input of any kind. `Panel.qml:932` reads `modelData.label` from a literal array
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

    ./Panel.qml:462, :515, :546

This is the accepted pattern, not an unbounded read. Every one of the three
processes is launched through `cappedCurl()` (`Panel.qml:301`), which caps at the
**producer**:

```sh
timeout -k 2 <deadline> sh -c 'cap="$1"; shift; curl "$@" | head -c "$cap"' sh <cap+1> \
  -fsS --proto '=https' --max-time <inner> -- <url>
```

- `head -c` closes the pipe at the byte ceiling before `StdioCollector` can hold
  more than that, so no check inside `onStreamFinished` is being relied on.
- `cap+1` bytes are requested, not `cap`, so a body sitting exactly at the
  ceiling stays distinguishable from one that was truncated.
- `timeout` is the deadline that still applies while curl is blocked in a
  syscall; curl's `--max-time` is the inner limit. Both are clamped to a minimum
  of 1, because `timeout 0` means *no limit*.
- `--proto '=https'` restricts the protocol, and `-L` is absent so no redirect
  is followed. The `=` prefix is load-bearing: curl reads an unprefixed protocol
  name as *add to the permitted set*, so `--proto=https` restricts nothing at
  all. See "Review round 2" below for the measurement.
- The URL and every curl option travel as argv entries. Nothing is spliced into
  the script text.

Caps are 64 KiB each, sized from measured replies: ipwho.is returns 963 bytes,
Nominatim 3.0 KiB at `limit=5`, Open-Meteo 180 bytes for a bare timezone lookup.
That is at least twenty times the largest.

Collections are bounded independently of bytes: the Nominatim handler applies
`.slice(0, 5)` to whatever comes back, because `limit=5` is a request to the
server and not a guarantee.

`Panel.qml:280` is a comment explaining the above, matched by the same grep.

The grep also reports `Panel.qml:309` under *socket-idle timeout used as a
response deadline*. It is not one: curl's `--max-time` bounds the **whole**
operation rather than resetting on each byte, and the outer `timeout` bounds it
again from outside the process. A drip-fed response is cut off by both.

## Preflight area 3 — `FileView`

    ./tools/build-catalog.py:446

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

`scripts/preflight.sh` reports two capability triggers, and **both are hits on
this notes file**, not on anything that ships or runs:

    SUBMISSION-NOTES.md:141   privilege      the word "sudo", in the sentence saying there is none
    SUBMISSION-NOTES.md:221   remote-build   the `git clone` block quoted in "Review round 1"
    SUBMISSION-NOTES.md:239   remote-build   the grep list naming `git clone` and `curl … | sh`

(The three lines above are themselves matched by the same grep, for the same
reason. That is the point being made.)

Each is prose describing a pattern the plugin does **not** use — the local
preflight grep has no notion of negation. The marketplace's own baseline is the
authority here and disagrees with the local grep: at `909d56f`, with this file
present and unchanged, it reported `"capabilities":[]` and `"findings":[]`. The
file is kept as-is rather than reworded to dodge a grep, since rewording would
cost the reviewer the explanation and change nothing about the code.

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

## Review round 1 — `remote-build` capability (issue #1788, commit 8240043)

The automated security baseline returned `review-required` at `8240043` with one
capability and **no findings**:

> **Remote source build (`remote-build`)** — The installation path builds,
> installs, or directly executes source obtained from a remote repository.
> `README.md:90`

The bot notes that no change is strictly required — a maintainer can simply
accept the capability. It was removed anyway, because every capability avoided
is a review round skipped, and this one bought nothing.

The trigger was a single line: the README documented an optional manual install
alongside the sanctioned one.

```sh
git clone https://github.com/kairos-tech-oh/omarchy-nightsky-plugin
cp -r omarchy-nightsky-plugin ~/.config/omarchy/plugins/kairos.night-sky
omarchy restart shell
```

That block is gone. `omarchy plugin install <repo URL>` is now the only
documented install path, which is the path the marketplace intends anyway.

Removal instructions still cover both cases, as the submission contract
requires: `omarchy plugin remove kairos.night-sky`, plus `rm -rf` on the plugin
directory for anyone who placed it there by hand. Describing how to *remove* a
hand-placed directory is not an install path and does not reintroduce the
capability.

The Development section keeps its tooling commands and now opens with "From a
checkout of this repository" — prose rather than a runnable clone-and-install
recipe.

Verified afterwards: a grep for `git clone`, `curl … | sh`, `cargo install
--git`, `pip install git+`, `go install …@` and `npm install …github` across the
whole repository returns nothing. No runtime code changed in this round — the
diff is README-only — so the checks and the bundled-data digests are unaffected.

## Review round 2 — security review (issue #1788, commit 909d56f)

`ryanrhughes` reviewed at exact HEAD `909d56f77a4eef4514365cdd431596c9f6f7de3e`
and raised three things:

> the runtime location requests use `curl -L` without protocol, destination, or
> private-address restrictions, so a compromised or misconfigured public endpoint
> can redirect the shell's request to an unintended local or private origin. The
> documented development checks also consume remote responses without size
> ceilings, while `tools/check-skymath.js` supplies no explicit request deadline,
> allowing stalled or oversized upstream responses to hang or exhaust the process.

All three are fixed. Taking them in the order raised.

### 1. Runtime location requests — `Panel.qml:301`

`-L` is gone, so no redirect is followed at all, and the protocol is pinned.

The first attempt at this pinned it as `--proto=https`, which **does not work**,
and the flag was inert for one commit. curl treats an unprefixed protocol name as
*add to the permitted set* rather than *restrict to it*, so `--proto=https`
permits everything curl already allowed. Measured on curl 8.21.0, through the
exact argv `cappedCurl()` builds:

| flag form | `http://example.com/` | `file:///…/probe.txt` | `https://ipwho.is/` |
|---|---|---|---|
| `--proto=https` | fetched, exit 0 | **file contents returned** | 957 bytes |
| `--proto "=https"` | `Protocol "http" is disabled` | `Protocol "file" is disabled` | 957 bytes |

The shipped form is now `"--proto", "=https"` as two argv entries.

On **destination and private-address restrictions**: all three runtime URLs are
hardcoded https literals in this repository — `Panel.qml:461` (ipwho.is),
`Panel.qml:367` (Nominatim), `Panel.qml:409` (Open-Meteo). No URL is ever built
from a response, a setting, or any other input, so there is no attacker-reachable
path to a host allowlist decision. With redirects no longer followed, the
destination is fixed at the literal. What that does **not** close is DNS
rebinding against one of those three fixed public hosts; that residual is stated
rather than implied, and closing it would need a resolve-and-pin step that curl
does not offer here.

### 2. Documented development checks — size ceilings

The previous round hardened `tools/check-skymath.js` only. That was half the
finding: `tools/build-catalog.py` is also a documented development check
(`README.md:149` and `:153`, and `tools/run-checks.sh` runs it first), and its
`fetch()` did `response.read()` with no ceiling at all behind a `timeout=120`
that was a socket-idle timer rather than a deadline. Both are now bounded, the
same four ways, in both tools:

| | `tools/build-catalog.py` | `tools/check-skymath.js` |
|---|---|---|
| scheme | https only | https only |
| host | allowlist `raw.githubusercontent.com` | allowlist `api.open-meteo.com`, `ssd.jpl.nasa.gov` |
| redirect | re-validated on every hop via `CheckedRedirectHandler` | `redirect: 'error'` |
| address | every resolved address must be public | n/a — no redirect is followed |
| deadline | wall clock across the body, sliced reads | one `AbortController` over the whole operation |
| bytes | 8 MiB, fails closed | 2 MiB, fails closed |

The byte cap reads `cap+1` and **fails closed** rather than truncating, because a
truncated JSON document that still parses is silently wrong. 8 MiB is about
twelve times the largest real input (`starnames.json`, 680,627 bytes).

The digest check that was already there is not a substitute for any of this: it
runs *after* the bytes are in memory, so it catches wrong content but not too
much of it.

Destination checks verified — 11 cases for the Python path, 7 for the JS path,
including the lookalike hosts `raw.githubusercontent.com.evil.example` and
`api.open-meteo.com.evil.example`, plain `http`, `file://`, `localhost`, `::1`,
`169.254.169.254` and `192.168.1.5`. All refused; both real feeds still work.
`read_capped()` verified at exactly the cap (returns), at cap+1 (fails closed),
and against a response handing back one byte per 50 ms (aborted at the 1.00 s
wall-clock deadline rather than running forever).

### 3. `tools/check-skymath.js` request deadline

An `AbortController` timer is started before `fetch()` and cleared only in
`finally`, so it bounds the body read as well as the connect — 15 s for the whole
operation. A socket-idle timeout would not have: it resets on every byte.

### Not changed, and why

The runtime path was already bounded and stays as it was: `head -c` at the
producer, `cap+1`, an outer `timeout` clamped to a minimum of 1 because
`timeout 0` means *no limit*, and `--max-time` as the inner ceiling. Preflight
lists `Panel.qml:309` under *socket-idle timeout used as a response deadline*;
curl's `--max-time` bounds the whole operation rather than resetting per byte, so
it is a response deadline, and the outer `timeout` bounds it again from outside
the process.

No sanitiser, catalogue, or astronomy code changed in this round. `Catalog.js`
still reproduces byte-for-byte from the pinned upstream commit to
`d12cbc06c2141a4e8c13cb5898be06430c920baebbda55ed27ea4b690d67bc75`, now through
the hardened fetch path.

## Verification performed

- `omarchy plugin validate .` → exit 0
- `tools/run-checks.sh` → 77/77, plus all V4 engine checks, with all six upstream
  inputs fetched through the hardened path and `Catalog.js` reproducing to the
  recorded SHA-256
- Protocol pin measured end to end through the argv `cappedCurl()` builds:
  `http://` and `file://` refused, `https://` unaffected
- Destination checks: 11 Python cases and 7 JavaScript cases, lookalike hosts and
  private addresses included; `read_capped()` at cap, cap+1, and under a
  one-byte-per-50 ms drip feed
- Sunrise/sunset within 63 s of Open-Meteo across 30 events, latitudes −34° to
  +64°; planets within 5.0 arcmin of JPL Horizons; Moon within 28 arcmin
- Polar day and polar night at Tromsø report a state rather than a NaN time
- Loaded in a hard-refreshed shell (qmlcache dropped, `omarchy restart shell`)
  and confirmed: bar label, panel, chart, IP geolocation, hover identification
- Charts cross-checked against known sky positions for Ohio in August and
  January and for Sydney — Summer Triangle at zenith, Orion in winter, Southern
  Cross and Scorpius from the southern hemisphere
