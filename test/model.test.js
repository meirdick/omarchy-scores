var fs = require("fs")
var P = require("../Providers.js")
var M = require("../Model.js")
var L = require("../Leagues.js")

var failures = 0
function check(label, ok, detail) { if (!ok) { failures++; console.log("FAIL  " + label + (detail ? "  " + detail : "")) } }
function eq(label, actual, expected) { check(label, actual === expected, "got " + JSON.stringify(actual) + " want " + JSON.stringify(expected)) }

var now = Date.now()
var STANDINGS = [{ name: "American League", rows: [
  { abbr: "TB",  name: "Tampa Bay Rays",   logo: "", wins: "74", losses: "49", ties: "0", streak: "L3" },
  { abbr: "NYY", name: "New York Yankees", logo: "", wins: "69", losses: "55", ties: "0", streak: "W1" }
] }]
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
// Count the catalogue rather than hardcoding a number that changes whenever a
// series is added.
eq("every catalogued league is listed",
   leagueList.filter(function(r) { return r.kind === "league" }).length,
   L.browseList().length)
check("racing series are among them",
      leagueList.some(function(r) { return r.kind === "league" && r.league === "indycar" }))

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

console.log("\n=== league following ===")
var byLeague = M.barState(mlb, [], now, { leagues: ["mlb"] })
console.log("  league-only follow :", byLeague.mode, "|", byLeague.text, "| count", byLeague.count)
check("a followed league fills the bar", byLeague.mode === "live")
check("a followed league offers every live game", byLeague.count > 1, "count=" + byLeague.count)

var liveHome = mlb.filter(function(g) { return g.state === "LIVE" })[0].home.abbr
var mixed = M.barState(mlb, ["mlb:" + liveHome], now, { leagues: ["mlb"] })
console.log("  club beats league  :", mixed.text, "| count", mixed.count)
eq("your club wins the bar slot", mixed.count, 1)
check("and it is your club", mixed.game.home.abbr === liveHome || mixed.game.away.abbr === liveHome)

var leagueRows = M.buildRows({ route: "", games: mlb, follows: [], followedLeagues: ["mlb"], now: now })
check("league follow makes games yours", leagueRows.some(function(r) { return r.kind === "game" && r.followed }))
check("but not by team", !leagueRows.some(function(r) { return r.kind === "game" && r.followedByTeam }))

var list = M.buildRows({ route: "leagues", games: [], follows: [], followedLeagues: ["nfl"], now: now })
var nfl = list.filter(function(r) { return r.kind === "league" && r.league === "nfl" })[0]
check("followed league is marked in the list", nfl && nfl.followed === true)

console.log("\n=== follow is not a toggle ===")
eq("adding twice is idempotent", M.addFollow(M.addFollow([], "mlb", "BOS"), "mlb", "bos").length, 1)
eq("adding a league twice is idempotent", M.addFollowLeague(M.addFollowLeague([], "nfl"), "nfl").length, 1)
eq("removing what is absent is a no-op", M.removeFollow(["mlb:BOS"], "nfl", "NYJ").length, 1)
eq("league list rejects team entries", M.normalizeLeagues(["mlb", "mlb:BOS"]).length, 1)

console.log("\n=== follow actions are always offered ===")
var fresh = M.buildRows({ route: "", games: [], follows: [], followedLeagues: [], now: now })
check("fresh install offers a way to follow", fresh.some(function(r) { return r.action === "search" }))
check("fresh install offers league browsing", fresh.some(function(r) { return r.action === "leagues" }))
var busy = M.buildRows({ route: "", games: mlb, follows: ["mlb:" + liveHome], followedLeagues: [], now: now })
check("still offered once following", busy.some(function(r) { return r.action === "search" }))
check("and they do not lead once there are scores", busy[0].kind === "section" && busy[0].title === "Live")

console.log("\n=== shell.json extraction ===")
var CONFIG = JSON.stringify({
  version: 1,
  bar: { layout: {
    left: [{ id: "omarchy.workspaces" }],
    center: [{ id: "omarchy.clock", format: "HH:mm" }],
    right: [{ id: "omarchy.tray" },
            { id: "meirdick.scores", followedTeams: "mlb:TB, mlb:BOS", livePollSec: 15 },
            { id: "omarchy.power" }]
  } }
})
var entry = M.widgetSettingsFrom(CONFIG, "meirdick.scores")
console.log("  entry:", JSON.stringify(entry))
check("finds our entry", entry && entry.id === "meirdick.scores")
eq("reads a setting off it", entry.livePollSec, 15)
eq("spaced list still parses to two", M.normalizeFollows(entry.followedTeams).length, 2)
eq("a widget that is not listed yields no keys", Object.keys(M.widgetSettingsFrom(CONFIG, "someone.else")).length, 0)
// null, not {} — the difference between "not there" and "cannot read it yet",
// which is what stops a mid-save read from wiping the followed list.
check("half-written JSON returns null", M.widgetSettingsFrom('{"bar":{"lay', "meirdick.scores") === null)
check("empty returns null", M.widgetSettingsFrom("", "meirdick.scores") === null)
eq("a config with no bar yields no keys", Object.keys(M.widgetSettingsFrom('{"version":1}', "meirdick.scores")).length, 0)

console.log("\n=== a team follow does not drag in its league ===")
var oneTeam = M.buildRows({ route: "", games: mlb, follows: ["mlb:" + liveHome], followedLeagues: [], now: now })
var shownGames = oneTeam.filter(function(r) { return r.kind === "game" })
console.log("  following one club shows " + shownGames.length + " game(s) out of " + mlb.length + " on the card")
eq("only the club's own games appear", shownGames.length, 1)
check("and it is the club's game",
      shownGames[0].game.home.abbr === liveHome || shownGames[0].game.away.abbr === liveHome)
check("no section names another league's spillover",
      !oneTeam.some(function(r) { return r.kind === "section" && r.title === "Live elsewhere" }))

var withLeague = M.buildRows({ route: "", games: mlb, follows: ["mlb:" + liveHome], followedLeagues: ["mlb"], now: now })
var leagueSection = withLeague.filter(function(r) { return r.kind === "section" && r.title === "MLB" })[0]
check("following the league adds a section named for it", leagueSection !== undefined)
eq("holding every other game on the card", Number(leagueSection.meta), mlb.length - 1)
// Your own club must not be duplicated into the league's section.
var ids = {}, dupes = 0
withLeague.filter(function(r) { return r.kind === "game" }).forEach(function(r) {
  if (ids[r.game.id]) dupes++
  ids[r.game.id] = true
})
eq("no game is listed twice", dupes, 0)

var order = withLeague.filter(function(r) { return r.kind === "section" }).map(function(r) { return r.title })
console.log("  section order:", order.join(" -> "))
check("your teams come before the league", order.indexOf("Live") < order.indexOf("MLB"))

// The escape hatch, off by default.
var everything = M.buildRows({ route: "", games: mlb, follows: ["mlb:" + liveHome],
                               followedLeagues: [], showAll: true, now: now })
check("showAll brings back the rest", everything.some(function(r) { return r.kind === "section" && r.title === "Also today" }))
check("and it is absent by default", !oneTeam.some(function(r) { return r.kind === "section" && r.title === "Also today" }))

console.log("\n=== a league follow is not the same as following every team ===")
var before = {}, after = mlb.map(function(g) { return JSON.parse(JSON.stringify(g)) })
mlb.forEach(function(g) { before[g.id] = JSON.parse(JSON.stringify(g)) })
// Score in a game involving none of your clubs, in a league you follow.
var neutral = after.filter(function(g) { return g.state === "LIVE" && g.home.abbr !== liveHome })[0]
neutral.home.score = neutral.home.score + 1

var quiet = M.diffGames(before, after, { follows: ["mlb:" + liveHome], leagues: ["mlb"] })
console.log("  league followed, notifyLeagues off ->", quiet.length, "events")
eq("a followed league stays quiet by default", quiet.length, 0)

var loud = M.diffGames(before, after, { follows: ["mlb:" + liveHome], leagues: ["mlb"], notifyLeagues: true })
console.log("  league followed, notifyLeagues on  ->", loud.length, "events")
eq("until you ask for it", loud.length, 1)

// A club you follow always alerts, whatever the league setting says.
var mineScored = mlb.map(function(g) { return JSON.parse(JSON.stringify(g)) })
var own = mineScored.filter(function(g) { return g.state === "LIVE" && g.home.abbr === liveHome })[0]
own.home.score = own.home.score + 1
eq("your own club always alerts",
   M.diffGames(before, mineScored, { follows: ["mlb:" + liveHome], leagues: [] }).length, 1)

console.log("\n=== a league view is never an empty box ===")
var withGames = M.buildRows({ route: "league:mlb", games: mlb, follows: [], followedLeagues: [],
  now: now, standings: STANDINGS, standingsLeague: "mlb" })
check("games are listed", withGames.some(function(r) { return r.kind === "game" }))
check("standings are listed under them", withGames.some(function(r) { return r.kind === "standing" }))
var firstGame = withGames.findIndex(function(r) { return r.kind === "game" })
var firstStanding = withGames.findIndex(function(r) { return r.kind === "standing" })
check("games come first", firstGame < firstStanding, firstGame + " vs " + firstStanding)

// The NBA in August: no card at all. This was an empty view before.
var offSeason = M.buildRows({ route: "league:nba", games: [], follows: [], followedLeagues: [],
  now: now, standings: STANDINGS, standingsLeague: "nba" })
check("an off-season league still shows standings",
      offSeason.some(function(r) { return r.kind === "standing" }))
check("and says why there are no games",
      offSeason.some(function(r) { return r.kind === "note" && /No games today/.test(r.text) }))

var loading = M.buildRows({ route: "league:nba", games: [], follows: [], followedLeagues: [],
  now: now, standings: [], standingsLeague: "", leagueLoading: true })
check("mid-fetch says loading, not 'no games'",
      loading.some(function(r) { return r.kind === "note" && /Loading/.test(r.text) }))
// Standings for another league must never leak into this one.
var wrongLeague = M.buildRows({ route: "league:nhl", games: [], follows: [], followedLeagues: [],
  now: now, standings: STANDINGS, standingsLeague: "mlb" })
check("another league's table does not leak in",
      !wrongLeague.some(function(r) { return r.kind === "standing" }))

// The standalone route and the inline table must agree.
var standalone = M.buildRows({ route: "standings:mlb", games: [], follows: [], followedLeagues: [],
  now: now, standings: STANDINGS, standingsLeague: "mlb" })
eq("both paths build the same table",
   standalone.filter(function(r) { return r.kind === "standing" }).length,
   withGames.filter(function(r) { return r.kind === "standing" }).length)

console.log("\n=== search covers leagues, not only teams ===")
var TEAMS = [{ league: "eng.1", abbr: "ARS", name: "Arsenal", location: "London" },
             { league: "mlb", abbr: "BOS", name: "Boston Red Sox", location: "Boston" }]
function runSearch(q) {
  return M.buildRows({ route: "search", games: [], follows: ["mlb:BOS"], followedLeagues: ["eng.1"],
                       now: now, teams: TEAMS, filter: q })
}
var byLeagueName = runSearch("premier")
console.log("  \"premier\" ->", byLeagueName.filter(function(r) { return r.kind === "league" }).map(function(r) { return r.label }).join(", "))
check("a league name is findable", byLeagueName.some(function(r) { return r.kind === "league" && r.league === "eng.1" }))
check("and shows it is already followed", byLeagueName.filter(function(r) { return r.kind === "league" })[0].followed === true)

var byTeamName = runSearch("arsenal")
check("teams still match", byTeamName.some(function(r) { return r.kind === "team" && r.abbr === "ARS" }))

var bySport = runSearch("baseball")
console.log("  \"baseball\" ->", bySport.filter(function(r) { return r.kind === "league" }).map(function(r) { return r.label }).join(", "))
check("searching a sport finds its leagues", bySport.some(function(r) { return r.kind === "league" && r.league === "mlb" }))

var empty = M.buildRows({ route: "search", games: [], follows: [], followedLeagues: [], now: now, teams: TEAMS, filter: "" })
check("an empty query with nothing followed explains itself",
      empty.some(function(r) { return r.kind === "note" && /team and league/.test(r.text) }))
var listing = runSearch("")
check("an empty query lists followed teams", listing.some(function(r) { return r.kind === "team" }))
check("and followed leagues", listing.some(function(r) { return r.kind === "league" }))
check("nonsense matches nothing", runSearch("zzzzzz").some(function(r) { return r.kind === "note" }))

console.log("\n=== club colours have to be visible ===")
var PANEL = "#05182e"
eq("luminance of black", M.luminance("#000000"), 0)
eq("garbage has no luminance", M.luminance("nope"), null)
check("contrast is symmetric", M.contrastRatio("#ffffff", PANEL) === M.contrastRatio(PANEL, "#ffffff"))

// The Pirates' primary is literally #000000 on a near-black panel.
var pirates = { color: "#000000", altColor: "#fdb827" }
eq("a black primary falls back to the alternate", M.teamAccent(pirates, PANEL), "#fdb827")
var rays = { color: "#092c5c", altColor: "#8fbce6" }
eq("so does a very dark navy", M.teamAccent(rays, PANEL), "#8fbce6")
var reds = { color: "#c6011f", altColor: "#ffffff" }
eq("a visible primary is kept", M.teamAccent(reds, PANEL), "#c6011f")
eq("no colours at all yields none", M.teamAccent({ color: "", altColor: "" }, PANEL), "")
// Both unusable: return something rather than nothing, and let the caller lift it.
check("both dark still returns a colour",
      M.teamAccent({ color: "#33006f", altColor: "#000000" }, PANEL) !== "")

// Across a real slate, every club must end up with something that reads.
var invisible = []
mlb.forEach(function(g) {
  [g.home, g.away].forEach(function(t) {
    var picked = M.teamAccent(t, PANEL)
    if (picked === "" || M.contrastRatio(picked, PANEL) < 1.9) invisible.push(t.abbr + " " + picked)
  })
})
console.log("  clubs on today's slate with no readable colour:", invisible.length ? invisible.join(", ") : "none")
eq("every club gets a readable colour", invisible.length, 0)

console.log("\n=== event sports are not two-sided ===")
var EVENTS = { pga: "pga", ufc: "ufc", f1: "f1" }
Object.keys(EVENTS).forEach(function(slug) {
  var raw
  try { raw = fs.readFileSync("/tmp/sweepdata/" + slug + ".json", "utf8") } catch (e) { return }
  var games = P.espn.parseScoreboard(raw, slug, now).games
  if (games.length === 0) return
  var g = games[0]
  console.log("  " + slug.padEnd(4) + " " + (g.isEvent ? "event" : "TWO-SIDED") +
              "  bar: " + M.barTextFor(g, "full", now))
  check(slug + " is flagged as an event", g.isEvent === true)
  // The bug this guards: a two-team render of a field of entrants read "? @ ?".
  check(slug + " bar text names the event", M.barTextFor(g, "full", now).indexOf("?") < 0,
        M.barTextFor(g, "full", now))
  var rows = M.buildRows({ route: "", games: games, follows: [], followedLeagues: [slug], now: now })
  check(slug + " renders as an event row", rows.some(function(r) { return r.kind === "event" }))
  check(slug + " is counted as a fixture", rows.filter(M.isFixtureRow).length > 0)
})
// Team sports must be untouched by all of that.
check("team sports stay two-sided", mlb.every(function(g) { return g.isEvent === false }))
check("and still render as game rows",
      M.buildRows({ route: "", games: mlb, follows: [], followedLeagues: ["mlb"], now: now })
        .some(function(r) { return r.kind === "game" }))

console.log(failures === 0 ? "\nOK — all assertions passed" : "\n" + failures + " FAILURES")
process.exit(failures === 0 ? 0 : 1)
