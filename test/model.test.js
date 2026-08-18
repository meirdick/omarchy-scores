var fs = require("fs")
var P = require("../Providers.js")
var M = require("../Model.js")
var L = require("../Leagues.js")

var failures = 0
function check(label, ok, detail) { if (!ok) { failures++; console.log("FAIL  " + label + (detail ? "  " + detail : "")) } }
function eq(label, actual, expected) { check(label, actual === expected, "got " + JSON.stringify(actual) + " want " + JSON.stringify(expected)) }

var now = Date.now()
var mlb = P.espn.parseScoreboard(fs.readFileSync(__dirname + "/../fixtures/mlb.json", "utf8"), "mlb", now).games
var live = mlb.filter(function(g) { return g.state === "LIVE" })[0]
var pre = mlb.filter(function(g) { return g.state === "PRE" })[0]
var final = mlb.filter(function(g) { return g.state === "FINAL" })[0]

console.log("=== follows ===")
eq("followKey normalizes case", M.followKey("mlb", "bos"), "mlb:BOS")
console.log("  normalize string:", JSON.stringify(M.normalizeFollows("mlb:bos, nfl:NYJ  nhl:BOS")))
eq("normalize dedupes", M.normalizeFollows(["mlb:BOS", "mlb:bos"]).length, 1)
eq("normalize rejects junk", M.normalizeFollows(["", "garbage", "mlb:BOS"]).length, 1)
console.log("  toggle on: ", JSON.stringify(M.toggleFollow([], "mlb", "BOS")))
console.log("  toggle off:", JSON.stringify(M.toggleFollow(["mlb:BOS"], "mlb", "bos")))
eq("toggle off removes", M.toggleFollow(["mlb:BOS"], "mlb", "bos").length, 0)

console.log("\n=== countdown ===")
;[[0,"now"],[30*1000,"now"],[14*60000,"14m"],[95*60000,"1h 35m"],[120*60000,"2h"],[30*3600000,"1d 6h"]].forEach(function(c){
  var got = M.countdown(c[0]); console.log("  " + c[0] + "ms -> " + got); eq("countdown " + c[0], got, c[1])
})

console.log("\n=== status labels ===")
console.log("  LIVE :", M.statusLabel(live, now))
console.log("  PRE  :", M.statusLabel(pre, now))
console.log("  FINAL:", M.statusLabel(final, now))
eq("live uses provider wording", M.statusLabel(live, now), live.rawStatus)
check("pre is reformatted, not passed through", M.statusLabel(pre, now) !== pre.rawStatus, M.statusLabel(pre, now))
eq("final", M.statusLabel(final, now), "Final")

console.log("\n=== situation ===")
console.log("  ", M.situationLine(live))
check("baseball situation renders", /out/.test(M.situationLine(live)), M.situationLine(live))
eq("empty bases", M.basesLabel([false,false,false]), "bases empty")
eq("loaded", M.basesLabel([true,true,true]), "bases loaded")
eq("corners", M.basesLabel([true,false,true]), "1st & 3rd")
eq("no situation on final", M.situationLine(final), "")

console.log("\n=== bar ===")
var follows = ["mlb:" + live.home.abbr]
var bar = M.barState(mlb, follows, now, {})
console.log("  live mode  :", bar.mode, "|", bar.text, "| count", bar.count)
eq("bar picks live", bar.mode, "live")
check("bar text has both teams", bar.text.indexOf(live.home.abbr) >= 0 && bar.text.indexOf(live.away.abbr) >= 0, bar.text)
console.log("  compact    :", M.barState(mlb, follows, now, {format:"compact"}).text)

// Synthesised rather than taken from the fixture: a fixture's "scheduled"
// game starts for real a few hours after capture, and then this stops testing
// the upcoming path at all.
var future = JSON.parse(JSON.stringify(pre))
future.startUtc = now + 2 * 3600000 + 14 * 60000
var withFuture = mlb.concat([future])
var preOnly = M.barState(withFuture, ["mlb:" + future.home.abbr], now, {})
console.log("  upcoming   :", preOnly.mode, "|", preOnly.text)
eq("falls back to countdown", preOnly.mode, "upcoming")
check("countdown text present", /\d+[hm]/.test(preOnly.text), preOnly.text)

var none = M.barState(mlb, ["nfl:NYJ"], now, {})
console.log("  idle       :", none.mode, "| text=" + JSON.stringify(none.text))
eq("idle when nothing followed plays", none.mode, "idle")
eq("idle renders nothing", none.text, "")

// Rotation must wrap rather than run off the end of the list.
var manyFollows = mlb.filter(function(g){return g.state==="LIVE"}).map(function(g){return "mlb:"+g.home.abbr})
var r0 = M.barState(mlb, manyFollows, now, {rotateIndex:0})
var rWrap = M.barState(mlb, manyFollows, now, {rotateIndex: r0.count})
console.log("  rotate 0/" + r0.count + ":", r0.text)
console.log("  rotate wrap:", rWrap.text)
eq("rotation wraps", rWrap.text, r0.text)

console.log("\n=== diff ===")
function clone(g) { return JSON.parse(JSON.stringify(g)) }
var prevMap = {}
mlb.forEach(function(g) { prevMap[g.id] = clone(g) })

var after = mlb.map(clone)
var scorer = after.filter(function(g) { return g.id === live.id })[0]
scorer.home.score = scorer.home.score + 2
var events = M.diffGames(prevMap, after, { follows: follows })
console.log("  score event:", events.map(function(e){return e.type}).join(","))
eq("one score event", events.length, 1)
eq("event type", events[0].type, "score")
eq("scoring team identified", events[0].scoringTeam.abbr, live.home.abbr)
console.log("  notification:", JSON.stringify(M.notificationFor(events[0], now)))

var started = mlb.map(clone)
var starter = started.filter(function(g) { return g.id === pre.id })[0]
starter.state = "LIVE"; starter.rawStatus = "Top 1st"
var startEvents = M.diffGames(prevMap, started, { follows: ["mlb:" + pre.home.abbr] })
eq("start event fires", startEvents.length && startEvents[0].type, "start")

var ended = mlb.map(clone)
var ender = ended.filter(function(g) { return g.id === live.id })[0]
ender.state = "FINAL"; ender.rawStatus = "Final"
var endEvents = M.diffGames(prevMap, ended, { follows: follows })
eq("final event fires", endEvents.length && endEvents[0].type, "final")

eq("suppressed on first poll", M.diffGames(prevMap, after, { follows: follows, suppress: true }).length, 0)
eq("unfollowed teams are silent", M.diffGames(prevMap, after, { follows: ["nfl:NYJ"] }).length, 0)
eq("unseen game is silent", M.diffGames({}, after, { follows: follows }).length, 0)
// A score going backwards (a correction) must not read as a score event.
var corrected = mlb.map(clone)
corrected.filter(function(g){return g.id===live.id})[0].home.score -= 1
eq("score corrections are silent", M.diffGames(prevMap, corrected, { follows: follows }).length, 0)

console.log("\n=== close game ===")
var close = clone(live)
close.sport = "baseball"; close.period = 9
close.home.score = 4; close.away.score = 4
check("tied late is close", M.isCloseGame(close, { closeMargin: 1 }))
close.period = 3
check("tied early is not close", !M.isCloseGame(close, { closeMargin: 1 }))
close.period = 9; close.home.score = 9
check("blowout is not close", !M.isCloseGame(close, { closeMargin: 1 }))

console.log("\n=== poll pacing ===")
eq("live pace",    M.pollIntervalSec(mlb, follows, now, {}), 25)
eq("panel open forces live", M.pollIntervalSec(mlb, ["nfl:NYJ"], now, { panelOpen: true }), 25)
var far = mlb.map(clone); far.forEach(function(g) { g.state = "PRE"; g.startUtc = now + 20 * 3600000 })
eq("nothing soon backs right off", M.pollIntervalSec(far, ["mlb:" + far[0].home.abbr], now, {}), 3600)
var soon = mlb.map(clone); soon.forEach(function(g) { g.state = "PRE"; g.startUtc = now + 30 * 60000 })
eq("imminent game polls every 5m", M.pollIntervalSec(soon, ["mlb:" + soon[0].home.abbr], now, {}), 300)
eq("no followed games at all", M.pollIntervalSec(mlb, [], now, {}), 3600)

console.log("\n=== rows ===")
var rows = M.buildRows({ route: "", games: mlb, follows: follows, now: now })
console.log(rows.slice(0, 8).map(function(r) {
  return "  " + r.kind.padEnd(8) + (r.title || (r.game ? r.game.name + " " + r.status : r.label || r.text || ""))
}).join("\n"))
check("rows built", rows.length > 3)
check("first selectable is not a header", rows[M.firstSelectable(rows)].selectable !== false)
check("live section first", rows[0].kind === "section" && rows[0].title === "Live", JSON.stringify(rows[0]))
var keys = {}; var dupes = 0
rows.forEach(function(r) { if (keys[r.key]) dupes++; keys[r.key] = true })
eq("row keys are unique", dupes, 0)

var empty = M.buildRows({ route: "", games: [], follows: [], now: now })
check("empty state explains itself", empty.some(function(r) { return r.kind === "note" }), JSON.stringify(empty.map(function(r){return r.kind})))

var leagueList = M.buildRows({ route: "leagues", games: [], follows: [], now: now, leagueCounts: { mlb: 11 } })
check("league list built", leagueList.filter(function(r) { return r.kind === "league" }).length === 20)

var detail = M.buildRows({ route: "game:" + live.id, games: mlb, follows: follows, now: now,
  summary: { scoringPlays: [{text:"HR", teamAbbr:live.home.abbr, home:1, away:0}], leaders: [] } })
console.log("  detail kinds:", detail.map(function(r) { return r.kind }).join(","))
check("detail has the game", detail.some(function(r) { return r.kind === "game" }))
check("detail has an open action", detail.some(function(r) { return r.action === "open" }))

var missing = M.buildRows({ route: "game:espn:does-not-exist", games: mlb, follows: follows, now: now })
check("missing game degrades to a note", missing.some(function(r) { return r.kind === "note" }))

var search = M.buildRows({ route: "search", games: mlb, follows: follows, now: now, filter: "red",
  teams: [{league:"mlb",abbr:"BOS",name:"Boston Red Sox",location:"Boston"}] })
console.log("  search kinds:", search.map(function(r) { return r.kind }).join(","))
check("search finds by name", search.some(function(r) { return r.kind === "team" && r.abbr === "BOS" }))

console.log(failures === 0 ? "\nOK — all assertions passed" : "\n" + failures + " FAILURES")
process.exit(failures === 0 ? 0 : 1)
