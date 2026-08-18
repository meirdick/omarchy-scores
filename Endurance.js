// Sports car racing: the FIA WEC (which is where Le Mans lives), the European
// Le Mans Series, and IMSA.
//
// None of them have a free JSON API, and ESPN carries no sports car racing at
// all. What they do have is Al Kamel Systems, who time all three and publish
// the official classification for every session as semicolon-delimited CSV.
// This reads those.
//
// The deliberate limitation: this is the last completed session, not live
// timing. Al Kamel's live app talks DDP over a websocket and every plausible
// JSON path returns the application shell instead of data, so live positions
// would mean reverse-engineering a private protocol. A finished race read from
// the official classification is worth more than a live feed that breaks.

var CHAMPIONSHIPS = {
  wec: {
    name: "FIA WEC",
    index: "https://fiawec.alkamelsystems.com/index.php",
    base: "https://fiawec.alkamelsystems.com/"
  },
  elms: {
    name: "European Le Mans Series",
    index: "https://elms.alkamelsystems.com/index.php",
    base: "https://elms.alkamelsystems.com/"
  },
  // Le Mans is a round of the WEC, but it is also the race people actually
  // want, so it gets its own entry pinned to that event instead of following
  // whatever round is current.
  lemans: {
    name: "24 Hours of Le Mans",
    index: "https://fiawec.alkamelsystems.com/index.php",
    base: "https://fiawec.alkamelsystems.com/",
    pinnedEvent: /LE\s*MANS/i
  },
  imsa: {
    name: "IMSA SportsCar Championship",
    // The bare root, not index.php: index.php answers 302 with a Location that
    // is missing the slash between host and path, so it cannot be followed.
    index: "https://results.imsa.com/",
    // results.imsa.com answers every file with a 302 whose Location is missing
    // the slash between host and path — "…alkamelcloud.comResults/…" — so it
    // cannot be followed. The corrected host is requested directly instead.
    base: "https://imsa.results.alkamelcloud.com/"
  }
}

function championship(slug) {
  return CHAMPIONSHIPS.hasOwnProperty(String(slug)) ? CHAMPIONSHIPS[String(slug)] : null
}

function isEnduranceLeague(slug) { return championship(slug) !== null }

function indexUrl(slug) {
  var meta = championship(slug)
  return meta ? meta.index : ""
}

// The season and event selectors on the results page. Al Kamel writes the
// attribute as `Value` with a capital V, so the match has to be case
// insensitive — matching lowercase finds nothing and looks like an empty
// archive.
function parseSelectors(text) {
  var html = String(text || "")
  function options(field) {
    var select = new RegExp('<select[^>]*name=["\']' + field + '["\'][^>]*>([\\s\\S]*?)</select>', "i").exec(html)
    if (!select) return []
    var out = []
    var option = /<option[^>]*\svalue\s*=\s*["']([^"']*)["'][^>]*>([\s\S]*?)<\/option>/gi
    var found
    while ((found = option.exec(select[1])) !== null) {
      out.push({
        value: found[1],
        label: String(found[2]).replace(/\s+/g, " ").trim(),
        selected: /\sselected/i.test(found[0])
      })
    }
    return out
  }
  return { seasons: options("season"), events: options("evvent") }
}

// The URL for one specific event of one season.
function eventIndexUrl(slug, season, event) {
  var meta = championship(slug)
  if (!meta) return ""
  return meta.index + "?season=" + encodeURIComponent(season) +
         "&evvent=" + encodeURIComponent(event)
}

// Which event this championship wants out of the selector. Pinned
// championships take their own; everything else takes whatever is current.
function chooseEvent(slug, selectors) {
  var meta = championship(slug)
  if (!meta || !meta.pinnedEvent || !selectors) return null
  var events = selectors.events || []
  // Latest first: a pinned event should resolve to this season's running of it.
  for (var i = events.length - 1; i >= 0; i--)
    if (meta.pinnedEvent.test(events[i].label) || meta.pinnedEvent.test(events[i].value))
      return events[i]
  return null
}

function currentSeason(selectors) {
  var seasons = selectors && selectors.seasons ? selectors.seasons : []
  for (var i = 0; i < seasons.length; i++) if (seasons[i].selected) return seasons[i]
  return seasons.length > 0 ? seasons[seasons.length - 1] : null
}

function isPinned(slug) {
  var meta = championship(slug)
  return !!(meta && meta.pinnedEvent)
}

function decode(text) {
  try { return decodeURIComponent(String(text)) } catch (e) { return String(text) }
}

// Every result link on the index page, parsed into something sortable.
//
// A path looks like:
//   Results/15_2026/04_SAO PAULO/666_FIA WEC/202607121130_Race/06_Hour 6/03_Classification_Race_Hour 6.CSV
// The 12-digit stamp orders sessions within an event, and a race is split into
// one classification per hour, so the hour orders them within the race.
function parseIndex(text, slug) {
  var lines = String(text || "").split(/["'\s<>]+/)
  var seen = {}, sessions = []

  for (var i = 0; i < lines.length; i++) {
    var raw = lines[i]
    if (raw.indexOf("Results/") !== 0 || !/\.CSV$/i.test(raw)) continue
    var path = decode(raw)
    // 03_ is the classification family. 23_Analysis, 26_Weather and
    // 27_Transponder are different documents entirely.
    var file = path.split("/").pop()
    if (!/^03_/.test(file)) continue
    if (seen[raw]) continue
    seen[raw] = true

    var stamp = ""
    var stampMatch = path.match(/\/(\d{12})_/)
    if (stampMatch) stamp = stampMatch[1]

    var sessionMatch = path.match(/\/\d{12}_([^/]+)/)
    var session = sessionMatch ? sessionMatch[1] : ""

    // The hour folder between the session and the file. WEC writes "06_Hour 6",
    // ELMS writes plain "Hour 1"; read the number wherever it sits.
    var hour = 0
    var hourMatch = path.match(/\/(?:(\d{1,2})_)?Hour\s*(\d+)\//i)
    if (hourMatch) hour = parseInt(hourMatch[2] || hourMatch[1], 10)

    var eventMatch = path.match(/^Results\/[^/]+\/([^/]+)\//)
    sessions.push({
      href: raw,
      path: path,
      stamp: stamp,
      session: session,
      hour: hour,
      event: eventMatch ? cleanEventName(eventMatch[1]) : "",
      file: file
    })
  }
  return sessions
}

// "04_SAO PAULO" -> "Sao Paulo". The leading number is a running order, and
// the names are shouted.
function cleanEventName(raw) {
  var name = String(raw || "").replace(/^\d+_/, "").replace(/_/g, " ").trim()
  if (name === "") return ""
  if (name !== name.toUpperCase()) return name
  return name.toLowerCase().replace(/(^|[\s(\-])([a-z])/g, function(all, lead, letter) {
    return lead + letter.toUpperCase()
  })
}

// Rank a session so the most interesting finished one wins:
//   a race beats qualifying beats practice
//   a later hour of a race beats an earlier one
//   an official classification beats a provisional or unofficial one
function scoreSession(entry) {
  var name = (entry.session + " " + entry.file).toLowerCase()
  var kind = 0
  if (/race|hours|hour/.test(name)) kind = 3
  else if (/hyperpole|qualifying/.test(name)) kind = 2
  else if (/practice|test|warm/.test(name)) kind = 1

  var certainty = 1
  if (/unofficial/.test(name)) certainty = 0
  else if (/provisional/.test(name)) certainty = 1
  else if (/official|classification/.test(name)) certainty = 2

  return { kind: kind, certainty: certainty }
}

// The one session to show.
//
// `expectedEvent` is the event folder the caller asked for, e.g. "03_LE MANS".
// It matters because the results site is stateful: the same URL serves
// whichever event was selected last, so a request for Le Mans can come back
// holding São Paulo. Filtering by the folder name means a wrong page yields
// nothing rather than the wrong race.
//
// Sorted by when a session ran, so a stale race from an earlier event can
// never outrank the current weekend.
function pickLatest(sessions, expectedEvent) {
  if (!sessions || sessions.length === 0) return null
  if (expectedEvent) {
    var wanted = String(expectedEvent)
    sessions = sessions.filter(function(entry) {
      return entry.path.indexOf(wanted) >= 0 || entry.href.indexOf(encodeURIComponent(wanted)) >= 0
    })
    if (sessions.length === 0) return null
  }
  var best = null
  for (var i = 0; i < sessions.length; i++) {
    var entry = sessions[i]
    var rank = scoreSession(entry)
    entry._kind = rank.kind
    entry._certainty = rank.certainty
    if (best === null) { best = entry; continue }
    if (entry.stamp !== best.stamp) { if (entry.stamp > best.stamp) best = entry; continue }
    if (entry._kind !== best._kind) { if (entry._kind > best._kind) best = entry; continue }
    if (entry.hour !== best.hour) { if (entry.hour > best.hour) best = entry; continue }
    if (entry._certainty > best._certainty) best = entry
  }
  return best
}

function classificationUrl(slug, entry) {
  var meta = championship(slug)
  if (!meta || !entry) return ""
  return meta.base + entry.href
}

// Header-driven, because the columns differ by championship and by session
// type: a WEC race publishes POSITION;NUMBER;TEAM;DRIVER_1..4;VEHICLE, a WEC
// practice publishes POS;NUMBER;LAP;TIME;…, and IMSA publishes
// POSITION;NUMBER;STATUS;LAPS;TOTAL_TIME;GAP_FIRST;…. Reading by index would
// silently mislabel every one of them.
function parseClassification(text) {
  var raw = String(text || "")
  // The files are UTF-8 with a BOM, which otherwise becomes part of the first
  // column name and makes every lookup miss.
  if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1)
  var lines = raw.split(/\r?\n/).filter(function(line) { return line.trim() !== "" })
  if (lines.length < 2) return []

  var header = lines[0].split(";").map(function(name) { return name.trim().toUpperCase() })
  function columnOf(names) {
    for (var i = 0; i < names.length; i++) {
      var at = header.indexOf(names[i])
      if (at >= 0) return at
    }
    return -1
  }

  var col = {
    position: columnOf(["POSITION", "POS"]),
    number: columnOf(["NUMBER"]),
    team: columnOf(["TEAM"]),
    cls: columnOf(["CLASS"]),
    laps: columnOf(["LAPS", " LAPS"]),
    gap: columnOf(["GAP_FIRST"]),
    vehicle: columnOf(["VEHICLE"]),
    status: columnOf(["STATUS"])
  }

  var driverColumns = []
  for (var h = 0; h < header.length; h++)
    if (/^DRIVER_?\d+$/.test(header[h]) || /^DRIVER\d+_SECONDNAME$/.test(header[h]))
      driverColumns.push(h)

  var rows = []
  for (var i = 1; i < lines.length; i++) {
    var cells = lines[i].split(";")
    function cell(index) {
      return index >= 0 && index < cells.length ? String(cells[index]).trim() : ""
    }
    var position = parseInt(cell(col.position), 10)
    if (!isFinite(position)) continue

    var drivers = []
    for (var d = 0; d < driverColumns.length; d++) {
      var name = cell(driverColumns[d])
      if (name !== "") drivers.push(name)
    }

    rows.push({
      position: position,
      number: cell(col.number),
      team: cell(col.team),
      cls: cell(col.cls),
      laps: cell(col.laps),
      gap: cell(col.gap),
      vehicle: cell(col.vehicle),
      status: cell(col.status),
      drivers: drivers
    })
  }
  rows.sort(function(a, b) { return a.position - b.position })
  return rows
}

// The classification as the normalized Game the rest of the plugin renders.
// It is an event, like a grand prix or a golf tournament: a field with an
// order, not two sides with a score.
function toGame(slug, entry, rows, nowMs, followedNumbers) {
  var meta = championship(slug)
  if (!meta || !entry) return null

  var leaders = []
  for (var i = 0; i < rows.length && i < 3; i++) {
    var row = rows[i]
    var label = (row.number !== "" ? "#" + row.number + " " : "") + row.team
    // The winner is described by what they won — the class. Everyone else is
    // described by how far back they were, which is the thing that differs;
    // repeating "HYPERCAR" down the column says nothing.
    var gap = row.gap === "-" ? "" : row.gap
    var detail = i === 0 ? (row.cls !== "" ? row.cls : row.laps)
                         : (gap !== "" ? gap : (row.cls !== "" ? row.cls : row.laps))
    leaders.push({ name: label, detail: detail, cls: row.cls, winner: i === 0, order: row.position })
  }

  // A car you follow is shown wherever it finished. Thirty-second overall is
  // still the result you opened the panel for, and a podium you have no stake
  // in is not.
  var wanted = {}
  var list = followedNumbers || []
  for (var w = 0; w < list.length; w++) wanted[String(list[w]).toUpperCase()] = true

  // Position within the class, which is the result that matters in sports car
  // racing: the classes race each other, not the field. A Le Mans LMP2 entry
  // finishing 32nd overall is 32nd behind a faster class it was never racing.
  var classRank = {}
  var classSize = {}
  for (var c = 0; c < rows.length; c++) {
    var key = String(rows[c].cls || "")
    classSize[key] = (classSize[key] || 0) + 1
    classRank[rows[c].position + "|" + key] = classSize[key]
  }

  for (var m = 0; m < rows.length; m++) {
    var row = rows[m]
    if (!wanted[String(row.number).toUpperCase()]) continue
    var already = false
    for (var k = 0; k < leaders.length; k++) if (leaders[k].order === row.position) already = true
    if (already) continue
    // Surnames only. "David HEINEMEIER HANSSON, Edward PEARSON, Jack DOOHAN"
    // is the full crew but does not fit a panel row; the surnames do.
    // One surname. A full endurance crew is three or four names; alongside the
    // car number and the team they do not fit the row, and an elided list that
    // breaks mid-word reads worse than a single name does.
    var drivers = row.drivers.filter(function(name) { return name !== "" }).map(surname).slice(0, 1)
    var inClass = classRank[row.position + "|" + String(row.cls || "")]
    var size = classSize[String(row.cls || "")]
    // A followed entry is named by its number and its driver rather than its
    // team: the number identifies the car, the driver is why you follow it,
    // and all three plus a class position does not fit the row.
    var plate = row.number !== "" ? "#" + row.number + " " : ""
    leaders.push({
      name: plate + (drivers.length > 0 ? drivers[0] : row.team),
      team: row.team,
      detail: row.cls !== "" && inClass
        ? (row.cls + " P" + inClass + "/" + size)
        : (row.cls !== "" ? row.cls : row.laps),
      drivers: drivers,
      cls: row.cls,
      classPosition: inClass || null,
      classSize: size || null,
      followed: true,
      winner: false,
      order: row.position
    })
  }
  leaders.sort(function(a, b) { return a.order - b.order })

  var title = entry.event !== "" ? entry.event : meta.name
  var startMs = stampToMs(entry.stamp)

  return {
    isEvent: true,
    leaders: leaders,
    id: slug + ":" + entry.stamp + ":" + entry.hour,
    eventId: entry.stamp,
    provider: "endurance",
    league: slug,
    sport: "racing",
    name: title,
    startUtc: startMs,
    // Always a finished session. This reads results, never live timing.
    state: "FINAL",
    rawStatus: "Final",
    statusDetail: entry.session,
    delayed: false,
    period: null,
    clock: "",
    home: emptyside(), away: emptyside(),
    situation: null,
    venue: "",
    sessionLabel: prettySession(entry),
    detailUrl: meta.base + entry.href,
    updatedAt: nowMs || 0,
    entries: rows
  }
}

// "David HEINEMEIER HANSSON" -> "Heinemeier Hansson". The files put the given
// name first and shout the family name, which is what makes it separable.
function surname(full) {
  var parts = String(full || "").trim().split(/\s+/)
  var shouted = parts.filter(function(part) { return part.length > 1 && part === part.toUpperCase() })
  var name = shouted.length > 0 ? shouted.join(" ") : parts[parts.length - 1] || ""
  return name.replace(/\S+/g, function(word) {
    return word.charAt(0).toUpperCase() + word.slice(1).toLowerCase()
  })
}

function emptyside() {
  return { abbr: "", name: "", fullName: "", id: "", score: null, color: "", altColor: "",
           logo: "", record: "", lines: [], winner: false }
}

function prettySession(entry) {
  var name = String(entry.session || "").replace(/_/g, " ").trim()
  if (entry.hour > 0) name += " · after " + entry.hour + "h"
  return name
}

// "202607121130" -> epoch ms, read as local time. The files carry no timezone
// and the circuit's own clock is what the folder name means.
function stampToMs(stamp) {
  var raw = String(stamp || "")
  if (!/^\d{12}$/.test(raw)) return 0
  var date = new Date(
    parseInt(raw.slice(0, 4), 10),
    parseInt(raw.slice(4, 6), 10) - 1,
    parseInt(raw.slice(6, 8), 10),
    parseInt(raw.slice(8, 10), 10),
    parseInt(raw.slice(10, 12), 10))
  var ms = date.getTime()
  return isFinite(ms) ? ms : 0
}

if (typeof module !== "undefined") {
  module.exports = {
    CHAMPIONSHIPS: CHAMPIONSHIPS,
    championship: championship, isEnduranceLeague: isEnduranceLeague,
    indexUrl: indexUrl, parseIndex: parseIndex, pickLatest: pickLatest,
    classificationUrl: classificationUrl, parseClassification: parseClassification,
    toGame: toGame, cleanEventName: cleanEventName, stampToMs: stampToMs,
    parseSelectors: parseSelectors, eventIndexUrl: eventIndexUrl,
    chooseEvent: chooseEvent, currentSeason: currentSeason, isPinned: isPinned,
    scoreSession: scoreSession, prettySession: prettySession, surname: surname
  }
}
