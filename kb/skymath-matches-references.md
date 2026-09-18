---
id: omarchy-nightsky-plugin.skymath-matches-references
project: omarchy-nightsky-plugin
category: logic
severity: critical
environment: any
depends_on: []
---

# planet and moon positions agree with JPL Horizons

## Claim
`tools/check-skymath.js` passes: computed planet positions stay within a
few arcminutes of JPL Horizons, and moon-phase illumination sweeps a full
cycle correctly.

## Why
This is offline astronomical computation with no external source of truth
at runtime — the only way to know the math is still right is to check it
against a real reference periodically, since nothing else would catch it
drifting.

## Check
```bash
node tools/check-skymath.js
```

## Depends On
None
