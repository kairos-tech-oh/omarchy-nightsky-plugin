#!/usr/bin/env node
"use strict";
process.env.TZ = "America/New_York";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(path.join(__dirname, "..", "PanelLogic.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const ctx = {};
vm.runInNewContext(src + "\nthis.L = { formatClock, formatOffset, userOffsetSec, showsForeignClock, foreignClockLine, relativeToNow, dayLengthLabel, cappedCurl, parseCappedJson };", ctx);
const F = ctx.L;

let failed = 0;
function check(name, cond, detail) {
  if (cond) console.log("ok   " + name);
  else { failed++; console.log("FAIL " + name + (detail === undefined ? "" : "  got " + JSON.stringify(detail))); }
}
function throws(fn) { try { fn(); return false; } catch (e) { return true; } }

const noonUtc = Date.UTC(2026, 6, 1, 12, 5);
const midnightUtc = Date.UTC(2026, 6, 1, 0, 7);
check("formatClock: place clock in 24h", F.formatClock(noonUtc, 9 * 3600, false) === "21:05", F.formatClock(noonUtc, 9 * 3600, false));
check("formatClock: place clock ignores the host's timezone", F.formatClock(noonUtc, 0, false) === "12:05");
check("formatClock: half-hour offset", F.formatClock(noonUtc, 5.5 * 3600, false) === "17:35");
check("formatClock: 12h midnight and noon", F.formatClock(midnightUtc, 0, true) === "12:07 AM" && F.formatClock(noonUtc, 0, true) === "12:05 PM");
check("formatClock: 12h hours are not zero-padded", F.formatClock(Date.UTC(2026, 6, 1, 9, 3), 0, true) === "9:03 AM");
check("formatClock: 24h hours are zero-padded", F.formatClock(Date.UTC(2026, 6, 1, 9, 3), 0, false) === "09:03");
check("formatClock: NaN offset uses the host clock (EDT in July)", F.formatClock(noonUtc, NaN, false) === "08:05", F.formatClock(noonUtc, NaN, false));
check("formatClock: missing time reads --:--", [null, undefined, NaN].every((v) => F.formatClock(v, 0, false) === "--:--"));

check("formatOffset: whole hours", F.formatOffset(9 * 3600) === "UTC+9" && F.formatOffset(-4 * 3600) === "UTC-4");
check("formatOffset: half and quarter hours", F.formatOffset(5.5 * 3600) === "UTC+5:30" && F.formatOffset(5.75 * 3600) === "UTC+5:45" && F.formatOffset(-3.5 * 3600) === "UTC-3:30");
check("formatOffset: zero and missing", F.formatOffset(0) === "UTC+0" && F.formatOffset(NaN) === "");

check("userOffsetSec: EDT in July, EST in January", F.userOffsetSec(noonUtc) === -4 * 3600 && F.userOffsetSec(Date.UTC(2026, 0, 15)) === -5 * 3600);

check("showsForeignClock: same offset hides the line", !F.showsForeignClock(-4 * 3600, -4 * 3600) && !F.showsForeignClock(-4 * 3600 + 30, -4 * 3600));
check("showsForeignClock: different offset shows it", F.showsForeignClock(9 * 3600, -4 * 3600));
check("showsForeignClock: unknown place offset hides it", !F.showsForeignClock(NaN, 0));
check("foreignClockLine: place clock, zone and offset", F.foreignClockLine(noonUtc, 9 * 3600, "Asia/Tokyo", -4 * 3600, false) === "21:05 local, Asia/Tokyo · UTC+9", F.foreignClockLine(noonUtc, 9 * 3600, "Asia/Tokyo", -4 * 3600, false));
check("foreignClockLine: no zone name omits it", F.foreignClockLine(noonUtc, 9 * 3600, "", -4 * 3600, true) === "9:05 PM local · UTC+9");
check("foreignClockLine: empty for the user's own clock or no time", F.foreignClockLine(noonUtc, -4 * 3600, "X", -4 * 3600, false) === "" && F.foreignClockLine(null, 9 * 3600, "X", 0, false) === "");

const now = Date.UTC(2026, 6, 1, 12, 0);
const plus = (min) => now + min * 60000;
check("relativeToNow: past and present read now", F.relativeToNow(plus(-5), now) === "now" && F.relativeToNow(now, now) === "now");
check("relativeToNow: minutes", F.relativeToNow(plus(45), now) === "in 45 min");
check("relativeToNow: hours and minutes", F.relativeToNow(plus(125), now) === "in 2h 5m" && F.relativeToNow(plus(120), now) === "in 2h");
check("relativeToNow: days", F.relativeToNow(plus(60 * 50), now) === "in 2d");
check("relativeToNow: missing time is empty", F.relativeToNow(null, now) === "" && F.relativeToNow(NaN, now) === "");

check("dayLengthLabel: hours and minutes of daylight", F.dayLengthLabel({ sunriseMs: plus(0), sunsetMs: plus(14 * 60 + 32) }) === "14h 32m of daylight");
check("dayLengthLabel: polar day and night", F.dayLengthLabel({ polar: "day" }) === "Sun up all day" && F.dayLengthLabel({ polar: "night" }) === "Sun below the horizon all day");
check("dayLengthLabel: missing data is empty", F.dayLengthLabel(null) === "" && F.dayLengthLabel({ sunriseMs: null, sunsetMs: plus(1) }) === "");

const cmd = F.cappedCurl("https://api.open-meteo.com/v1/x", 1000, 10, ["-A", "ua"]);
check("cappedCurl: caps at cap+1 bytes", cmd.indexOf("1001") > 0, cmd);
check("cappedCurl: restricts to https with the = form", cmd[cmd.indexOf("--proto") + 1] === "=https" && !cmd.some((a) => /^--proto=/.test(a)), cmd);
check("cappedCurl: no redirects", !cmd.some((a) => /^-[A-Za-z]*L/.test(a) || /^--location/.test(a)), cmd);
check("cappedCurl: url is passed after --", cmd[cmd.length - 2] === "--" && cmd[cmd.length - 1] === "https://api.open-meteo.com/v1/x");
const zero = F.cappedCurl("https://x/", 10, 0);
check("cappedCurl: a zero budget still has a deadline", zero[zero.indexOf("--max-time") + 1] === "1" && zero[3] === "6", zero);

check("parseCappedJson: blank body throws", throws(() => F.parseCappedJson(" ", 100)));
check("parseCappedJson: oversized body throws", throws(() => F.parseCappedJson('{"a":"' + "x".repeat(200) + '"}', 100)));
check("parseCappedJson: valid body parses", F.parseCappedJson('{"a":1}', 100).a === 1);

console.log(failed === 0 ? "\nall panel checks passed" : "\n" + failed + " panel check(s) failed");
process.exit(failed === 0 ? 0 : 1);
