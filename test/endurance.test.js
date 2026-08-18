// Run: node test/endurance.test.js
//
// Fixtures are real captures: the result links from each championship's index
// page, and two genuine race classifications.
var fs = require("fs")
var E = require("../Endurance.js")

var failures = 0
function check(label, ok, detail) { if (!ok) { failures++; console.log("FAIL  " + label + (detail ? "  " + detail : "")) } }
function eq(label, actual, expected) { check(label, actual === expected, "got " + JSON.stringify(actual) + " want " + JSON.stringify(expected)) }

var now = Date.now()
function fixture(name) { return fs.readFileSync(__dirname + "/../fixtures/endurance/" + name, "utf8") }

console.log("=== index parsing ===")
;["wec", "elms", "imsa"].forEach(function(slug) {
  var sessions = E.parseIndex(fixture(slug + "-index.txt"), slug)
  var best = E.pickLatest(sessions)
  console.log("  " + slug.padEnd(5) + " classifications=" + String(sessions.length).padEnd(4) +
              " latest: " + (best ? best.event + " / " + E.prettySession(best) : "none"))
  check(slug + " finds classifications", sessions.length > 0)
  check(slug + " picks one", best !== null)
  // The whole point is the race, not the third practice session.
  check(slug + " picks a race", /race/i.test(best.session + " " + best.file), best.session)
  check(slug + " builds a URL", E.classificationUrl(slug, best).indexOf("http") === 0)
  // Only the 03_ family is a classification; 23_Analysis and 26_Weather are not.
  sessions.forEach(function(s) { check(slug + " only takes classifications", /^03_/.test(s.file), s.file) })
})

// A race split into hours must resolve to the last one, or the standings are
// whatever they were an hour before the finish.
var wecSessions = E.parseIndex(fixture("wec-index.txt"), "wec")
var wecBest = E.pickLatest(wecSessions)
var wecHours = wecSessions.filter(function(s) { return s.hour > 0 })
console.log("  wec race hours present:", wecHours.map(function(s) { return s.hour }).join(","))
if (wecHours.length > 0)
  eq("the final hour wins", wecBest.hour, Math.max.apply(null, wecHours.map(function(s) { return s.hour })))

console.log("\n=== classification parsing ===")
;[["wec", "wec-race.csv"], ["imsa", "imsa-race.csv"]].forEach(function(pair) {
  var rows = E.parseClassification(fixture(pair[1]))
  console.log("  " + pair[0] + " entries=" + rows.length + "  winner: #" + rows[0].number + " " + rows[0].team)
  check(pair[0] + " parses rows", rows.length > 0)
  eq(pair[0] + " starts at P1", rows[0].position, 1)
  check(pair[0] + " names the winner", rows[0].team !== "")
  check(pair[0] + " has a car number", rows[0].number !== "")
  // Positions must ascend; the file order is not guaranteed.
  for (var i = 1; i < rows.length; i++)
    check(pair[0] + " positions ascend", rows[i].position >= rows[i - 1].position)
  // The BOM: without stripping it the first column name is "﻿POSITION"
  // and every lookup misses, yielding zero rows.
  check(pair[0] + " survives the BOM", rows[0].position === 1)
})

var wecRows = E.parseClassification(fixture("wec-race.csv"))
check("WEC lists drivers", wecRows[0].drivers.length >= 2, JSON.stringify(wecRows[0].drivers))
check("WEC carries a class", wecRows[0].cls !== "")
var imsaRows = E.parseClassification(fixture("imsa-race.csv"))
check("IMSA carries laps", imsaRows[0].laps !== "")
check("IMSA carries a gap for P2", imsaRows[1].gap !== "")

console.log("\n=== normalized game ===")
var game = E.toGame("wec", wecBest, wecRows, now)
console.log("  \"" + game.name + "\"  [" + game.sessionLabel + "]  " + game.state)
game.leaders.forEach(function(l) { console.log("    " + l.order + ". " + l.name + "  " + l.detail) })
check("it is an event", game.isEvent === true)
// Results, never live. Anything else would make the poller treat it as live.
eq("always final", game.state, "FINAL")
eq("three leaders", game.leaders.length, 3)
check("winner shows the class", game.leaders[0].detail === wecRows[0].cls)
check("the rest show a gap", game.leaders[1].detail !== game.leaders[2].detail,
      "both read " + game.leaders[1].detail)
check("no team sides", game.home.abbr === "" && game.away.abbr === "")
check("start time parsed from the folder stamp", game.startUtc > 0)

console.log("\n=== bad input ===")
eq("empty CSV", E.parseClassification("").length, 0)
eq("headers only", E.parseClassification("POSITION;NUMBER").length, 0)
eq("garbage CSV", E.parseClassification("not;a;classification").length, 0)
eq("empty index", E.parseIndex("", "wec").length, 0)
eq("index with no results", E.parseIndex("<html><body>nothing</body></html>", "wec").length, 0)
check("nothing to pick returns null", E.pickLatest([]) === null)
check("unknown championship has no index", E.indexUrl("nope") === "")
check("known ones do", E.indexUrl("wec").indexOf("http") === 0)
eq("event names are cleaned", E.cleanEventName("04_SAO%20PAULO".replace("%20", " ")), "Sao Paulo")
eq("a bad stamp is zero", E.stampToMs("nope"), 0)

console.log(failures === 0 ? "\nOK — all assertions passed" : "\n" + failures + " FAILURES")
process.exit(failures === 0 ? 0 : 1)
