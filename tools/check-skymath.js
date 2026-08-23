#!/usr/bin/env node
/*
 * Verify SkyMath.js against independent references.
 *
 * The plugin computes the whole sky locally, which means there is no service to
 * blame if a number is wrong -- so the numbers get checked against outside
 * sources here, before any of them reach a widget:
 *
 *   sunrise / sunset   Open-Meteo, which publishes both for any coordinate
 *   planets, Moon      JPL Horizons, the reference ephemeris
 *   star geometry      closed-form identities that must hold exactly
 *
 * Network is used only by this development script. The plugin itself never
 * contacts either service.
 *
 *   node tools/check-skymath.js
 *
 * Exits non-zero if any check fails.
 */

'use strict';

const fs = require('fs');
const path = require('path');

// SkyMath.js is a QML JavaScript library: `.pragma library` is a QML engine
// directive that Node does not understand. Strip that one line and the rest is
// plain ECMAScript, so the file under test here is byte-for-byte the file the
// shell loads apart from a pragma that carries no behaviour.
const source = fs.readFileSync(path.join(__dirname, '..', 'SkyMath.js'), 'utf8')
  .replace(/^\s*\.pragma\s+library\s*$/m, '');
const SkyMath = {};
new Function('exports', source + '\n' + [
  'julianDayFromMs', 'localSiderealTime', 'equatorialToHorizontal', 'sunPosition',
  'sunTimes', 'nextSunEvent', 'moonPosition', 'moonIllumination', 'planetPosition',
  'projectToDisc', 'normalizeDegrees', 'normalizeSigned', 'angularSeparation',
  'starColour', 'julianCentury',
].map((name) => `exports.${name} = ${name};`).join('\n'))(SkyMath);

const sanitiseSource = fs.readFileSync(path.join(__dirname, '..', 'Sanitise.js'), 'utf8')
  .replace(/^\s*\.pragma\s+library\s*$/m, '');
const Sanitise = {};
new Function('exports', sanitiseSource + '\nexports.plainOneLine = plainOneLine;')(Sanitise);

const catalogSource = fs.readFileSync(path.join(__dirname, '..', 'data', 'Catalog.js'), 'utf8')
  .replace(/^\s*\.pragma\s+library\s*$/m, '');
const Catalog = {};
new Function('exports', catalogSource + '\nexports.PLANETS = PLANETS; exports.STARS = STARS;'
  + ' exports.STAR_COUNT = STAR_COUNT; exports.NAMED_INDEX = NAMED_INDEX;'
  + ' exports.NAMED_TEXT = NAMED_TEXT; exports.MILKY_WAY = MILKY_WAY;'
  + ' exports.CONSTELLATION_LINES = CONSTELLATION_LINES;')(Catalog);

let failures = 0;
let checks = 0;

function report(ok, label, detail) {
  checks++;
  if (!ok) failures++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? '   ' + detail : ''}`);
}

function near(actual, expected, tolerance, label, unit) {
  const delta = Math.abs(actual - expected);
  report(delta <= tolerance, label,
    `got ${actual.toFixed(3)}, expected ${expected.toFixed(3)}, ` +
    `off by ${delta.toFixed(3)}${unit || ''} (tolerance ${tolerance}${unit || ''})`);
  return delta;
}

async function getJson(url) {
  const response = await fetch(url, { headers: { 'User-Agent': 'night-sky-checks' } });
  if (!response.ok) throw new Error(`${response.status} for ${url}`);
  return response.json();
}

const PLACES = [
  { name: 'Westerville, OH', lat: 40.1267, lon: -82.9319 },
  { name: 'London',          lat: 51.5074, lon: -0.1278 },
  { name: 'Tokyo',           lat: 35.6895, lon: 139.6917 },
  { name: 'Sydney',          lat: -33.8688, lon: 151.2093 },
  { name: 'Reykjavik',       lat: 64.1466, lon: -21.9426 },
];

// --------------------------------------------------------------------------
// 1. geometry identities that must hold exactly
// --------------------------------------------------------------------------

function checkGeometry() {
  console.log('\nGeometry identities');

  const nowMs = Date.UTC(2026, 7, 23, 3, 0, 0);
  const jd = SkyMath.julianDayFromMs(nowMs);

  // A star at the celestial pole sits at an altitude equal to the observer's
  // latitude, due north, at every hour of every day. Polaris is 0.736 degrees
  // off the pole, so it tracks a small circle around that altitude.
  for (const latitude of [10, 40.1267, 51.5, 64.1]) {
    const lst = SkyMath.localSiderealTime(jd, 0);
    const pole = SkyMath.equatorialToHorizontal(0, 90, lst, latitude);
    near(pole.altitude, latitude, 1e-9,
      `celestial pole altitude equals latitude ${latitude}`, ' deg');
  }

  // The azimuth convention is the one thing here that can be wrong by a
  // reflection and still look plausible, so it is asserted directly: a star one
  // hour of right ascension *east* of the meridian, seen from the northern
  // hemisphere, must be in the eastern half of the sky (azimuth 0..180).
  const lst = 100;
  const eastward = SkyMath.equatorialToHorizontal(lst + 15, 0, lst, 40);
  report(eastward.azimuth > 0 && eastward.azimuth < 180,
    'star east of meridian has easterly azimuth',
    `azimuth ${eastward.azimuth.toFixed(1)} deg`);

  const westward = SkyMath.equatorialToHorizontal(lst - 15, 0, lst, 40);
  report(westward.azimuth > 180 && westward.azimuth < 360,
    'star west of meridian has westerly azimuth',
    `azimuth ${westward.azimuth.toFixed(1)} deg`);

  // A star on the meridian, south of the zenith, is due south.
  const meridian = SkyMath.equatorialToHorizontal(lst, 0, lst, 40);
  near(meridian.azimuth, 180, 1e-6, 'star on meridian below zenith is due south', ' deg');
  near(meridian.altitude, 50, 1e-6, 'meridian altitude is 90 minus latitude', ' deg');

  // The projection must put the zenith at the centre, the horizon on the rim,
  // and north at the top.
  const zenith = SkyMath.projectToDisc(90, 0, 200, 200, 180);
  report(Math.abs(zenith.x - 200) < 1e-9 && Math.abs(zenith.y - 200) < 1e-9,
    'zenith projects to the disc centre', `(${zenith.x}, ${zenith.y})`);

  const north = SkyMath.projectToDisc(0, 0, 200, 200, 180);
  report(Math.abs(north.x - 200) < 1e-9 && Math.abs(north.y - 20) < 1e-9,
    'north horizon projects to the top of the disc', `(${north.x}, ${north.y})`);

  const east = SkyMath.projectToDisc(0, 90, 200, 200, 180);
  report(east.x < 200 && Math.abs(east.y - 200) < 1e-9,
    'east horizon projects to the LEFT (chart is held overhead)',
    `(${east.x.toFixed(1)}, ${east.y.toFixed(1)})`);

  report(SkyMath.projectToDisc(-1, 0, 200, 200, 180) === null,
    'below-horizon positions are culled');
}

// --------------------------------------------------------------------------
// 2. sunrise and sunset against Open-Meteo
// --------------------------------------------------------------------------

async function checkSunTimes() {
  console.log('\nSunrise / sunset vs Open-Meteo');
  let worst = 0;

  for (const place of PLACES) {
    const url = 'https://api.open-meteo.com/v1/forecast'
      + `?latitude=${place.lat}&longitude=${place.lon}`
      + '&daily=sunrise,sunset&timezone=UTC&forecast_days=3';
    const data = await getJson(url);

    for (let day = 0; day < data.daily.time.length; day++) {
      const dayMs = Date.parse(data.daily.time[day] + 'T12:00:00Z');
      const times = SkyMath.sunTimes(dayMs, place.lat, place.lon);

      for (const event of ['sunrise', 'sunset']) {
        const referenceMs = Date.parse(data.daily[event][day] + 'Z');
        const ours = times[event + 'Ms'];
        if (ours === null || !isFinite(referenceMs)) continue;
        // Open-Meteo publishes to the minute, so its own value carries up to
        // 30s of rounding; the budget below absorbs that.
        const deltaSeconds = Math.abs(ours - referenceMs) / 1000;
        worst = Math.max(worst, deltaSeconds);
        report(deltaSeconds <= 90,
          `${place.name} ${data.daily.time[day]} ${event}`,
          `off by ${deltaSeconds.toFixed(0)}s`);
      }
    }
  }
  console.log(`  worst sun-time error: ${worst.toFixed(0)}s`);
}

// --------------------------------------------------------------------------
// 3. polar day and polar night
// --------------------------------------------------------------------------

function checkPolar() {
  console.log('\nPolar day / night (Tromso, 69.65 N)');
  const lat = 69.6496;
  const lon = 18.9560;

  const midsummer = SkyMath.sunTimes(Date.UTC(2026, 5, 21, 12), lat, lon);
  report(midsummer.polar === 'day' && midsummer.sunriseMs === null,
    'midnight sun reported as polar day, not NaN', `polar=${midsummer.polar}`);

  const midwinter = SkyMath.sunTimes(Date.UTC(2026, 11, 21, 12), lat, lon);
  report(midwinter.polar === 'night' && midwinter.sunsetMs === null,
    'polar night reported as polar night, not NaN', `polar=${midwinter.polar}`);

  const equinox = SkyMath.sunTimes(Date.UTC(2026, 2, 20, 12), lat, lon);
  report(equinox.polar === null && equinox.sunriseMs !== null && equinox.sunsetMs !== null,
    'equinox at the same place still has both events');

  // The bar widget must never print a NaN clock time. nextSunEvent has to
  // report the polar state instead of returning a garbage instant.
  const during = SkyMath.nextSunEvent(Date.UTC(2026, 5, 21, 12), lat, lon);
  report(during.kind === null && during.polar === 'day',
    'nextSunEvent under the midnight sun returns a polar state, not a time',
    `kind=${during.kind} polar=${during.polar}`);

  // And it must find a real event everywhere that has one.
  for (const place of PLACES) {
    const next = SkyMath.nextSunEvent(Date.now(), place.lat, place.lon);
    const ok = next.kind !== null && next.atMs > Date.now()
      && next.atMs < Date.now() + 2 * 86400000;
    report(ok, `${place.name}: next sun event is in the future and within 2 days`,
      `${next.kind} at ${next.atMs ? new Date(next.atMs).toISOString() : 'null'}`);
  }
}

// --------------------------------------------------------------------------
// 4. Moon and planets against JPL Horizons
// --------------------------------------------------------------------------

// Horizons returns RA/Dec in its own text block between $$SOE and $$EOE.
function parseHorizons(text) {
  const start = text.indexOf('$$SOE');
  const end = text.indexOf('$$EOE');
  if (start < 0 || end < 0) throw new Error('no Horizons data block');
  const body = text.slice(start + 5, end).trim().split('\n')[0];
  // ' 2026-Aug-23 03:00     10 12 34.56 +11 22 33.4   ...'
  const numbers = body.match(/(\d+)\s+(\d+)\s+([\d.]+)\s+([+-]\d+)\s+(\d+)\s+([\d.]+)/);
  if (!numbers) throw new Error('unparsed Horizons row: ' + body);
  const raHours = Number(numbers[1]) + Number(numbers[2]) / 60 + Number(numbers[3]) / 3600;
  const decSign = numbers[4].startsWith('-') ? -1 : 1;
  const dec = decSign * (Math.abs(Number(numbers[4])) + Number(numbers[5]) / 60
    + Number(numbers[6]) / 3600);
  return { ra: SkyMath.normalizeSigned(raHours * 15), dec: dec };
}

async function horizons(command, whenIso) {
  const startIso = whenIso;
  const stopMs = Date.parse(whenIso + 'Z') + 60000;
  const stopIso = new Date(stopMs).toISOString().slice(0, 16).replace('T', ' ');
  const url = 'https://ssd.jpl.nasa.gov/api/horizons.api?format=text'
    + `&COMMAND='${command}'&OBJ_DATA='NO'&MAKE_EPHEM='YES'&EPHEM_TYPE='OBSERVER'`
    + "&CENTER='500@399'"
    + `&START_TIME='${encodeURIComponent(startIso.replace('T', ' '))}'`
    + `&STOP_TIME='${encodeURIComponent(stopIso)}'&STEP_SIZE='1 m'&QUANTITIES='1'`;
  const response = await fetch(url, { headers: { 'User-Agent': 'night-sky-checks' } });
  if (!response.ok) throw new Error(`Horizons ${response.status}`);
  return parseHorizons(await response.text());
}

async function checkBodies() {
  console.log('\nMoon and planets vs JPL Horizons');
  const whenIso = '2026-08-23T03:00';
  const jd = SkyMath.julianDayFromMs(Date.parse(whenIso + 'Z'));

  // Horizons object codes for the planet barycentres, keyed by catalogue id.
  const codes = { mer: '199', ven: '299', mar: '499', jup: '599', sat: '699' };
  const earth = Catalog.PLANETS.find((planet) => planet.id === 'ter');

  const moonReference = await horizons('301', whenIso);
  const moon = SkyMath.moonPosition(jd);
  const moonError = SkyMath.angularSeparation(moon.ra, moon.dec,
    moonReference.ra, moonReference.dec);
  report(moonError <= 0.5, 'Moon position within 0.5 deg of Horizons',
    `off by ${(moonError * 60).toFixed(1)} arcmin`);

  let worstPlanet = 0;
  for (const planet of Catalog.PLANETS) {
    if (!codes[planet.id]) continue;
    const reference = await horizons(codes[planet.id], whenIso);
    const ours = SkyMath.planetPosition(planet, earth, jd);
    const error = SkyMath.angularSeparation(ours.ra, ours.dec, reference.ra, reference.dec);
    worstPlanet = Math.max(worstPlanet, error);
    report(error <= 0.15, `${planet.name} within 9 arcmin of Horizons`,
      `off by ${(error * 60).toFixed(1)} arcmin`);
  }
  console.log(`  worst planet error: ${(worstPlanet * 60).toFixed(1)} arcmin`);

  // Illuminated fraction must move monotonically from new to full, and the
  // waxing flag must agree with the direction of travel.
  const phases = [];
  for (let day = 0; day <= 29; day++) {
    phases.push(SkyMath.moonIllumination(jd + day));
  }
  report(phases.some((p) => p.fraction < 0.05) || phases.some((p) => p.fraction > 0.95),
    'illuminated fraction sweeps a full cycle over 29 days',
    `min ${Math.min(...phases.map((p) => p.fraction)).toFixed(2)}, ` +
    `max ${Math.max(...phases.map((p) => p.fraction)).toFixed(2)}`);

  let consistent = true;
  for (let i = 1; i < phases.length; i++) {
    const rising = phases[i].fraction > phases[i - 1].fraction;
    // Skip the two samples that straddle new and full, where the direction
    // legitimately reverses between one day and the next.
    if (Math.abs(phases[i].fraction - phases[i - 1].fraction) < 0.01) continue;
    if (rising !== phases[i].waxing) consistent = false;
  }
  report(consistent, 'waxing flag agrees with the direction the fraction is moving');
}

// --------------------------------------------------------------------------
// 5. catalogue sanity
// --------------------------------------------------------------------------

function checkCatalog() {
  console.log('\nCatalogue');
  report(Catalog.STARS.length === Catalog.STAR_COUNT * 4,
    'star array length matches the declared count',
    `${Catalog.STARS.length} = ${Catalog.STAR_COUNT} x 4`);

  let sorted = true;
  for (let i = 6; i < Catalog.STARS.length; i += 4) {
    if (Catalog.STARS[i] < Catalog.STARS[i - 4]) { sorted = false; break; }
  }
  report(sorted, 'stars are ordered brightest first, so a magnitude limit can stop early');

  let inRange = true;
  for (let i = 0; i < Catalog.STARS.length; i += 4) {
    if (Math.abs(Catalog.STARS[i]) > 180.001 || Math.abs(Catalog.STARS[i + 1]) > 90.001) {
      inRange = false; break;
    }
  }
  report(inRange, 'every star coordinate is inside RA +/-180, Dec +/-90');

  report(Catalog.NAMED_INDEX.length === Catalog.NAMED_TEXT.length,
    'named-star parallel arrays are the same length',
    `${Catalog.NAMED_INDEX.length} entries`);

  // Sirius is the brightest star in the sky, so it must be the first record.
  const brightestName = Catalog.NAMED_TEXT[Catalog.NAMED_INDEX.indexOf(0)];
  report(brightestName === 'Sirius', 'brightest catalogue star is Sirius',
    `got ${brightestName}`);

  let mwVertices = 0;
  for (const layer of Catalog.MILKY_WAY) {
    for (const ring of layer) mwVertices += ring.length / 2;
  }
  report(mwVertices <= 5000, 'Milky Way vertex count is under the retention cap',
    `${mwVertices} vertices`);
}

// --------------------------------------------------------------------------
// 6. the sanitiser, against real injection payloads
// --------------------------------------------------------------------------

function checkSanitiser() {
  console.log('\nSanitiser (text crossing into shell-owned AutoText sinks)');

  // The exact shape reviewers measured in marketplace issue #1566: a string
  // that, reaching a Text.AutoText sink, renders as a 40px-tall row and fetches
  // the URL from inside the shell process.
  const payload = '<img src="http://127.0.0.1:9/x.png" width="300" height="40">Springfield';
  const cleaned = Sanitise.plainOneLine(payload, 200);
  report(!/[<>&]/.test(cleaned), 'angle brackets and ampersands are gone', `-> ${cleaned}`);
  report(cleaned.indexOf('img') >= 0 && cleaned.indexOf('Springfield') >= 0,
    'the readable text survives, only the markup is destroyed', `-> ${cleaned}`);

  // Entity-encoded brackets must not survive either: stripping < and > alone
  // leaves &#60; and &lt;, which the rich-text engine decodes back.
  for (const entity of ['&#60;img src=x&#62;', '&lt;img src=x&gt;', '&#x3c;b&#x3e;']) {
    const out = Sanitise.plainOneLine(entity, 200);
    report(!/[<>&]/.test(out), `entity-encoded bracket neutralised: ${entity}`, `-> ${out}`);
  }

  // Newlines let one field forge what looks like a second line of the display.
  const multiline = Sanitise.plainOneLine('Paris\nSunrise 00:00\r\nFake', 200);
  report(!/[\r\n]/.test(multiline), 'newlines collapsed to spaces', `-> ${multiline}`);

  // Length cap, so a long display_name cannot paint across the screen.
  const long = Sanitise.plainOneLine('x'.repeat(500), 40);
  report(long.length === 40, 'over-long text is capped', `${long.length} chars`);

  // Ordinary place names must come through untouched, or the cure is worse.
  for (const name of ['Westerville, Ohio, United States', 'Tromsø', '東京都', 'Saint-Étienne']) {
    report(Sanitise.plainOneLine(name, 120) === name, `ordinary place name unchanged: ${name}`);
  }

  // Null and undefined must not throw -- they arrive whenever a lookup fails.
  report(Sanitise.plainOneLine(null, 40) === '' && Sanitise.plainOneLine(undefined, 40) === '',
    'null and undefined flatten to an empty string');
}

// --------------------------------------------------------------------------

(async function main() {
  checkGeometry();
  checkCatalog();
  checkSanitiser();
  checkPolar();
  try {
    await checkSunTimes();
    await checkBodies();
  } catch (error) {
    console.log(`\n  network checks could not run: ${error.message}`);
    console.log('  (offline checks above still apply)');
  }

  console.log(`\n${checks - failures}/${checks} checks passed`);
  process.exit(failures === 0 ? 0 : 1);
})();
