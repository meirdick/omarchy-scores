// Canonical league slugs and their per-provider addresses.
//
// The rest of the plugin only ever says "mlb" or "eng.1". Which path that
// turns into on some vendor's host is this file's problem and nobody else's;
// a provider slug that escapes this module is a bug.

// group is the heading the league sorts under in the panel's league list.
var CATALOG = {
  // ---- North American majors
  "nfl":   { name: "NFL",           group: "Football",   espn: "football/nfl" , logo: "https://a.espncdn.com/i/teamlogos/leagues/500/nfl.png" },
  "ncaaf": { name: "NCAA Football", group: "Football",   espn: "football/college-football" },
  "nba":   { name: "NBA",           group: "Basketball", espn: "basketball/nba" , logo: "https://a.espncdn.com/i/teamlogos/leagues/500/nba.png" },
  "wnba":  { name: "WNBA",          group: "Basketball", espn: "basketball/wnba" , logo: "https://a.espncdn.com/i/teamlogos/leagues/500/wnba.png" },
  "ncaam": { name: "NCAA Men's",    group: "Basketball", espn: "basketball/mens-college-basketball" },
  "ncaaw": { name: "NCAA Women's",  group: "Basketball", espn: "basketball/womens-college-basketball" },
  "mlb":   { name: "MLB",           group: "Baseball",   espn: "baseball/mlb", statsapi: 1 , logo: "https://a.espncdn.com/i/teamlogos/leagues/500/mlb.png" },
  "ncaab": { name: "NCAA Baseball", group: "Baseball",   espn: "baseball/college-baseball" },
  "nhl":   { name: "NHL",           group: "Hockey",     espn: "hockey/nhl", nhlweb: true , logo: "https://a.espncdn.com/i/teamlogos/leagues/500/nhl.png" },

  // ---- Soccer. `soccer` is ESPN's cross-competition aggregate.
  "soccer":  { name: "All soccer",       group: "Soccer", espn: "soccer/all" },
  "mls":     { name: "MLS",              group: "Soccer", espn: "soccer/usa.1" , logo: "https://a.espncdn.com/i/leaguelogos/soccer/500/19.png" },
  "eng.1":   { name: "Premier League",   group: "Soccer", espn: "soccer/eng.1" , logo: "https://a.espncdn.com/i/leaguelogos/soccer/500/23.png" },
  "esp.1":   { name: "LaLiga",           group: "Soccer", espn: "soccer/esp.1" , logo: "https://a.espncdn.com/i/leaguelogos/soccer/500/15.png" },
  "ger.1":   { name: "Bundesliga",       group: "Soccer", espn: "soccer/ger.1" , logo: "https://a.espncdn.com/i/leaguelogos/soccer/500/10.png" },
  "ita.1":   { name: "Serie A",          group: "Soccer", espn: "soccer/ita.1" , logo: "https://a.espncdn.com/i/leaguelogos/soccer/500/12.png" },
  "fra.1":   { name: "Ligue 1",          group: "Soccer", espn: "soccer/fra.1" , logo: "https://a.espncdn.com/i/leaguelogos/soccer/500/9.png" },
  "ucl":     { name: "Champions League", group: "Soccer", espn: "soccer/uefa.champions" , logo: "https://a.espncdn.com/i/leaguelogos/soccer/500/2.png" },
  "uel":     { name: "Europa League",    group: "Soccer", espn: "soccer/uefa.europa" , logo: "https://a.espncdn.com/i/leaguelogos/soccer/500/2310.png" },
  "wc":      { name: "World Cup",        group: "Soccer", espn: "soccer/fifa.world" , logo: "https://a.espncdn.com/i/leaguelogos/soccer/500/4.png" },
  "wwc":     { name: "Women's World Cup", group: "Soccer", espn: "soccer/fifa.wwc" , logo: "https://a.espncdn.com/i/leaguelogos/soccer/500/6.png" },

  // ---- Individual sports. No teams to follow, so these are browse-only.
  "ufc": { name: "UFC", group: "Other", espn: "mma/ufc", individual: true },
  "f1":  { name: "F1",  group: "Other", espn: "racing/f1", individual: true },
  "pga": { name: "PGA", group: "Other", espn: "golf/pga", individual: true },
  "atp": { name: "ATP", group: "Other", espn: "tennis/atp", individual: true },
  "wta": { name: "WTA", group: "Other", espn: "tennis/wta", individual: true }
};

// Leagues offered in the panel's league list, in display order. A user can
// still name any other slug in `leagues` — see resolve() — this is only what
// gets browsed without typing.
var BROWSE_ORDER = [
  "nfl", "ncaaf", "nba", "wnba", "ncaam", "mlb", "nhl",
  "eng.1", "esp.1", "ger.1", "ita.1", "fra.1", "ucl", "uel", "mls", "wc",
  "ufc", "f1", "pga", "atp"
];

// ESPN publishes ~216 soccer competitions and a comparable tail elsewhere.
// Rather than enumerate them, any slug this file does not know is passed
// through: "sport/league" verbatim, and a bare "ned.1"-shaped slug is assumed
// to be soccer, which is the only family that uses that form.
function resolve(slug) {
  var id = String(slug || "").trim()
  if (id === "") return null
  if (CATALOG.hasOwnProperty(id)) {
    var known = CATALOG[id]
    return {
      id: id, name: known.name, group: known.group, espn: known.espn,
      statsapi: known.statsapi || 0, nhlweb: known.nhlweb === true,
      individual: known.individual === true, logo: known.logo || "", known: true
    }
  }
  var espn = id.indexOf("/") >= 0 ? id : (/^[a-z]{3}\.\d+$/.test(id) ? "soccer/" + id : "")
  if (espn === "") return null
  return {
    id: id, name: id, group: "Other", espn: espn,
    statsapi: 0, nhlweb: false, individual: false, logo: "", known: false
  }
}

// League mark, or "" when ESPN publishes none — college and the long tail of
// soccer competitions have no logo, and the caller draws a monogram instead.
function logoFor(slug) {
  var league = resolve(slug)
  return league ? league.logo : ""
}

// Short label for a monogram when there is no mark.
function shortLabel(slug) {
  var name = displayName(slug)
  var words = String(name).split(/[\s.]+/).filter(function(w) { return w !== "" })
  // An acronym carries the identity on its own: "NCAA Football" as "NF" reads
  // as NFL, which is a different league sitting two rows above it.
  if (words.length > 0 && /^[A-Z]{2,}$/.test(words[0])) return words[0].slice(0, 2)
  if (words.length >= 2) return (words[0].charAt(0) + words[1].charAt(0)).toUpperCase()
  return String(name).slice(0, 2).toUpperCase()
}

function displayName(slug) {
  var league = resolve(slug)
  return league ? league.name : String(slug || "")
}

function group(slug) {
  var league = resolve(slug)
  return league ? league.group : "Other"
}

function isIndividual(slug) {
  var league = resolve(slug)
  return league ? league.individual : false
}

// Which providers can serve this league, best first. The user's providerChain
// setting overrides per league; anything it names that cannot serve the league
// is dropped rather than tried and failed.
function providersFor(slug, overrides) {
  var league = resolve(slug)
  if (!league) return []
  var capable = ["espn"]
  if (league.statsapi) capable.push("mlb")
  if (league.nhlweb) capable.push("nhl")

  var requested = overrides && overrides[slug]
  if (!Array.isArray(requested) || requested.length === 0) return capable

  var chain = []
  for (var i = 0; i < requested.length; i++) {
    var name = String(requested[i])
    if (capable.indexOf(name) >= 0 && chain.indexOf(name) < 0) chain.push(name)
  }
  return chain.length > 0 ? chain : capable
}

function browseList() {
  var out = []
  for (var i = 0; i < BROWSE_ORDER.length; i++) {
    var league = resolve(BROWSE_ORDER[i])
    if (league) out.push(league)
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    CATALOG: CATALOG,
    BROWSE_ORDER: BROWSE_ORDER,
    resolve: resolve,
    displayName: displayName,
    group: group,
    isIndividual: isIndividual,
    providersFor: providersFor, logoFor: logoFor, shortLabel: shortLabel,
    browseList: browseList
  }
}
