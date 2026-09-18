---
id: omarchy-nightsky-plugin.catalog-reproducible
project: omarchy-nightsky-plugin
category: data
severity: critical
environment: any
depends_on: []
---

# the star catalogue rebuilds byte-for-byte from its pinned upstream commit

## Claim
`tools/build-catalog.py --check` passes: rebuilding `Catalog.js` from the
pinned d3-celestial commit matches the committed file exactly.

## Why
The catalogue is generated, not hand-maintained — this is the only thing
that would catch it drifting from what the build script would actually
produce today, or the pinned source going missing upstream.

## Check
```bash
python3 tools/build-catalog.py --check
```

## Depends On
None
