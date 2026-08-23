// Confirms SkyMath.js and data/Catalog.js load and behave correctly under Qt's
// V4 engine -- the one that actually runs inside omarchy-shell.
//
// tools/check-skymath.js proves the maths against real ephemerides, but it runs
// under Node. V4 is a different engine with a different JavaScript subset, and
// "it worked in Node" has never been evidence about the shell. This file closes
// that gap: same library, same expectations, V4 doing the arithmetic.
//
// Run it with:
//
//     tools/run-checks.sh
//
// The result is communicated through the exit code rather than console output,
// because Qt's `qml` runner suppresses console messages on some builds -- and
// an assertion that fails loudly is worth more than a number nobody reads.
// Exit 0 means every check passed; any other value is the number of the first
// check that did not.

import QtQuick
import "../SkyMath.js" as SkyMath
import "../Sanitise.js" as Sanitise
import "../data/Catalog.js" as Catalog

QtObject {
  function fail(code) {
    Qt.exit(code)
    return false
  }

  Component.onCompleted: {
    // 1-9: the catalogue loaded, and loaded completely.
    if (!Catalog.STARS || Catalog.STARS.length === 0) return fail(1)
    if (Catalog.STARS.length !== Catalog.STAR_COUNT * 4) return fail(2)
    if (Catalog.CONSTELLATION_LINES.length !== 89) return fail(3)
    if (Catalog.CONSTELLATIONS.length !== 89) return fail(4)
    if (Catalog.MILKY_WAY.length !== 5) return fail(5)
    if (Catalog.PLANETS.length !== 6) return fail(6)
    if (Catalog.STAR_COUNT > Catalog.MAX_STARS) return fail(7)

    // 10-19: geometry identities. These must hold to machine precision in any
    // engine; a V4 trigonometry difference would show up here first.
    var jd = SkyMath.julianDayFromMs(Date.now())
    var lst = SkyMath.localSiderealTime(jd, -82.9319)

    var pole = SkyMath.equatorialToHorizontal(0, 90, lst, 40.1267)
    if (Math.abs(pole.altitude - 40.1267) > 1e-6) return fail(10)

    var meridian = SkyMath.equatorialToHorizontal(lst, 0, lst, 40)
    if (Math.abs(meridian.azimuth - 180) > 1e-4) return fail(11)
    if (Math.abs(meridian.altitude - 50) > 1e-4) return fail(12)

    var east = SkyMath.equatorialToHorizontal(lst + 15, 0, lst, 40)
    if (!(east.azimuth > 0 && east.azimuth < 180)) return fail(13)

    var zenith = SkyMath.projectToDisc(90, 0, 200, 200, 180)
    if (!zenith || Math.abs(zenith.x - 200) > 1e-6 || Math.abs(zenith.y - 200) > 1e-6) return fail(14)

    var north = SkyMath.projectToDisc(0, 0, 200, 200, 180)
    if (!north || Math.abs(north.y - 20) > 1e-6) return fail(15)

    // East must land on the left half of the disc. Getting this backwards
    // mirrors the sky and is invisible unless asserted.
    var eastPoint = SkyMath.projectToDisc(0, 90, 200, 200, 180)
    if (!eastPoint || eastPoint.x >= 200) return fail(16)

    if (SkyMath.projectToDisc(-1, 0, 200, 200, 180) !== null) return fail(17)

    // 20-29: the Sun, the Moon and the planets produce finite, sane values.
    var next = SkyMath.nextSunEvent(Date.now(), 40.1267, -82.9319)
    if (next.kind === null) return fail(20)
    if (!isFinite(next.atMs)) return fail(21)
    if (next.atMs <= Date.now()) return fail(22)
    if (next.atMs > Date.now() + 2 * 86400000) return fail(23)

    // The midnight sun must report a state, never a NaN clock reading.
    var polar = SkyMath.sunTimes(Date.UTC(2026, 5, 21, 12), 69.6496, 18.956)
    if (polar.polar !== "day" || polar.sunriseMs !== null) return fail(24)

    var moon = SkyMath.moonIllumination(jd)
    if (!isFinite(moon.fraction) || moon.fraction < 0 || moon.fraction > 1) return fail(25)
    if (!moon.name || moon.name.length === 0) return fail(26)

    var earth = null
    for (var i = 0; i < Catalog.PLANETS.length; i++) {
      if (Catalog.PLANETS[i].id === "ter") earth = Catalog.PLANETS[i]
    }
    if (!earth) return fail(27)

    for (var j = 0; j < Catalog.PLANETS.length; j++) {
      var planet = Catalog.PLANETS[j]
      if (planet.id === "ter") continue
      var position = SkyMath.planetPosition(planet, earth, jd)
      if (!isFinite(position.ra) || !isFinite(position.dec)) return fail(28)
      if (Math.abs(position.dec) > 90.001) return fail(29)
    }

    // 30-39: every star projects to a finite point or is culled -- no NaN can
    // reach the canvas, where it would silently poison a path.
    var visible = 0
    for (var k = 0; k < Catalog.STAR_COUNT; k++) {
      var offset = k * 4
      var horizontal = SkyMath.equatorialToHorizontal(
          Catalog.STARS[offset], Catalog.STARS[offset + 1], lst, 40.1267)
      if (!isFinite(horizontal.altitude) || !isFinite(horizontal.azimuth)) return fail(30)
      var point = SkyMath.projectToDisc(horizontal.altitude, horizontal.azimuth, 190, 190, 180)
      if (point === null) continue
      if (!isFinite(point.x) || !isFinite(point.y)) return fail(31)
      visible++
    }
    // Roughly half the sphere is up at any moment; a wildly different count
    // means the horizon test inverted.
    if (visible < Catalog.STAR_COUNT * 0.25 || visible > Catalog.STAR_COUNT * 0.75) return fail(32)

    // 40-49: colours are well-formed CSS the canvas will accept.
    var colours = [-0.4, -0.1, 0.0, 0.65, 1.2, 2.0]
    for (var c = 0; c < colours.length; c++) {
      if (!/^rgb\(\d{1,3},\d{1,3},\d{1,3}\)$/.test(SkyMath.starColour(colours[c]))) return fail(40)
    }

    // 50-59: the sanitiser, under V4's own regex engine. Node passing is not
    // evidence about V4, and this is the one function whose failure is silent
    // and security-relevant.
    var payloads = [
      '<img src="http://127.0.0.1:9/x.png" width="300" height="40">Springfield',
      '&#60;img src=x&#62;',
      '&lt;b&gt;bold',
      'Paris\nSunrise 00:00'
    ]
    for (var s = 0; s < payloads.length; s++) {
      var cleaned = Sanitise.plainOneLine(payloads[s], 200)
      if (/[<>&]/.test(cleaned)) return fail(50)
      if (/[\r\n\t]/.test(cleaned)) return fail(51)
    }
    if (Sanitise.plainOneLine("Westerville, Ohio", 120) !== "Westerville, Ohio") return fail(52)
    if (Sanitise.plainOneLine("Tromsø", 120) !== "Tromsø") return fail(53)
    if (Sanitise.plainOneLine(null, 40) !== "") return fail(54)
    if (Sanitise.plainOneLine(new Array(500).join("x"), 40).length !== 40) return fail(55)

    Qt.exit(0)
  }
}
