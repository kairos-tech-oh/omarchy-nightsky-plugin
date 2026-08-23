.pragma library

// Positional astronomy for the night-sky plugin.
//
// Everything the plugin draws or prints is computed here, on the machine, from
// the bundled catalogue -- no ephemeris service, no sunrise API, no network at
// all. That is the whole reason this file exists: it makes the plugin work
// offline, respond instantly to a location change, and stay permanently clear
// of anybody's rate limit.
//
// Angles are degrees at every boundary. Radians appear only inside a function,
// never in an argument or a return value, because mixing the two silently is
// how sky code goes subtly wrong.
//
// Accuracy, as measured by tools/check-skymath.js against Open-Meteo and JPL
// Horizons -- these are observed worst cases, not the textbook claims:
//   sunrise / sunset    63 s worst over 30 events, latitudes -34 to +64
//                       (Open-Meteo publishes to the minute, so ~30 s of that
//                       is its own rounding)
//   planets             5.0 arcmin worst, Saturn; the rest under 1.1
//   Moon position       28 arcmin -- about one lunar diameter
//   star positions      exact; the catalogue is J2000 and proper motion over a
//                       few decades is far below one pixel
// The chart draws 90 degrees of altitude across roughly 190 pixels, so a
// degree is about two pixels and every error above is sub-pixel to one pixel.

var DEG = Math.PI / 180.0
var RAD = 180.0 / Math.PI

// Obliquity of the ecliptic at J2000.
var OBLIQUITY_J2000 = 23.43928

// The Sun's centre sits 0.833 degrees below the true horizon at the moment we
// call it risen or set: about 0.567 for atmospheric refraction plus its own
// 0.266 semi-diameter, since sunrise is when the *limb* appears.
var SUNRISE_ZENITH = 90.833

var MS_PER_DAY = 86400000
var J2000_JD = 2451545.0
// Julian day number of the Unix epoch, 1970-01-01T00:00:00Z.
var UNIX_EPOCH_JD = 2440587.5


// --------------------------------------------------------------------------
// angles and time
// --------------------------------------------------------------------------

function normalizeDegrees(value) {
  var wrapped = value % 360.0
  return wrapped < 0 ? wrapped + 360.0 : wrapped
}

// Wrap to -180..180. Used where a signed offset is meaningful -- an hour angle
// west versus east, a mean anomaly either side of perihelion.
function normalizeSigned(value) {
  var wrapped = normalizeDegrees(value)
  return wrapped > 180.0 ? wrapped - 360.0 : wrapped
}

function sinDeg(value) { return Math.sin(value * DEG) }
function cosDeg(value) { return Math.cos(value * DEG) }
function tanDeg(value) { return Math.tan(value * DEG) }

function julianDayFromMs(unixMs) {
  return unixMs / MS_PER_DAY + UNIX_EPOCH_JD
}

function msFromJulianDay(jd) {
  return (jd - UNIX_EPOCH_JD) * MS_PER_DAY
}

// Julian centuries since J2000.0 -- the time argument nearly every series below
// is expressed in.
function julianCentury(jd) {
  return (jd - J2000_JD) / 36525.0
}

// Greenwich mean sidereal time. The quadratic term matters over decades, not
// over a session, but it costs one multiply.
function greenwichMeanSiderealTime(jd) {
  var t = julianCentury(jd)
  var gmst = 280.46061837
      + 360.98564736629 * (jd - J2000_JD)
      + t * t * (0.000387933 - t / 38710000.0)
  return normalizeDegrees(gmst)
}

// Local sidereal time: the right ascension currently on the meridian. East
// longitude positive, which is the sign convention every caller here uses.
function localSiderealTime(jd, longitudeDeg) {
  return normalizeDegrees(greenwichMeanSiderealTime(jd) + longitudeDeg)
}


// --------------------------------------------------------------------------
// coordinate conversion
// --------------------------------------------------------------------------

// Equatorial (RA/Dec) to horizontal (altitude/azimuth) for one observer.
//
// Azimuth is returned in the convention the compass rose uses: 0 = north,
// 90 = east, increasing clockwise. Getting this backwards mirrors the entire
// chart east-for-west, which is the classic failure in this kind of code and
// the reason the check script asserts a known star's azimuth explicitly.
function equatorialToHorizontal(raDeg, decDeg, lstDeg, latitudeDeg) {
  var hourAngle = normalizeSigned(lstDeg - raDeg)
  var sinDec = sinDeg(decDeg)
  var cosDec = cosDeg(decDeg)
  var sinLat = sinDeg(latitudeDeg)
  var cosLat = cosDeg(latitudeDeg)
  var cosHour = cosDeg(hourAngle)

  var sinAlt = sinDec * sinLat + cosDec * cosLat * cosHour
  sinAlt = Math.max(-1.0, Math.min(1.0, sinAlt))
  var altitude = Math.asin(sinAlt) * RAD

  var y = -cosDec * cosLat * sinDeg(hourAngle)
  var x = sinDec - sinLat * sinAlt
  var azimuth = normalizeDegrees(Math.atan2(y, x) * RAD)

  return { altitude: altitude, azimuth: azimuth }
}

// Ecliptic longitude/latitude to equatorial RA/Dec.
function eclipticToEquatorial(longitudeDeg, latitudeDeg, obliquityDeg) {
  var obliquity = obliquityDeg === undefined ? OBLIQUITY_J2000 : obliquityDeg
  var sinLon = sinDeg(longitudeDeg)
  var cosLon = cosDeg(longitudeDeg)
  var sinLat = sinDeg(latitudeDeg)
  var cosLat = cosDeg(latitudeDeg)
  var sinObl = sinDeg(obliquity)
  var cosObl = cosDeg(obliquity)

  var ra = Math.atan2(sinLon * cosObl - (sinLat / cosLat) * sinObl, cosLon) * RAD
  var dec = Math.asin(sinLat * cosObl + cosLat * sinObl * sinLon) * RAD
  return { ra: normalizeSigned(ra), dec: dec }
}

// Angular separation between two equatorial positions, in degrees.
function angularSeparation(ra1, dec1, ra2, dec2) {
  var cosSeparation = sinDeg(dec1) * sinDeg(dec2)
      + cosDeg(dec1) * cosDeg(dec2) * cosDeg(ra1 - ra2)
  cosSeparation = Math.max(-1.0, Math.min(1.0, cosSeparation))
  return Math.acos(cosSeparation) * RAD
}


// --------------------------------------------------------------------------
// the Sun
// --------------------------------------------------------------------------

// Apparent solar position, following NOAA's published solar-position
// procedure. Returns the quantities the sunrise solver and the Moon-phase
// calculation both need, so neither has to recompute the series.
function sunPosition(jd) {
  var t = julianCentury(jd)

  var meanLongitude = normalizeDegrees(280.46646 + t * (36000.76983 + t * 0.0003032))
  var meanAnomaly = 357.52911 + t * (35999.05029 - 0.0001537 * t)
  var eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)

  var equationOfCentre =
      sinDeg(meanAnomaly) * (1.914602 - t * (0.004817 + 0.000014 * t))
      + sinDeg(2 * meanAnomaly) * (0.019993 - 0.000101 * t)
      + sinDeg(3 * meanAnomaly) * 0.000289

  var trueLongitude = meanLongitude + equationOfCentre
  var trueAnomaly = meanAnomaly + equationOfCentre

  // Distance in astronomical units, needed for the Moon's phase angle.
  var radiusVector = (1.000001018 * (1 - eccentricity * eccentricity))
      / (1 + eccentricity * cosDeg(trueAnomaly))

  // Nutation and aberration, to the precision this plugin needs.
  var omega = 125.04 - 1934.136 * t
  var apparentLongitude = trueLongitude - 0.00569 - 0.00478 * sinDeg(omega)

  var meanObliquity = 23.0 + (26.0 + ((21.448 - t * (46.815 + t * (0.00059 - t * 0.001813)))) / 60.0) / 60.0
  var obliquity = meanObliquity + 0.00256 * cosDeg(omega)

  var declination = Math.asin(sinDeg(obliquity) * sinDeg(apparentLongitude)) * RAD
  var ra = Math.atan2(cosDeg(obliquity) * sinDeg(apparentLongitude), cosDeg(apparentLongitude)) * RAD

  // Equation of time, in minutes: the gap between apparent and mean solar time.
  var varY = tanDeg(obliquity / 2.0) * tanDeg(obliquity / 2.0)
  var equationOfTime = 4.0 * RAD * (
      varY * sinDeg(2 * meanLongitude)
      - 2.0 * eccentricity * sinDeg(meanAnomaly)
      + 4.0 * eccentricity * varY * sinDeg(meanAnomaly) * cosDeg(2 * meanLongitude)
      - 0.5 * varY * varY * sinDeg(4 * meanLongitude)
      - 1.25 * eccentricity * eccentricity * sinDeg(2 * meanAnomaly))

  return {
    ra: normalizeSigned(ra),
    dec: declination,
    apparentLongitude: normalizeDegrees(apparentLongitude),
    obliquity: obliquity,
    equationOfTime: equationOfTime,
    radiusVectorAu: radiusVector
  }
}

// Sunrise and sunset for one calendar day at one place.
//
// `dayStartUtcMs` is any instant inside the local day of interest; the solar
// quantities are evaluated near local solar noon, which is what keeps the
// result inside a minute of a full ephemeris.
//
// Returns milliseconds since the Unix epoch, or null for each event that does
// not occur. `polar` distinguishes the two ways an event can be missing --
// there is no sunrise during the midnight sun and no sunrise during polar
// night, and a widget that printed the same blank for both would be lying.
function sunTimes(dayStartUtcMs, latitudeDeg, longitudeDeg) {
  var jdMidnight = Math.floor(julianDayFromMs(dayStartUtcMs) - 0.5) + 0.5
  // Evaluate at the approximate local noon rather than at UT midnight, so a
  // longitude far from Greenwich still samples the right day's declination.
  var jdNoon = jdMidnight + 0.5 - longitudeDeg / 360.0
  var sun = sunPosition(jdNoon)

  // Solar noon expressed in minutes after UT midnight.
  var solarNoonMinutes = 720.0 - 4.0 * longitudeDeg - sun.equationOfTime

  var cosHourAngle = (cosDeg(SUNRISE_ZENITH) - sinDeg(latitudeDeg) * sinDeg(sun.dec))
      / (cosDeg(latitudeDeg) * cosDeg(sun.dec))

  var result = {
    solarNoonMs: msFromJulianDay(jdMidnight) + solarNoonMinutes * 60000,
    sunriseMs: null,
    sunsetMs: null,
    declination: sun.dec,
    polar: null
  }

  // |cos H| > 1 has no solution: the Sun never reaches the horizon altitude
  // that day. Which side it stays on is decided by the sign.
  if (cosHourAngle > 1.0) {
    result.polar = "night"
    return result
  }
  if (cosHourAngle < -1.0) {
    result.polar = "day"
    return result
  }

  var hourAngle = Math.acos(cosHourAngle) * RAD
  var offsetMinutes = 4.0 * hourAngle
  result.sunriseMs = msFromJulianDay(jdMidnight) + (solarNoonMinutes - offsetMinutes) * 60000
  result.sunsetMs = msFromJulianDay(jdMidnight) + (solarNoonMinutes + offsetMinutes) * 60000
  return result
}

// The next sunrise or sunset strictly after `nowMs` -- what the bar widget
// shows.
//
// Scanning day by day rather than computing today's pair and assuming is what
// makes this correct at the edges: near the poles a run of days may have no
// events at all, and around the date boundary "today's sunrise" has often
// already happened. Three days is enough for any latitude that has events at
// all, and the polar case is reported rather than searched forever.
function nextSunEvent(nowMs, latitudeDeg, longitudeDeg) {
  var polarState = null
  for (var offset = -1; offset <= 2; offset++) {
    var times = sunTimes(nowMs + offset * MS_PER_DAY, latitudeDeg, longitudeDeg)
    if (times.polar !== null) {
      // Remember the state of the day we are actually standing in.
      if (offset === 0) polarState = times.polar
      continue
    }
    if (times.sunriseMs !== null && times.sunriseMs > nowMs
        && (times.sunsetMs === null || times.sunriseMs <= times.sunsetMs || times.sunsetMs <= nowMs)) {
      return { kind: "sunrise", atMs: times.sunriseMs, polar: null }
    }
    if (times.sunsetMs !== null && times.sunsetMs > nowMs) {
      return { kind: "sunset", atMs: times.sunsetMs, polar: null }
    }
  }
  return { kind: null, atMs: null, polar: polarState }
}


// --------------------------------------------------------------------------
// the Moon
// --------------------------------------------------------------------------

// Low-precision lunar position: the abbreviated series from the Astronomical
// Almanac, good to roughly 10 arcminutes in longitude and 4 in latitude over
// the years around now. The full ELP theory would be thousands of terms for a
// refinement smaller than the Moon's own drawn radius on this chart.
function moonPosition(jd) {
  var t = julianCentury(jd)

  var longitude = 218.32 + 481267.8813 * t
      + 6.29 * sinDeg(134.9 + 477198.85 * t)
      - 1.27 * sinDeg(259.2 - 413335.38 * t)
      + 0.66 * sinDeg(235.7 + 890534.23 * t)
      + 0.21 * sinDeg(269.9 + 954397.70 * t)
      - 0.19 * sinDeg(357.5 + 35999.05 * t)
      - 0.11 * sinDeg(186.6 + 966404.05 * t)

  var latitude = 5.13 * sinDeg(93.3 + 483202.03 * t)
      + 0.28 * sinDeg(228.2 + 960400.87 * t)
      - 0.28 * sinDeg(318.3 + 6003.18 * t)
      - 0.17 * sinDeg(217.6 - 407332.20 * t)

  var parallax = 0.9508
      + 0.0518 * cosDeg(134.9 + 477198.85 * t)
      + 0.0095 * cosDeg(259.2 - 413335.38 * t)
      + 0.0078 * cosDeg(235.7 + 890534.23 * t)
      + 0.0028 * cosDeg(269.9 + 954397.70 * t)

  longitude = normalizeDegrees(longitude)
  var equatorial = eclipticToEquatorial(longitude, latitude)

  // Earth radii, from the horizontal parallax.
  var distanceEarthRadii = 1.0 / sinDeg(parallax)

  return {
    ra: equatorial.ra,
    dec: equatorial.dec,
    eclipticLongitude: longitude,
    eclipticLatitude: latitude,
    distanceKm: distanceEarthRadii * 6378.14
  }
}

var MOON_PHASE_NAMES = [
  "New Moon", "Waxing Crescent", "First Quarter", "Waxing Gibbous",
  "Full Moon", "Waning Gibbous", "Last Quarter", "Waning Crescent"
]

// Illuminated fraction and phase name.
//
// The fraction comes from the Sun-Moon-Earth geometry rather than from days
// elapsed since a reference new moon, so it stays right through the anomalistic
// month instead of drifting. The lit fraction alone cannot tell waxing from
// waning -- both halves of the cycle pass through every value -- so the name is
// decided by the Moon's elongation east of the Sun.
function moonIllumination(jd) {
  var sun = sunPosition(jd)
  var moon = moonPosition(jd)

  var elongation = angularSeparation(sun.ra, sun.dec, moon.ra, moon.dec)

  var sunDistanceKm = sun.radiusVectorAu * 149597870.7
  var phaseAngle = Math.atan2(
      sunDistanceKm * sinDeg(elongation),
      moon.distanceKm - sunDistanceKm * cosDeg(elongation)) * RAD

  var fraction = (1.0 + cosDeg(phaseAngle)) / 2.0

  // 0 at new moon, rising through 180 at full, back to 360.
  var age = normalizeDegrees(moon.eclipticLongitude - sun.apparentLongitude)

  // Eight equal 45-degree bins centred on the named phases, so "Full Moon"
  // covers the 22.5 degrees either side of opposition rather than a single
  // instant nobody is ever looking at.
  var index = Math.floor(normalizeDegrees(age + 22.5) / 45.0) % 8

  return {
    fraction: fraction,
    phaseAngle: phaseAngle,
    ageDegrees: age,
    waxing: age < 180.0,
    name: MOON_PHASE_NAMES[index],
    ra: moon.ra,
    dec: moon.dec,
    distanceKm: moon.distanceKm
  }
}


// --------------------------------------------------------------------------
// the planets
// --------------------------------------------------------------------------

// Solve Kepler's equation by Newton iteration. Six passes is comfortably
// convergent for every eccentricity in this catalogue (Mercury's 0.2056 is the
// worst), and a fixed bound means no input can spin here.
function solveKepler(meanAnomalyDeg, eccentricity) {
  var eccentric = meanAnomalyDeg + eccentricity * RAD * sinDeg(meanAnomalyDeg)
  for (var i = 0; i < 6; i++) {
    var deltaM = meanAnomalyDeg - (eccentric - eccentricity * RAD * sinDeg(eccentric))
    var deltaE = deltaM / (1.0 - eccentricity * cosDeg(eccentric))
    eccentric += deltaE
    if (Math.abs(deltaE) < 1e-9) break
  }
  return eccentric
}

// Heliocentric rectangular ecliptic coordinates, in astronomical units, from
// one planet's Keplerian element set at time `t` (Julian centuries past J2000).
function heliocentricEcliptic(elements, t) {
  var a = elements.a + elements.da * t
  var e = elements.e + elements.de * t
  var inclination = elements.i + elements.di * t
  var meanLongitude = elements.l + elements.dl * t
  var perihelion = elements.w + elements.dw * t
  var node = elements.n + elements.dn * t

  var argumentOfPerihelion = perihelion - node
  var meanAnomaly = normalizeSigned(meanLongitude - perihelion)
  var eccentric = solveKepler(meanAnomaly, e)

  // Position in the orbital plane.
  var xOrbital = a * (cosDeg(eccentric) - e)
  var yOrbital = a * Math.sqrt(1.0 - e * e) * sinDeg(eccentric)

  var cosArg = cosDeg(argumentOfPerihelion)
  var sinArg = sinDeg(argumentOfPerihelion)
  var cosNode = cosDeg(node)
  var sinNode = sinDeg(node)
  var cosInc = cosDeg(inclination)
  var sinInc = sinDeg(inclination)

  return {
    x: (cosArg * cosNode - sinArg * sinNode * cosInc) * xOrbital
       + (-sinArg * cosNode - cosArg * sinNode * cosInc) * yOrbital,
    y: (cosArg * sinNode + sinArg * cosNode * cosInc) * xOrbital
       + (-sinArg * sinNode + cosArg * cosNode * cosInc) * yOrbital,
    z: (sinArg * sinInc) * xOrbital + (cosArg * sinInc) * yOrbital
  }
}

// Geocentric apparent position of one planet.
//
// `earthElements` is the Earth entry from the same catalogue: a planet's place
// in our sky is the difference between where it is and where we are, so Earth's
// orbit has to be solved on every call too.
function planetPosition(elements, earthElements, jd) {
  var t = julianCentury(jd)
  var planet = heliocentricEcliptic(elements, t)
  var earth = heliocentricEcliptic(earthElements, t)

  var x = planet.x - earth.x
  var y = planet.y - earth.y
  var z = planet.z - earth.z

  // Ecliptic to equatorial: a single rotation about the vernal equinox.
  var cosObl = cosDeg(OBLIQUITY_J2000)
  var sinObl = sinDeg(OBLIQUITY_J2000)
  var xEquatorial = x
  var yEquatorial = y * cosObl - z * sinObl
  var zEquatorial = y * sinObl + z * cosObl

  var distance = Math.sqrt(xEquatorial * xEquatorial
      + yEquatorial * yEquatorial + zEquatorial * zEquatorial)

  var heliocentricDistance = Math.sqrt(planet.x * planet.x
      + planet.y * planet.y + planet.z * planet.z)

  // Brightness, used only to size the drawn dot. The phase term is omitted --
  // it matters for Venus and Mercury, but a dot is a few pixels across and the
  // ordering, which is all the size conveys, is unaffected.
  var magnitude = elements.h + 5.0 * Math.log(heliocentricDistance * distance) / Math.LN10

  return {
    ra: normalizeSigned(Math.atan2(yEquatorial, xEquatorial) * RAD),
    dec: Math.asin(zEquatorial / distance) * RAD,
    distanceAu: distance,
    magnitude: magnitude
  }
}


// --------------------------------------------------------------------------
// projection
// --------------------------------------------------------------------------

// Azimuthal-equidistant projection of the visible hemisphere onto a disc:
// zenith at the centre, horizon on the rim, altitude linear in radius. Equal
// altitude steps are equal pixel steps, which is what makes "halfway up the
// sky" look halfway up.
//
// North is drawn at the top and east at the *left*. That is not a mistake and
// not a mirror: a sky chart is held overhead and looked up through, so the
// compass runs the opposite way round from a map of the ground.
//
// Returns null below the horizon so callers can cull with a null check rather
// than repeating the altitude test.
function projectToDisc(altitudeDeg, azimuthDeg, centreX, centreY, radiusPx) {
  if (altitudeDeg < 0) return null
  var r = radiusPx * (90.0 - altitudeDeg) / 90.0
  var theta = azimuthDeg * DEG
  return {
    x: centreX - r * Math.sin(theta),
    y: centreY - r * Math.cos(theta)
  }
}

// B-V colour index to an approximate RGB string.
//
// Hot blue-white stars sit near -0.3, the Sun at 0.65, cool red giants past
// 1.6. The ramp is deliberately gentle. The eye's colour receptors barely fire
// at night, so real naked-eye stars read as near-white with a hint of tint --
// only Betelgeuse, Antares and Arcturus are obviously coloured. A ramp tuned
// for saturation instead of realism turns the chart into confetti, which is
// what the first draft of this function did.
//
// Reference points the ramp is built to hit:
//   -0.4  Spica, Rigel        rgb(191,204,255)  clearly blue
//    0.0  Vega                rgb(240,245,255)  white
//    0.65 the Sun, Capella    rgb(255,247,235)  barely warm
//    1.2  Arcturus            rgb(255,224,197)  amber
//    1.8  Betelgeuse          rgb(255,199,156)  orange
function starColour(colourIndex) {
  var bv = Math.max(-0.4, Math.min(2.0, colourIndex))
  var red
  var green
  var blue

  if (bv < 0.0) {
    var hot = (bv + 0.4) / 0.4
    red = 0.75 + 0.19 * hot
    green = 0.80 + 0.16 * hot
    blue = 1.0
  } else if (bv < 0.65) {
    var mid = bv / 0.65
    red = 0.94 + 0.06 * mid
    green = 0.96 + 0.01 * mid
    blue = 1.0 - 0.08 * mid
  } else {
    var warmth = Math.min(1.0, (bv - 0.65) / 1.15)
    red = 1.0
    green = 0.97 - 0.19 * warmth
    blue = 0.92 - 0.31 * warmth
  }

  return "rgb(" + Math.round(255 * Math.max(0, Math.min(1, red))) + ","
      + Math.round(255 * Math.max(0, Math.min(1, green))) + ","
      + Math.round(255 * Math.max(0, Math.min(1, blue))) + ")"
}
