// Run: node test/providers.test.js   (from the plugin root)
var fs = require("fs")
var P = require("../Providers.js")

var now = Date.now()
var FIXTURES = [["mlb","mlb"],["nfl","nfl"],["eng1","eng.1"],["nhl","nhl"],["wnba","wnba"]]
var failures = 0

function check(label, condition, detail) {
  if (!condition) { failures++; console.log("FAIL  " + label + (detail ? "  " + detail : "")) }
}

FIXTURES.forEach(function(pair) {
  var text = fs.readFileSync(__dirname + "/../fixtures/" + pair[0] + ".json", "utf8")
  var result = P.espn.parseScoreboard(text, pair[1], now)
  console.log("--- " + pair[1] + "  ok=" + result.ok + "  n=" + result.games.length)
  check(pair[1] + " parses", result.ok)
  check(pair[1] + " has games", result.games.length > 0)
  result.games.slice(0, 3).forEach(function(g) {
    console.log("   ", g.state.padEnd(9),
      (g.away.abbr + " " + g.away.score + " @ " + g.home.abbr + " " + g.home.score).padEnd(22),
      "|", String(g.rawStatus).padEnd(20),
      "| sit:", g.situation ? g.situation.kind : "-", "| sport:", g.sport)
  })
  result.games.forEach(function(g) {
    check("home/away both resolved in " + pair[1], g.home.abbr !== "" && g.away.abbr !== "", g.name)
    check("state is known in " + pair[1], ["PRE","LIVE","FINAL","POSTPONED"].indexOf(g.state) >= 0, g.state)
    check("id namespaced in " + pair[1], g.id.indexOf("espn:") === 0, g.id)
    check("startUtc parsed in " + pair[1], g.startUtc > 0, g.name)
    // A live or final game must carry integer scores, never the raw strings.
    if (g.state === "LIVE" || g.state === "FINAL")
      check("scores are ints in " + pair[1], typeof g.home.score === "number" && typeof g.away.score === "number", g.name)
  })
})

var mlbResult = P.espn.parseScoreboard(fs.readFileSync(__dirname + "/../fixtures/mlb.json", "utf8"), "mlb", now)
var live = mlbResult.games.filter(function(g) { return g.state === "LIVE" && g.situation })[0]
console.log("\nlive situation:", JSON.stringify(live.situation))
console.log("detailUrl:     ", live.detailUrl)
console.log("home record:   ", live.home.record, "| color:", live.home.color, "| lines:", live.home.lines.join(","))
check("baseball situation kind", live.situation.kind === "baseball")
check("bases is a 3-tuple", Array.isArray(live.situation.bases) && live.situation.bases.length === 3)
check("detailUrl found", /espn\.com/.test(live.detailUrl))
check("color has #", live.home.color.charAt(0) === "#")

var delayed = mlbResult.games.filter(function(g) { return g.delayed })
console.log("delayed:       ", JSON.stringify(delayed.map(function(g) { return [g.name, g.state, g.rawStatus] })))
check("delayed game stays LIVE", delayed.length === 0 || delayed[0].state === "LIVE")

console.log("\nbad input:", JSON.stringify(P.espn.parseScoreboard("not json", "mlb", now)))
console.log("empty:    ", JSON.stringify(P.espn.parseScoreboard("", "mlb", now)))
check("garbage does not throw", P.espn.parseScoreboard("not json", "mlb", now).ok === false)
check("empty does not throw", P.espn.parseScoreboard("", "mlb", now).ok === false)
check("null does not throw", P.espn.parseScoreboard(null, "mlb", now).ok === false)

console.log("\nurls:")
console.log("  ", P.espn.scoreboardUrl("mlb", new Date()))
console.log("  ", P.espn.standingsUrl("mlb"))
console.log("  ", P.espn.summaryUrl("mlb", "401816563"))
console.log("  ", P.mlb.scoreboardUrl("mlb", new Date()))
console.log("  ", P.nhl.scoreboardUrl("nhl", new Date()))
check("unknown league yields no url", P.espn.scoreboardUrl("!!", new Date()) === "")
check("mlb provider refuses other leagues", P.mlb.scoreboardUrl("nfl", new Date()) === "")

// --- summaries -------------------------------------------------------------
// The two sports disagree about where scoring lives and how a team is named.
// Both must come out the same shape or the detail view renders "?" for a team.
;[["mlb", 9], ["nfl", 7]].forEach(function(pair) {
  var summary = P.espn.parseSummary(fs.readFileSync(__dirname + "/../fixtures/" + pair[0] + "-summary.json", "utf8"))
  console.log("\nsummary " + pair[0] + ": " + summary.scoringPlays.length + " scoring, " + summary.leaders.length + " leaders")
  check(pair[0] + " summary parses", summary !== null)
  check(pair[0] + " finds scoring plays", summary.scoringPlays.length === pair[1],
        "got " + summary.scoringPlays.length + " want " + pair[1])
  summary.scoringPlays.forEach(function(play) {
    // The regression this guards: baseball sends {team:{id:"1"}} with no
    // abbreviation, so an abbreviation-only read leaves every row blank.
    check(pair[0] + " play names a team", /^[A-Z]{2,4}$/.test(play.teamAbbr), JSON.stringify(play.teamAbbr))
    check(pair[0] + " play has text", play.text !== "")
    check(pair[0] + " play has a running score", play.home !== null && play.away !== null)
  })
})
check("summary of garbage is null", P.espn.parseSummary("nope") === null)
check("summary of empty is null", P.espn.parseSummary("") === null)

// --- standings ordering ----------------------------------------------------
// Each sport is read by a different column, and ESPN does not return the
// entries in table order. Getting this wrong put a 46-36 team above a 56-26 one.
;[["mlb", "winPercent"], ["nba", "winPercent"], ["nhl", "points"], ["eng1", "rank"]].forEach(function(pair) {
  var groups = P.espn.parseStandings(fs.readFileSync(__dirname + "/../fixtures/" + pair[0] + "-standings.json", "utf8"))
  check(pair[0] + " standings parse", groups.length > 0)
  var rows = groups[0].rows
  console.log("\n" + pair[0] + " (" + groups[0].name + ") ordered by " + pair[1] + ":")
  rows.slice(0, 4).forEach(function(r, i) {
    console.log("   " + (i + 1) + ". " + r.name.padEnd(24) + " " + (r.wins + "-" + r.losses).padEnd(8) +
      " pct=" + (r.winPercent || "-").padEnd(6) + " pts=" + (r.points || "-"))
  })
  check(pair[0] + " table is not empty", rows.length > 1)

  // Whatever the sport ranks on must be non-increasing down the table.
  for (var i = 1; i < rows.length; i++) {
    var prev = rows[i - 1], cur = rows[i]
    if (pair[1] === "rank")
      check(pair[0] + " rank ascends", prev.rank <= cur.rank, prev.name + " then " + cur.name)
    else if (pair[1] === "winPercent")
      check(pair[0] + " win percentage descends", prev._winPercent >= cur._winPercent,
            prev.name + " " + prev.winPercent + " then " + cur.name + " " + cur.winPercent)
    else
      check(pair[0] + " points descend", prev._points >= cur._points,
            prev.name + " " + prev.points + " then " + cur.name + " " + cur.points)
  }
})

// playoffSeed must not be mistaken for a table order: MLB seeds division
// winners first, which is the bug this guards.
var mlbStand = P.espn.parseStandings(fs.readFileSync(__dirname + "/../fixtures/mlb-standings.json", "utf8"))
var seeds = mlbStand[0].rows.map(function(r) { return r.seed })
check("MLB is not merely sorted by playoff seed",
      seeds.some(function(s, i) { return i > 0 && s < seeds[i - 1] }),
      "seeds came out ascending, so seed order was used")

console.log(failures === 0 ? "\nOK — all assertions passed" : "\n" + failures + " FAILURES")
process.exit(failures === 0 ? 0 : 1)
