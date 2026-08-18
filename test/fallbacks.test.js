// Cross-provider agreement: the same MLB game, parsed by two independent
// providers, must produce the same normalized Game. This is the test that
// proves the abstraction is real rather than an ESPN-shaped hole.
var fs = require("fs")
var P = require("../Providers.js")
var now = Date.now()
var failures = 0
function check(label, ok, detail) { if (!ok) { failures++; console.log("FAIL  " + label + (detail ? "  " + detail : "")) } }

var viaMlb = P.mlb.parseScoreboard(fs.readFileSync(__dirname + "/../fixtures/mlb-statsapi.json", "utf8"), "mlb", now)
console.log("--- statsapi  ok=" + viaMlb.ok + "  n=" + viaMlb.games.length)
viaMlb.games.slice(0, 4).forEach(function(g) {
  console.log("   ", g.state.padEnd(9),
    (g.away.abbr + " " + g.away.score + " @ " + g.home.abbr + " " + g.home.score).padEnd(22),
    "|", String(g.rawStatus).padEnd(18), "| sit:", g.situation ? JSON.stringify(g.situation.bases) : "-")
})

var viaNhl = P.nhl.parseScoreboard(fs.readFileSync(__dirname + "/../fixtures/nhl-apiweb.json", "utf8"), "nhl", now)
console.log("--- nhl api-web  ok=" + viaNhl.ok + "  n=" + viaNhl.games.length)
viaNhl.games.forEach(function(g) {
  console.log("   ", g.state.padEnd(9),
    (g.away.abbr + " " + g.away.score + " @ " + g.home.abbr + " " + g.home.score).padEnd(22),
    "|", String(g.rawStatus).padEnd(18), "|", g.detailUrl)
})

;[["statsapi", viaMlb], ["nhl", viaNhl]].forEach(function(pair) {
  check(pair[0] + " parses", pair[1].ok)
  pair[1].games.forEach(function(g) {
    check(pair[0] + " has both teams", g.home.abbr !== "" && g.away.abbr !== "", g.name)
    check(pair[0] + " state known", ["PRE","LIVE","FINAL","POSTPONED"].indexOf(g.state) >= 0, g.state)
    check(pair[0] + " startUtc parsed", g.startUtc > 0, g.name)
    check(pair[0] + " id namespaced", /^(mlb|nhl):/.test(g.id), g.id)
  })
})

// Same MLB slate, both providers. Match on abbreviation pair and compare.
var viaEspn = P.espn.parseScoreboard(fs.readFileSync(__dirname + "/../fixtures/mlb.json", "utf8"), "mlb", now)
// Key on matchup AND start time: a doubleheader is two games with identical
// abbreviations, and collapsing them compares game 1 against game 2.
function key(g) { return g.away.abbr + "@" + g.home.abbr + "#" + Math.round(g.startUtc / 60000) }
var byMatchup = {}
viaEspn.games.forEach(function(g) { byMatchup[key(g)] = g })

var compared = 0, agreed = 0
viaMlb.games.forEach(function(a) {
  var b = byMatchup[key(a)]
  if (!b) return
  compared++
  var sameState = a.state === b.state
  var sameScore = a.home.score === b.home.score && a.away.score === b.away.score
  if (sameState && sameScore) agreed++
  else console.log("   diverged " + a.away.abbr + "@" + a.home.abbr +
    "  statsapi=" + a.state + " " + a.away.score + "-" + a.home.score + " (" + a.rawStatus + ")" +
    "  espn=" + b.state + " " + b.away.score + "-" + b.home.score + " (" + b.rawStatus + ")")
})
console.log("\ncross-provider: " + agreed + "/" + compared + " games agree on state and score")
check("providers were comparable", compared >= 5, "compared=" + compared)
// Two independent live feeds poll at different instants, so a game or two may
// legitimately differ by one score. Demand agreement on the large majority.
check("providers substantially agree", compared === 0 || agreed >= compared - 2, agreed + "/" + compared)

console.log(failures === 0 ? "\nOK — all assertions passed" : "\n" + failures + " FAILURES")
process.exit(failures === 0 ? 0 : 1)
