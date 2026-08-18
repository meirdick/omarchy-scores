// Provider adapters. Every one of these turns some vendor's JSON into the
// normalized Game shape below, and nothing above this file ever sees vendor
// JSON again.
//
//   Game = {
//     id, league, sport, startUtc, state, rawStatus, delayed,
//     period, clock, home, away, situation, detailUrl, updatedAt
//   }
//   Team = { abbr, name, score, logo, color, record }
//
// state is "PRE" | "LIVE" | "FINAL" | "POSTPONED".
//
// rawStatus is the provider's own rendering ("Bot 7th", "Q3 4:22", "Final").
// It is used verbatim for LIVE and FINAL because every provider already gets
// the per-sport wording right and reimplementing it is a bug farm. It is NOT
// used for PRE: ESPN renders that as "8/17 - 8:40 PM EDT" for MLB but plain
// "Scheduled" for soccer, so the panel formats PRE from startUtc instead.

var Leagues = (typeof require !== "undefined") ? require("./Leagues.js") : null

// Set by Panel.qml/Service.qml under QML, where require() does not exist.
function useLeagues(mod) { Leagues = mod }

// ------------------------------------------------------------------ helpers

function toScore(value) {
  if (value === undefined || value === null || value === "") return null
  var n = parseInt(String(value), 10)
  return isFinite(n) ? n : null
}

function parseJson(text) {
  var raw = String(text || "").trim()
  if (raw === "") return null
  try { return JSON.parse(raw) } catch (e) { return null }
}

function emptyTeam() {
  return { abbr: "", name: "", score: null, logo: "", color: "", record: "" }
}

// A date as ESPN wants it in ?dates=, in the machine's own timezone. Using UTC
// here would show yesterday's card all evening in the Americas.
function espnDate(date) {
  var d = date || new Date()
  var month = d.getMonth() + 1
  var day = d.getDate()
  return String(d.getFullYear()) + (month < 10 ? "0" : "") + month + (day < 10 ? "0" : "") + day
}

function isoDate(date) {
  var d = date || new Date()
  var month = d.getMonth() + 1
  var day = d.getDate()
  return String(d.getFullYear()) + "-" + (month < 10 ? "0" : "") + month + "-" + (day < 10 ? "0" : "") + day
}

// ------------------------------------------------------------------- espn

var ESPN_HOST = "https://site.web.api.espn.com"
// site.api.espn.com serves the same payload but 403s any browser-shaped
// User-Agent — curl/* and python-requests/* get 200, Mozilla/* and Wget/* get
// 403. site.web.api.espn.com has no such gate, so it is the default and the
// fetcher must NOT set a User-Agent. If you are "fixing" this by pretending to
// be Chrome, that is the bug, not the cure.
var ESPN_ALT_HOST = "https://site.api.espn.com"
var ESPN_CORE_HOST = "https://sports.core.api.espn.com"

function espnStateOf(type) {
  var name = String(type && type.name || "")
  if (name === "STATUS_POSTPONED" || name === "STATUS_CANCELED" ||
      name === "STATUS_SUSPENDED" || name === "STATUS_RAIN_DELAY_STATUS") {
    // Suspended games keep a score worth showing, but they are not live and
    // must not hold the poller at its live interval.
    return "POSTPONED"
  }
  switch (String(type && type.state || "")) {
  case "pre":  return "PRE"
  case "in":   return "LIVE"
  case "post": return "FINAL"
  }
  return "PRE"
}

// Sport family, used only to pick a situation formatter.
function espnSportOf(path) {
  var head = String(path || "").split("/")[0]
  return head || "other"
}

function espnTeam(competitor) {
  if (!competitor) return emptyTeam()
  var team = competitor.team || {}
  var records = Array.isArray(competitor.records) ? competitor.records : []
  var record = ""
  for (var i = 0; i < records.length; i++) {
    if (String(records[i].type || "") === "total" || String(records[i].name || "") === "overall") {
      record = String(records[i].summary || "")
      break
    }
  }
  if (record === "" && records.length > 0) record = String(records[0].summary || "")

  var lines = []
  if (Array.isArray(competitor.linescores))
    for (var j = 0; j < competitor.linescores.length; j++)
      lines.push(toScore(competitor.linescores[j].value))

  return {
    abbr: String(team.abbreviation || team.shortDisplayName || ""),
    name: String(team.shortDisplayName || team.displayName || team.name || ""),
    fullName: String(team.displayName || ""),
    id: String(team.id || ""),
    score: toScore(competitor.score),
    // ESPN sends bare hex with no leading '#'.
    color: team.color ? "#" + String(team.color) : "",
    logo: String(team.logo || ""),
    record: record,
    lines: lines,
    winner: competitor.winner === true
  }
}

// Normalized situation. `kind` picks the formatter; every field beyond it is
// optional and the formatter must tolerate its absence.
function espnSituation(situation, sport) {
  if (!situation) return null
  var lastPlay = situation.lastPlay || null
  var out = {
    kind: sport === "baseball" ? "baseball" : (sport === "football" ? "football" : "generic"),
    lastPlayId: lastPlay ? String(lastPlay.id || "") : "",
    lastPlayText: lastPlay ? String(lastPlay.text || "") : ""
  }
  if (out.kind === "baseball") {
    out.balls = toScore(situation.balls)
    out.strikes = toScore(situation.strikes)
    out.outs = toScore(situation.outs)
    out.bases = [situation.onFirst === true, situation.onSecond === true, situation.onThird === true]
  } else if (out.kind === "football") {
    // Unverified against a live payload — no NFL game was in progress when
    // this was written. Every read is guarded so a missing field degrades to
    // no situation line rather than a broken one.
    out.downDistance = String(situation.downDistanceText || "")
    out.possession = String(situation.possession || "")
    out.redZone = situation.isRedZone === true
  }
  return out
}

function espnDetailUrl(event) {
  var links = Array.isArray(event && event.links) ? event.links : []
  for (var i = 0; i < links.length; i++) {
    var rel = Array.isArray(links[i].rel) ? links[i].rel : []
    if (rel.indexOf("summary") >= 0 && links[i].href) return String(links[i].href)
  }
  for (var j = 0; j < links.length; j++) if (links[j].href) return String(links[j].href)
  return ""
}

function espnGame(event, league, sport, nowMs) {
  if (!event) return null
  var competition = Array.isArray(event.competitions) ? event.competitions[0] : null
  if (!competition) return null
  var competitors = Array.isArray(competition.competitors) ? competition.competitors : []

  // Never index competitors positionally — the array is home-first for MLB and
  // makes no promise elsewhere.
  var home = emptyTeam(), away = emptyTeam()
  for (var i = 0; i < competitors.length; i++) {
    if (String(competitors[i].homeAway) === "home") home = espnTeam(competitors[i])
    else if (String(competitors[i].homeAway) === "away") away = espnTeam(competitors[i])
  }

  var status = event.status || {}
  var type = status.type || {}
  var startMs = Date.parse(String(event.date || ""))

  return {
    id: "espn:" + String(event.id || ""),
    eventId: String(event.id || ""),
    provider: "espn",
    league: league,
    sport: sport,
    name: String(event.shortName || event.name || ""),
    startUtc: isFinite(startMs) ? startMs : 0,
    state: espnStateOf(type),
    rawStatus: String(type.shortDetail || type.description || ""),
    statusDetail: String(type.detail || ""),
    delayed: String(type.name || "") === "STATUS_DELAYED",
    period: toScore(status.period),
    clock: status.displayClock ? String(status.displayClock) : "",
    home: home,
    away: away,
    situation: espnSituation(competition.situation, sport),
    venue: competition.venue && competition.venue.fullName ? String(competition.venue.fullName) : "",
    detailUrl: espnDetailUrl(event),
    updatedAt: nowMs || 0
  }
}

var espn = {
  name: "espn",

  scoreboardUrl: function(league, date, host) {
    var meta = Leagues && Leagues.resolve(league)
    if (!meta) return ""
    return (host || ESPN_HOST) + "/apis/site/v2/sports/" + meta.espn +
      "/scoreboard?dates=" + espnDate(date)
  },

  summaryUrl: function(league, eventId, host) {
    var meta = Leagues && Leagues.resolve(league)
    if (!meta) return ""
    return (host || ESPN_HOST) + "/apis/site/v2/sports/" + meta.espn +
      "/summary?event=" + encodeURIComponent(String(eventId))
  },

  // Standings live under apis/v2, not apis/site/v2, and only on the plain host.
  standingsUrl: function(league, host) {
    var meta = Leagues && Leagues.resolve(league)
    if (!meta) return ""
    return (host || ESPN_ALT_HOST) + "/apis/v2/sports/" + meta.espn + "/standings"
  },

  teamsUrl: function(league, host) {
    var meta = Leagues && Leagues.resolve(league)
    if (!meta) return ""
    return (host || ESPN_HOST) + "/apis/site/v2/sports/" + meta.espn + "/teams"
  },

  parseScoreboard: function(text, league, nowMs) {
    var data = parseJson(text)
    if (!data) return { ok: false, games: [], error: "unparseable response" }
    var meta = Leagues && Leagues.resolve(league)
    var sport = espnSportOf(meta ? meta.espn : "")
    var events = Array.isArray(data.events) ? data.events : []
    var games = []
    for (var i = 0; i < events.length; i++) {
      var game = espnGame(events[i], league, sport, nowMs)
      if (game) games.push(game)
    }
    return { ok: true, games: games, error: "" }
  },

  // Team list for the follow picker. Shape differs from the scoreboard: the
  // teams live at sports[0].leagues[0].teams[].team.
  parseTeams: function(text, league) {
    var data = parseJson(text)
    if (!data) return []
    var sports = Array.isArray(data.sports) ? data.sports : []
    var leagues = sports[0] && Array.isArray(sports[0].leagues) ? sports[0].leagues : []
    var entries = leagues[0] && Array.isArray(leagues[0].teams) ? leagues[0].teams : []
    var out = []
    for (var i = 0; i < entries.length; i++) {
      var team = entries[i].team || {}
      if (!team.abbreviation) continue
      out.push({
        league: league,
        abbr: String(team.abbreviation),
        name: String(team.displayName || team.shortDisplayName || ""),
        location: String(team.location || ""),
        color: team.color ? "#" + String(team.color) : "",
        logo: String(team.logos && team.logos[0] && team.logos[0].href || "")
      })
    }
    return out
  },

  // `stats` is a flat name/displayValue array. Look entries up by name; the
  // order is not stable and indexing it positionally silently mislabels
  // columns.
  parseStandings: function(text) {
    var data = parseJson(text)
    if (!data) return []
    var groups = []

    function statOf(stats, name) {
      if (!Array.isArray(stats)) return ""
      for (var i = 0; i < stats.length; i++)
        if (String(stats[i].name || "") === name)
          return String(stats[i].displayValue !== undefined ? stats[i].displayValue : stats[i].value)
      return ""
    }

    function walk(node) {
      if (!node) return
      if (node.standings && Array.isArray(node.standings.entries)) {
        var rows = []
        for (var i = 0; i < node.standings.entries.length; i++) {
          var entry = node.standings.entries[i]
          var team = entry.team || {}
          rows.push({
            abbr: String(team.abbreviation || ""),
            name: String(team.displayName || team.shortDisplayName || ""),
            logo: String(team.logos && team.logos[0] && team.logos[0].href || ""),
            wins: statOf(entry.stats, "wins"),
            losses: statOf(entry.stats, "losses"),
            ties: statOf(entry.stats, "ties"),
            points: statOf(entry.stats, "points"),
            winPercent: statOf(entry.stats, "winPercent"),
            gamesBehind: statOf(entry.stats, "gamesBehind"),
            streak: statOf(entry.stats, "streak")
          })
        }
        groups.push({ name: String(node.name || node.displayName || ""), rows: rows })
      }
      if (Array.isArray(node.children))
        for (var j = 0; j < node.children.length; j++) walk(node.children[j])
    }

    walk(data)
    return groups
  },

  // The summary payload reduced to what a dropdown can show. It is 600 KB for
  // NFL and near 1 MB for MLB, so it is fetched once when a game is opened and
  // never polled.
  //
  // The two sports disagree about where scoring lives and how a team is named:
  // football fills `scoringPlays[]` and identifies the team by abbreviation,
  // baseball has no `scoringPlays` key at all and instead flags entries inside
  // `plays[]`, identifying the team by numeric id. Both are normalized here so
  // the panel has one shape to render.
  parseSummary: function(text) {
    var data = parseJson(text)
    if (!data) return null

    // id -> abbreviation, for the payloads that reference teams by id.
    var byId = {}
    var header = data.header || {}
    var competitions = Array.isArray(header.competitions) ? header.competitions : []
    var competitors = competitions[0] && Array.isArray(competitions[0].competitors)
      ? competitions[0].competitors : []
    for (var c = 0; c < competitors.length; c++) {
      var team = competitors[c].team || {}
      if (team.id) byId[String(team.id)] = String(team.abbreviation || team.shortDisplayName || "")
    }

    function teamLabel(value) {
      var raw = String(value === undefined || value === null ? "" : value)
      if (raw === "") return ""
      return byId[raw] !== undefined ? byId[raw] : raw
    }

    var source = []
    if (Array.isArray(data.scoringPlays) && data.scoringPlays.length > 0) {
      source = data.scoringPlays
    } else if (Array.isArray(data.plays)) {
      for (var i = 0; i < data.plays.length; i++)
        if (data.plays[i] && data.plays[i].scoringPlay === true) source.push(data.plays[i])
    }

    var plays = []
    for (var j = 0; j < source.length; j++) {
      var play = source[j]
      var period = play.period || {}
      // football sends {team:{abbreviation:"CIN"}}; baseball sends {team:{id:"1"}}
      // with no abbreviation at all, so fall back to the id and let teamLabel
      // resolve it against the header.
      var teamRef = play.team
      if (teamRef && typeof teamRef === "object")
        teamRef = teamRef.abbreviation !== undefined && teamRef.abbreviation !== null
          ? teamRef.abbreviation : teamRef.id
      plays.push({
        text: String(play.text || "").trim(),
        teamAbbr: teamLabel(teamRef),
        clock: String(play.clock && play.clock.displayValue || ""),
        period: toScore(period.number),
        periodLabel: String(period.displayValue || period.type || ""),
        away: toScore(play.awayScore),
        home: toScore(play.homeScore)
      })
    }

    var leaders = []
    if (Array.isArray(data.leaders)) {
      for (var k = 0; k < data.leaders.length; k++) {
        var side = data.leaders[k]
        var categories = Array.isArray(side.leaders) ? side.leaders : []
        for (var m = 0; m < categories.length; m++) {
          var top = Array.isArray(categories[m].leaders) ? categories[m].leaders[0] : null
          if (!top) continue
          leaders.push({
            teamAbbr: String(side.team && side.team.abbreviation || ""),
            category: String(categories[m].displayName || categories[m].name || ""),
            athlete: String(top.athlete && top.athlete.shortName || ""),
            value: String(top.displayValue || "")
          })
        }
      }
    }

    return { scoringPlays: plays, leaders: leaders }
  }
}

// -------------------------------------------------------------- mlb statsapi

// MLBAM's terms (gdx.mlb.com/components/copyright.txt) permit "individual,
// non-commercial, non-bulk use", which is exactly this. It is the only source
// here with written permission for the use case, so it is the MLB fallback.
var MLB_HOST = "https://statsapi.mlb.com"

function mlbState(status) {
  var abstract = String(status && status.abstractGameState || "")
  var detailed = String(status && status.detailedState || "")
  if (/postponed|cancelled|canceled|suspended/i.test(detailed)) return "POSTPONED"
  if (abstract === "Live") return "LIVE"
  if (abstract === "Final") return "FINAL"
  return "PRE"
}

var mlb = {
  name: "mlb",

  scoreboardUrl: function(league, date) {
    if (league !== "mlb") return ""
    return MLB_HOST + "/api/v1/schedule?sportId=1&date=" + isoDate(date) +
      "&hydrate=linescore,team"
  },

  parseScoreboard: function(text, league, nowMs) {
    var data = parseJson(text)
    if (!data) return { ok: false, games: [], error: "unparseable response" }
    var dates = Array.isArray(data.dates) ? data.dates : []
    var games = []

    for (var d = 0; d < dates.length; d++) {
      var dayGames = Array.isArray(dates[d].games) ? dates[d].games : []
      for (var i = 0; i < dayGames.length; i++) {
        var game = dayGames[i]
        var teams = game.teams || {}
        var line = game.linescore || {}
        var startMs = Date.parse(String(game.gameDate || ""))

        function side(entry) {
          var team = entry && entry.team || {}
          return {
            abbr: String(team.abbreviation || ""),
            name: String(team.teamName || team.name || ""),
            fullName: String(team.name || ""),
            id: String(team.id || ""),
            score: toScore(entry && entry.score),
            color: "", logo: "",
            record: entry && entry.leagueRecord
              ? String(entry.leagueRecord.wins) + "-" + String(entry.leagueRecord.losses) : "",
            lines: [],
            winner: entry && entry.isWinner === true
          }
        }

        var state = mlbState(game.status)
        // statsapi splits the half-inning across two fields; ESPN's one-string
        // "Bot 7th" is the target wording, so assemble the same thing here.
        var status = state === "LIVE" && line.currentInningOrdinal
          ? (String(line.inningState || "").slice(0, 3) + " " + String(line.currentInningOrdinal))
          : String(game.status && game.status.detailedState || "")

        games.push({
          id: "mlb:" + String(game.gamePk || ""),
          eventId: String(game.gamePk || ""),
          provider: "mlb",
          league: "mlb",
          sport: "baseball",
          name: String(teams.away && teams.away.team && teams.away.team.abbreviation || "") + " @ " +
                String(teams.home && teams.home.team && teams.home.team.abbreviation || ""),
          startUtc: isFinite(startMs) ? startMs : 0,
          state: state,
          rawStatus: status,
          statusDetail: String(game.status && game.status.detailedState || ""),
          delayed: /delay/i.test(String(game.status && game.status.detailedState || "")),
          period: toScore(line.currentInning),
          clock: "",
          home: side(teams.home),
          away: side(teams.away),
          situation: state === "LIVE" ? {
            kind: "baseball",
            balls: toScore(line.balls), strikes: toScore(line.strikes), outs: toScore(line.outs),
            bases: [!!(line.offense && line.offense.first), !!(line.offense && line.offense.second),
                    !!(line.offense && line.offense.third)],
            lastPlayId: "", lastPlayText: ""
          } : null,
          venue: String(game.venue && game.venue.name || ""),
          detailUrl: "https://www.mlb.com/gameday/" + String(game.gamePk || ""),
          updatedAt: nowMs || 0
        })
      }
    }
    return { ok: true, games: games, error: "" }
  }
}

// ---------------------------------------------------------------- nhl api-web

// /v1/score/now answers 307, so the fetcher must follow redirects. Requesting
// the dated form directly avoids relying on that.
var NHL_HOST = "https://api-web.nhle.com"

function nhlState(gameState) {
  switch (String(gameState || "")) {
  case "LIVE": case "CRIT": return "LIVE"
  case "FINAL": case "OFF": return "FINAL"
  case "PPD": case "CNCL": case "SUSP": return "POSTPONED"
  }
  return "PRE"
}

var nhl = {
  name: "nhl",

  scoreboardUrl: function(league, date) {
    if (league !== "nhl") return ""
    return NHL_HOST + "/v1/score/" + isoDate(date)
  },

  parseScoreboard: function(text, league, nowMs) {
    var data = parseJson(text)
    if (!data) return { ok: false, games: [], error: "unparseable response" }
    var entries = Array.isArray(data.games) ? data.games : []
    var games = []

    function side(entry) {
      if (!entry) return emptyTeam()
      return {
        abbr: String(entry.abbrev || ""),
        name: String(entry.commonName && entry.commonName.default || entry.name && entry.name.default || ""),
        fullName: String(entry.placeName && entry.placeName.default || ""),
        id: String(entry.id || ""),
        score: toScore(entry.score),
        color: "",
        logo: String(entry.logo || ""),
        record: "", lines: [], winner: false
      }
    }

    for (var i = 0; i < entries.length; i++) {
      var game = entries[i]
      var startMs = Date.parse(String(game.startTimeUTC || ""))
      var state = nhlState(game.gameState)
      var period = toScore(game.periodDescriptor && game.periodDescriptor.number)
      var clock = String(game.clock && game.clock.timeRemaining || "")

      games.push({
        id: "nhl:" + String(game.id || ""),
        eventId: String(game.id || ""),
        provider: "nhl",
        league: "nhl",
        sport: "hockey",
        name: String(game.awayTeam && game.awayTeam.abbrev || "") + " @ " +
              String(game.homeTeam && game.homeTeam.abbrev || ""),
        startUtc: isFinite(startMs) ? startMs : 0,
        state: state,
        rawStatus: state === "LIVE"
          ? ("P" + String(period || "") + (clock ? " " + clock : ""))
          : (state === "FINAL" ? "Final" : ""),
        statusDetail: String(game.gameState || ""),
        delayed: false,
        period: period,
        clock: clock,
        home: side(game.homeTeam),
        away: side(game.awayTeam),
        situation: null,
        venue: String(game.venue && game.venue.default || ""),
        detailUrl: game.gameCenterLink ? "https://www.nhl.com" + String(game.gameCenterLink) : "",
        updatedAt: nowMs || 0
      })
    }
    return { ok: true, games: games, error: "" }
  }
}

// ------------------------------------------------------------------ registry

var REGISTRY = { espn: espn, mlb: mlb, nhl: nhl }

function get(name) { return REGISTRY[String(name)] || null }

if (typeof module !== "undefined") {
  module.exports = {
    espn: espn, mlb: mlb, nhl: nhl,
    get: get, useLeagues: useLeagues,
    espnDate: espnDate, isoDate: isoDate, toScore: toScore,
    ESPN_HOST: ESPN_HOST, ESPN_ALT_HOST: ESPN_ALT_HOST, ESPN_CORE_HOST: ESPN_CORE_HOST
  }
}
