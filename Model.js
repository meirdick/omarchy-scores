// Pure presentation logic: formatting, sorting, row building, and the diff
// that notifications are derived from. No QML state, no network, no I/O — so
// all of it runs under plain node in test/.

var Leagues = (typeof require !== "undefined") ? require("./Leagues.js") : null
function useLeagues(mod) { Leagues = mod }

var MINUTE = 60000
var HOUR = 3600000
var DAY = 86400000

// ------------------------------------------------------------------ follows

// A follow is "<league>:<ABBR>", e.g. "mlb:BOS". Case is normalized on the
// abbreviation so a hand-edited shell.json entry of "mlb:bos" still matches.
function followKey(league, abbr) {
  return String(league || "") + ":" + String(abbr || "").toUpperCase()
}

function normalizeFollows(value) {
  var list = []
  if (Array.isArray(value)) list = value
  else if (typeof value === "string" && value.trim() !== "") list = value.split(/[\s,]+/)
  var seen = {}, out = []
  for (var i = 0; i < list.length; i++) {
    var entry = String(list[i] || "").trim()
    if (entry === "" || entry.indexOf(":") < 0) continue
    var parts = entry.split(":")
    var key = followKey(parts[0], parts[1])
    if (!seen[key]) { seen[key] = true; out.push(key) }
  }
  return out
}

function followSet(value) {
  var set = {}
  var list = normalizeFollows(value)
  for (var i = 0; i < list.length; i++) set[list[i]] = true
  return set
}

function isFollowedTeam(set, league, abbr) {
  return set[followKey(league, abbr)] === true
}

function isFollowedGame(set, game) {
  if (!game) return false
  return isFollowedTeam(set, game.league, game.home.abbr) ||
         isFollowedTeam(set, game.league, game.away.abbr)
}

// Which side of the game the user cares about, for "your team scored" wording.
function followedSide(set, game) {
  if (!game) return null
  if (isFollowedTeam(set, game.league, game.home.abbr)) return "home"
  if (isFollowedTeam(set, game.league, game.away.abbr)) return "away"
  return null
}

function toggleFollow(value, league, abbr) {
  var key = followKey(league, abbr)
  var list = normalizeFollows(value)
  var index = list.indexOf(key)
  if (index >= 0) list.splice(index, 1)
  else list.push(key)
  return list
}

// ----------------------------------------------------------------- formatting

function pad2(n) { return (n < 10 ? "0" : "") + n }

// Wall-clock start time in the machine's timezone. formatTime is injected
// because QML has Qt.formatTime and node does not; both callers pass their own.
function clockTime(ms, formatTime) {
  if (!ms) return ""
  var date = new Date(ms)
  if (typeof formatTime === "function") return formatTime(date)
  var hours = date.getHours()
  var suffix = hours >= 12 ? "PM" : "AM"
  var display = hours % 12
  if (display === 0) display = 12
  return display + ":" + pad2(date.getMinutes()) + " " + suffix
}

function sameDay(aMs, bMs) {
  var a = new Date(aMs), b = new Date(bMs)
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}

// "2h 14m", "14m", "now". Deliberately not seconds — a bar that ticks every
// second is a distraction, and the poll interval is coarser than that anyway.
function countdown(ms) {
  if (ms <= 0) return "now"
  if (ms < MINUTE) return "now"
  var minutes = Math.floor(ms / MINUTE)
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  if (hours < 24) return rest > 0 ? (hours + "h " + rest + "m") : (hours + "h")
  var days = Math.floor(hours / 24)
  return days + "d " + (hours % 24) + "h"
}

// The status string shown next to a score.
//
// LIVE and FINAL use the provider's own wording verbatim — every provider
// already renders "Bot 7th" / "Q3 4:22" / "45'+2" correctly per sport, and
// reimplementing that is a bug farm. PRE is the exception: ESPN renders it as
// "8/17 - 8:40 PM EDT" for MLB but bare "Scheduled" for soccer, so it is
// formatted here instead.
function statusLabel(game, nowMs, formatTime) {
  if (!game) return ""
  if (game.state === "PRE") {
    if (!game.startUtc) return game.rawStatus || "Scheduled"
    var delta = game.startUtc - nowMs
    if (delta > 0 && delta < 12 * HOUR) return clockTime(game.startUtc, formatTime) + " · in " + countdown(delta)
    return clockTime(game.startUtc, formatTime)
  }
  if (game.state === "POSTPONED") return game.rawStatus || game.statusDetail || "Postponed"
  return game.rawStatus || (game.state === "FINAL" ? "Final" : "")
}

// The sport-specific in-game line. Returns "" when there is nothing to say,
// which is the normal case for most sports and every non-live game.
function situationLine(game) {
  var situation = game && game.situation
  if (!situation || game.state !== "LIVE") return ""

  if (situation.kind === "baseball") {
    var parts = []
    if (situation.balls !== null && situation.strikes !== null)
      parts.push(situation.balls + "-" + situation.strikes)
    if (situation.outs !== null) parts.push(situation.outs + (situation.outs === 1 ? " out" : " outs"))
    var bases = basesLabel(situation.bases)
    if (bases !== "") parts.push(bases)
    return parts.join(", ")
  }

  if (situation.kind === "football") {
    var line = String(situation.downDistance || "")
    if (situation.possession) line = line === "" ? situation.possession : (line + " · " + situation.possession)
    if (situation.redZone) line = line === "" ? "red zone" : (line + " · red zone")
    return line
  }

  return String(situation.lastPlayText || "")
}

function basesLabel(bases) {
  if (!Array.isArray(bases)) return ""
  var on = []
  if (bases[0]) on.push("1st")
  if (bases[1]) on.push("2nd")
  if (bases[2]) on.push("3rd")
  if (on.length === 0) return "bases empty"
  if (on.length === 3) return "bases loaded"
  return on.join(" & ")
}

// --------------------------------------------------------------- bar rendering

// The bar is a Live Activity with a mouse: two abbreviations, two scores, one
// status token. Anything that does not fit that shape belongs in the panel.
function barTextFor(game, format, nowMs, formatTime) {
  if (!game) return ""
  var away = game.away, home = game.home

  if (game.state === "PRE") {
    var when = game.startUtc ? countdown(game.startUtc - nowMs) : ""
    var matchup = away.abbr + " @ " + home.abbr
    if (format === "compact") return matchup
    return when ? (matchup + " · " + when) : matchup
  }

  var score = away.abbr + " " + fmtScore(away.score) + " · " + home.abbr + " " + fmtScore(home.score)
  if (format === "compact") return away.abbr + " " + fmtScore(away.score) + "-" + fmtScore(home.score) + " " + home.abbr
  var status = statusLabel(game, nowMs, formatTime)
  return status ? (score + "  " + status) : score
}

function fmtScore(value) { return (value === null || value === undefined) ? "0" : String(value) }

// What the bar should show right now, given every game the poller holds.
// Returns a descriptor rather than a string so the widget can style by state
// and know how many live games it is rotating through.
function barState(games, follows, nowMs, options) {
  var opts = options || {}
  var set = followSet(follows)
  var followed = []
  for (var i = 0; i < games.length; i++) if (isFollowedGame(set, games[i])) followed.push(games[i])

  var live = followed.filter(function(g) { return g.state === "LIVE" })
  if (live.length > 0) {
    live.sort(function(a, b) { return a.startUtc - b.startUtc })
    var index = live.length > 0 ? (Math.max(0, opts.rotateIndex || 0) % live.length) : 0
    return {
      mode: "live", game: live[index], games: live,
      index: index, count: live.length,
      text: barTextFor(live[index], opts.format, nowMs, opts.formatTime)
    }
  }

  // Nothing live: the next game the user cares about, so the widget is not
  // blank for the 80% of the week when nobody is playing.
  var upcoming = followed.filter(function(g) { return g.state === "PRE" && g.startUtc > nowMs })
  upcoming.sort(function(a, b) { return a.startUtc - b.startUtc })
  if (upcoming.length > 0)
    return {
      mode: "upcoming", game: upcoming[0], games: upcoming, index: 0, count: upcoming.length,
      text: barTextFor(upcoming[0], opts.format, nowMs, opts.formatTime)
    }

  // A final that is still worth reading — the score you missed while away.
  var finals = followed.filter(function(g) {
    return g.state === "FINAL" && (nowMs - g.startUtc) < (opts.finalWindowHours || 8) * HOUR
  })
  finals.sort(function(a, b) { return b.startUtc - a.startUtc })
  if (finals.length > 0)
    return {
      mode: "final", game: finals[0], games: finals, index: 0, count: finals.length,
      text: barTextFor(finals[0], opts.format, nowMs, opts.formatTime)
    }

  return { mode: "idle", game: null, games: [], index: 0, count: 0, text: "" }
}

// ------------------------------------------------------------------ sorting

var STATE_ORDER = { LIVE: 0, PRE: 1, POSTPONED: 2, FINAL: 3 }

function compareGames(a, b) {
  var byState = (STATE_ORDER[a.state] || 9) - (STATE_ORDER[b.state] || 9)
  if (byState !== 0) return byState
  if (a.state === "FINAL") return b.startUtc - a.startUtc
  return a.startUtc - b.startUtc
}

function sortGames(games) {
  return games.slice().sort(compareGames)
}

// ----------------------------------------------------------------- diffing

// Notification events, derived only from the normalized model. Nothing here
// knows which provider produced the games, so a provider swap cannot change
// which alerts fire.
//
// `previous` is a map of game id -> game from the last poll. A missing entry
// means the game was not seen before, which on the first poll after startup is
// every in-progress game — hence `suppress`, which the caller sets for that
// one pass so a shell restart does not fire a burst of stale alerts.
function diffGames(previous, current, options) {
  var opts = options || {}
  if (opts.suppress) return []
  var set = followSet(opts.follows)
  var events = []

  for (var i = 0; i < current.length; i++) {
    var game = current[i]
    if (opts.followedOnly !== false && !isFollowedGame(set, game)) continue
    var before = previous ? previous[game.id] : null
    if (!before) continue

    if (before.state === "PRE" && game.state === "LIVE")
      events.push({ type: "start", game: game, side: followedSide(set, game) })

    var homeDelta = scoreDelta(before.home.score, game.home.score)
    var awayDelta = scoreDelta(before.away.score, game.away.score)
    if ((homeDelta > 0 || awayDelta > 0) && game.state === "LIVE") {
      events.push({
        type: "score", game: game, side: followedSide(set, game),
        scoringTeam: homeDelta > awayDelta ? game.home : game.away,
        homeDelta: homeDelta, awayDelta: awayDelta
      })
    }

    if (before.state !== "FINAL" && game.state === "FINAL")
      events.push({ type: "final", game: game, side: followedSide(set, game) })

    if (isCloseGame(game, opts) && !isCloseGame(before, opts))
      events.push({ type: "close", game: game, side: followedSide(set, game) })
  }
  return events
}

function scoreDelta(before, after) {
  if (before === null || before === undefined || after === null || after === undefined) return 0
  var delta = after - before
  return delta > 0 ? delta : 0
}

// "Close" means late and within a margin. `finalPeriod` differs per sport, so
// it is configured rather than guessed; a sport with no configured period only
// qualifies on the margin plus a live clock, which is the conservative read.
function isCloseGame(game, options) {
  if (!game || game.state !== "LIVE") return false
  var opts = options || {}
  var margin = opts.closeMargin === undefined ? 1 : opts.closeMargin
  if (game.home.score === null || game.away.score === null) return false
  if (Math.abs(game.home.score - game.away.score) > margin) return false

  var finalPeriod = closePeriodFor(game.sport, opts)
  if (finalPeriod > 0 && (game.period || 0) < finalPeriod) return false

  if (game.clock) {
    var seconds = clockSeconds(game.clock)
    if (seconds !== null && seconds > (opts.closeClockSec === undefined ? 300 : opts.closeClockSec)) return false
  }
  return true
}

function closePeriodFor(sport, opts) {
  var overrides = (opts && opts.closePeriods) || {}
  if (overrides[sport] !== undefined) return overrides[sport]
  switch (sport) {
  case "baseball":   return 8   // 8th inning or later
  case "football":   return 4
  case "basketball": return 4
  case "hockey":     return 3
  case "soccer":     return 2   // second half
  }
  return 0
}

function clockSeconds(clock) {
  var match = String(clock || "").match(/^(\d+):(\d{2})$/)
  if (!match) return null
  return parseInt(match[1], 10) * 60 + parseInt(match[2], 10)
}

// Notification text. Kept next to the diff so the wording and the trigger
// cannot drift apart.
function notificationFor(event, nowMs, formatTime) {
  var game = event.game
  var line = game.away.abbr + " " + fmtScore(game.away.score) + " · " +
             game.home.abbr + " " + fmtScore(game.home.score)
  var league = Leagues ? Leagues.displayName(game.league) : game.league

  switch (event.type) {
  case "start":
    return { title: league + " · " + game.away.abbr + " @ " + game.home.abbr, body: "Under way" }
  case "score":
    return {
      title: event.scoringTeam.abbr + " score — " + line,
      body: [statusLabel(game, nowMs, formatTime), situationLine(game)].filter(nonEmpty).join("  ·  ")
    }
  case "final":
    return { title: "Final · " + line, body: league + (game.venue ? " · " + game.venue : "") }
  case "close":
    return {
      title: "Close game · " + line,
      body: statusLabel(game, nowMs, formatTime)
    }
  }
  return { title: line, body: "" }
}

function nonEmpty(value) { return String(value || "") !== "" }

// ------------------------------------------------------------- poll pacing

// Adaptive polling. This is a feature, not plumbing: it is the difference
// between a widget that costs nothing and one that hammers a free endpoint all
// week for games nobody is watching.
function pollIntervalSec(games, follows, nowMs, options) {
  var opts = options || {}
  var live = Math.max(10, opts.livePollSec || 25)
  var idle = Math.max(60, opts.idlePollSec || 900)
  if (opts.panelOpen) return live

  var set = followSet(follows)
  var anyLive = false, soonest = null
  for (var i = 0; i < games.length; i++) {
    var game = games[i]
    var followed = isFollowedGame(set, game)
    if (game.state === "LIVE" && (followed || opts.watchAll)) anyLive = true
    if (game.state === "PRE" && followed && game.startUtc > nowMs)
      if (soonest === null || game.startUtc < soonest) soonest = game.startUtc
  }
  if (anyLive) return live
  if (soonest !== null && (soonest - nowMs) < HOUR) return 300
  if (soonest !== null && (soonest - nowMs) < 6 * HOUR) return Math.min(idle, 900)
  return Math.max(idle, 3600)
}

// ------------------------------------------------------------- row building

// One flat list of rows over one ListView. The panel body is heterogeneous but
// every row is a row, so cursor movement never has to know which section it is
// in. `selectable: false` marks headers and notes.
function section(title, meta) {
  return { kind: "section", key: "section:" + title, selectable: false, title: title, meta: meta || "" }
}

function note(text, key) {
  return { kind: "note", key: "note:" + (key || text), selectable: false, text: text }
}

function gameRow(game, set, nowMs, formatTime) {
  return {
    kind: "game", key: game.id, selectable: true, game: game,
    followed: isFollowedGame(set, game),
    status: statusLabel(game, nowMs, formatTime),
    situation: situationLine(game),
    league: game.league
  }
}

// Tag each row with whether the next row is of the same kind. A delegate
// cannot see its neighbours, and a divider under the last game of a section
// would draw a line right above the next heading.
function markGroups(rows) {
  for (var i = 0; i < rows.length; i++) {
    var next = rows[i + 1]
    rows[i].lastInGroup = !next || next.kind !== rows[i].kind
  }
  return rows
}

function buildRows(state) {
  var route = String(state.route || "")
  var nowMs = state.now || 0
  var set = followSet(state.follows)
  var formatTime = state.formatTime
  var filter = String(state.filter || "").trim().toLowerCase()
  var games = Array.isArray(state.games) ? state.games : []

  if (route.indexOf("game:") === 0) return markGroups(gameDetailRows(state, set, nowMs, formatTime))
  if (route.indexOf("standings:") === 0) return markGroups(standingsRows(state))
  if (route.indexOf("league:") === 0) return markGroups(leagueRows(state, set, nowMs, formatTime))
  if (route === "leagues") return markGroups(leagueListRows(state))
  if (route === "search") return markGroups(searchRows(state, set))

  return markGroups(todayRows(state, set, nowMs, formatTime, filter, games))
}

function matchesFilter(game, filter) {
  if (filter === "") return true
  var haystack = [game.home.abbr, game.away.abbr, game.home.name, game.away.name,
                  game.home.fullName, game.away.fullName, game.league].join(" ").toLowerCase()
  return haystack.indexOf(filter) >= 0
}

function todayRows(state, set, nowMs, formatTime, filter, games) {
  var rows = []
  var visible = games.filter(function(g) { return matchesFilter(g, filter) })
  var followed = visible.filter(function(g) { return isFollowedGame(set, g) })
  var others = visible.filter(function(g) { return !isFollowedGame(set, g) })

  var followedLive = sortGames(followed.filter(function(g) { return g.state === "LIVE" }))
  var followedRest = sortGames(followed.filter(function(g) { return g.state !== "LIVE" }))
  var othersLive = sortGames(others.filter(function(g) { return g.state === "LIVE" }))
  var othersRest = sortGames(others.filter(function(g) { return g.state !== "LIVE" }))

  if (followedLive.length > 0) {
    rows.push(section("Live", String(followedLive.length)))
    for (var i = 0; i < followedLive.length; i++) rows.push(gameRow(followedLive[i], set, nowMs, formatTime))
  }
  if (followedRest.length > 0) {
    rows.push(section("Your teams", String(followedRest.length)))
    for (var j = 0; j < followedRest.length; j++) rows.push(gameRow(followedRest[j], set, nowMs, formatTime))
  }
  if (othersLive.length > 0) {
    rows.push(section("Live elsewhere", String(othersLive.length)))
    for (var k = 0; k < othersLive.length; k++) rows.push(gameRow(othersLive[k], set, nowMs, formatTime))
  }
  if (state.showAll !== false && othersRest.length > 0) {
    rows.push(section("Also today", String(othersRest.length)))
    for (var m = 0; m < othersRest.length; m++) rows.push(gameRow(othersRest[m], set, nowMs, formatTime))
  }

  if (rows.length === 0) {
    if (state.loading) rows.push(note("Loading…", "loading"))
    else if (filter !== "") rows.push(note("Nothing matches “" + state.filter + "”", "nomatch"))
    else if (normalizeFollows(state.follows).length === 0)
      rows.push(note("No teams followed yet — press / to search, f to follow", "nofollows"))
    else rows.push(note("No games scheduled", "nogames"))
  }

  rows.push(section("Browse", ""))
  rows.push({ kind: "action", key: "action:leagues", selectable: true, action: "leagues", label: "All leagues", hint: "" })
  return rows
}

function leagueRows(state, set, nowMs, formatTime) {
  var slug = String(state.route).slice("league:".length)
  var rows = []
  var games = sortGames((state.games || []).filter(function(g) { return g.league === slug }))
  if (games.length === 0) rows.push(note(state.loading ? "Loading…" : "No games scheduled", "empty"))
  for (var i = 0; i < games.length; i++) rows.push(gameRow(games[i], set, nowMs, formatTime))
  rows.push({ kind: "action", key: "action:standings", selectable: true, action: "standings:" + slug,
              label: "Standings", hint: "" })
  return rows
}

function leagueListRows(state) {
  var rows = []
  var list = Leagues ? Leagues.browseList() : []
  var lastGroup = ""
  var counts = state.leagueCounts || {}
  for (var i = 0; i < list.length; i++) {
    var league = list[i]
    if (league.group !== lastGroup) { rows.push(section(league.group, "")); lastGroup = league.group }
    rows.push({
      kind: "league", key: "league:" + league.id, selectable: true,
      league: league.id, label: league.name,
      hint: counts[league.id] ? (counts[league.id] + " today") : ""
    })
  }
  if (rows.length === 0) rows.push(note("No leagues", "noleagues"))
  return rows
}

function standingsRows(state) {
  var slug = String(state.route).slice("standings:".length)
  var rows = []
  var groups = state.standings || []
  if (groups.length === 0) { rows.push(note(state.loading ? "Loading…" : "No standings available", "nostand")); return rows }
  for (var i = 0; i < groups.length; i++) {
    if (groups[i].name) rows.push(section(groups[i].name, ""))
    for (var j = 0; j < groups[i].rows.length; j++) {
      var entry = groups[i].rows[j]
      rows.push({
        kind: "standing", key: "standing:" + slug + ":" + entry.abbr + ":" + j, selectable: true,
        league: slug, entry: entry, rank: j + 1,
        record: recordLabel(entry)
      })
    }
  }
  return rows
}

// "74-49-0" is not a baseball record. Ties only earn a column when a team has
// actually drawn something.
function recordLabel(entry) {
  if (String(entry.wins || "") === "") return String(entry.points || "")
  var record = entry.wins + "-" + entry.losses
  var ties = String(entry.ties || "")
  if (ties !== "" && ties !== "0") record += "-" + ties
  return record
}

function gameDetailRows(state, set, nowMs, formatTime) {
  var id = String(state.route).slice("game:".length)
  var game = null
  var games = state.games || []
  for (var i = 0; i < games.length; i++) if (games[i].id === id) game = games[i]
  if (!game) return [note("Game no longer on the card", "gone")]

  var rows = [gameRow(game, set, nowMs, formatTime)]

  if (game.home.lines.length > 0 || game.away.lines.length > 0)
    rows.push({ kind: "linescore", key: "linescore:" + game.id, selectable: false, game: game })

  var summary = state.summary || null
  if (state.loading && !summary) rows.push(note("Loading detail…", "loadingdetail"))

  if (summary && summary.scoringPlays && summary.scoringPlays.length > 0) {
    rows.push(section("Scoring", ""))
    // Newest first — the thing you opened the panel to see is the last play.
    var plays = summary.scoringPlays.slice().reverse()
    var limit = state.playLimit || 12
    for (var j = 0; j < plays.length && j < limit; j++)
      rows.push({ kind: "play", key: "play:" + j, selectable: false, play: plays[j] })
    if (plays.length > limit) rows.push(note(plays.length - limit + " earlier scoring plays not shown", "playtrunc"))
  }

  if (summary && summary.leaders && summary.leaders.length > 0) {
    rows.push(section("Leaders", ""))
    for (var k = 0; k < summary.leaders.length && k < 6; k++)
      rows.push({ kind: "leader", key: "leader:" + k, selectable: false, leader: summary.leaders[k] })
  }

  rows.push({ kind: "action", key: "action:open", selectable: true, action: "open",
              label: "Open on the web", hint: game.detailUrl })
  return rows
}

function searchRows(state, set) {
  var filter = String(state.filter || "").trim().toLowerCase()
  // No heading: the hero already says "Follow a team" and repeats the hint.
  var rows = []
  var teams = state.teams || []

  var matches = []
  if (filter !== "") {
    for (var i = 0; i < teams.length && matches.length < 60; i++) {
      var team = teams[i]
      var haystack = (team.abbr + " " + team.name + " " + team.location + " " + team.league).toLowerCase()
      if (haystack.indexOf(filter) >= 0) matches.push(team)
    }
  }

  // With no query, show what is already followed so unfollowing is reachable
  // without having to remember and retype the team's name.
  if (filter === "") {
    var followed = normalizeFollows(state.follows)
    if (followed.length === 0) rows.push(note("Type to search every team in every league", "nofollow"))
    else rows.push(section("Following", String(followed.length)))
    for (var j = 0; j < followed.length; j++) {
      var parts = followed[j].split(":")
      matches.push({ league: parts[0], abbr: parts[1], name: teamNameFor(teams, parts[0], parts[1]), location: "" })
    }
  }

  if (filter !== "" && matches.length === 0)
    rows.push(note(state.teamsLoading ? "Loading teams…" : "No team matches “" + state.filter + "”", "noteam"))

  for (var k = 0; k < matches.length; k++) {
    var entry = matches[k]
    rows.push({
      kind: "team", key: "team:" + entry.league + ":" + entry.abbr, selectable: true,
      team: entry, league: entry.league, abbr: entry.abbr,
      label: entry.name || entry.abbr,
      hint: Leagues ? Leagues.displayName(entry.league) : entry.league,
      followed: isFollowedTeam(set, entry.league, entry.abbr)
    })
  }
  return rows
}

function teamNameFor(teams, league, abbr) {
  for (var i = 0; i < teams.length; i++)
    if (teams[i].league === league && String(teams[i].abbr).toUpperCase() === String(abbr).toUpperCase())
      return teams[i].name
  return abbr
}

// Index of the first selectable row, so a route change never lands the cursor
// on a header.
function firstSelectable(rows) {
  for (var i = 0; i < rows.length; i++) if (rows[i].selectable !== false) return i
  return 0
}

function relativeTime(ms, nowMs) {
  if (!ms) return ""
  var delta = Math.max(0, nowMs - ms)
  if (delta < MINUTE) return "just now"
  if (delta < HOUR) return Math.floor(delta / MINUTE) + "m ago"
  if (delta < DAY) return Math.floor(delta / HOUR) + "h ago"
  return Math.floor(delta / DAY) + "d ago"
}

// ------------------------------------------------------------- emphasis

// Which side is ahead. "" means level, which is a real state and not the same
// as "no data" — the panel dims neither team when it is a tie.
function leaderSide(game) {
  if (!game) return ""
  var home = game.home.score, away = game.away.score
  if (home === null || away === null) return ""
  if (home > away) return "home"
  if (away > home) return "away"
  return ""
}

// Only a finished game has a winner. A team leading in the 3rd has not won
// anything, so live games get emphasis without the finality of a win mark.
function winnerSide(game) {
  if (!game || game.state !== "FINAL") return ""
  if (game.home.winner) return "home"
  if (game.away.winner) return "away"
  return leaderSide(game)
}

// One token per lifecycle state, so every surface signals the same three
// things the same way: what has not happened, what is happening, what is done.
function stateToken(game) {
  if (!game) return "none"
  if (game.state === "LIVE") return game.delayed ? "delayed" : "live"
  if (game.state === "FINAL") return "final"
  if (game.state === "POSTPONED") return "off"
  return "upcoming"
}

// Identity of the most recent thing that happened, for change detection in the
// view. When this string changes on a live game, something happened in it.
function activityKey(game) {
  if (!game) return ""
  var play = game.situation ? String(game.situation.lastPlayId || game.situation.lastPlayText || "") : ""
  return game.state + "|" + fmtScore(game.home.score) + "-" + fmtScore(game.away.score) +
         "|" + String(game.rawStatus || "") + "|" + play
}

// How far through the game we are, 0..1, for a progress indicator. Coarse by
// design: it reads "early / middle / nearly over", not a precise clock.
function progressFraction(game) {
  if (!game || game.state !== "LIVE") return game && game.state === "FINAL" ? 1 : 0
  var total = regulationPeriods(game.sport)
  if (total <= 0) return 0
  var period = game.period || 0
  if (period <= 0) return 0
  return Math.max(0, Math.min(1, period / total))
}

function regulationPeriods(sport) {
  switch (sport) {
  case "baseball":   return 9
  case "football":   return 4
  case "basketball": return 4
  case "hockey":     return 3
  case "soccer":     return 2
  }
  return 0
}

if (typeof module !== "undefined") {
  module.exports = {
    useLeagues: useLeagues,
    followKey: followKey, normalizeFollows: normalizeFollows, followSet: followSet,
    isFollowedTeam: isFollowedTeam, isFollowedGame: isFollowedGame,
    followedSide: followedSide, toggleFollow: toggleFollow,
    clockTime: clockTime, sameDay: sameDay, countdown: countdown,
    statusLabel: statusLabel, situationLine: situationLine, basesLabel: basesLabel,
    barTextFor: barTextFor, barState: barState, fmtScore: fmtScore,
    sortGames: sortGames, compareGames: compareGames,
    diffGames: diffGames, isCloseGame: isCloseGame, notificationFor: notificationFor,
    pollIntervalSec: pollIntervalSec,
    buildRows: buildRows, firstSelectable: firstSelectable, relativeTime: relativeTime,
    matchesFilter: matchesFilter, markGroups: markGroups,
    leaderSide: leaderSide, winnerSide: winnerSide, stateToken: stateToken,
    activityKey: activityKey, progressFraction: progressFraction,
    regulationPeriods: regulationPeriods
  }
}
