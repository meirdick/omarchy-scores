import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Leagues.js" as Leagues
import "Providers.js" as Providers
import "Endurance.js" as Endurance
import "Model.js" as Model

// Everything stateful: which leagues to poll, the fetch pool, the adaptive
// scheduler, the diff that drives notifications. The widget and the panel read
// properties off this and never touch the network themselves.
Item {
  id: root
  visible: false

  // Settings injected by the bar host. Authoritative in principle, but see
  // fileSettings below.
  property var settings: ({})

  // ---------------------------------------------------------------- settings
  //
  // The bar injects `settings` from the widget's shell.json entry, but that
  // injection does not reliably re-run when the file changes underneath it:
  // writing a new followedTeams and reading it back showed the old value for
  // as long as the shell stayed up, and `omarchy-shell shell reloadConfig` did
  // not shake it loose either — only a full restart did.
  //
  // Following a team writes to that file, so relying on the injection alone
  // means pressing f appears to do nothing until the next restart. Watch the
  // file directly and prefer what it says. When the injection is working, both
  // agree and this changes nothing.
  readonly property string shellConfigPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  property var fileSettings: ({})

  FileView {
    path: root.shellConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      // null means the file was unreadable — caught mid-save. Keep the last
      // good copy rather than briefly forgetting every followed team.
      var parsed = Model.widgetSettingsFrom(text(), root.moduleId)
      if (parsed !== null) root.fileSettings = parsed
    }
    onLoadFailed: root.fileSettings = ({})
  }

  readonly property string moduleId: "meirdick.scores"

  // --- results -------------------------------------------------------------
  // league slug -> array of normalized Game. Kept per league so one league
  // failing cannot blank the others.
  //
  // Today is tracked separately from whatever day the panel is browsing. The
  // bar is a glance at now: paging to tomorrow in the panel must not change
  // what the bar says, because the widget resizes to its text and the whole
  // bar shifts around it. It also keeps alerts honest — a game on next
  // Tuesday's card has not just started.
  property var gamesByLeague: ({})
  property var games: []
  property var browseByLeague: ({})
  property var browseGames: []
  // What the panel should render: today's set unless it is showing another day.
  readonly property var panelGames: dateOffset === 0 ? games : browseGames
  property var standings: []
  property string standingsLeague: ""
  property var summary: null
  property string summaryGameId: ""
  property var teams: []
  property bool teamsLoading: false
  property var teamsLoaded: ({})

  // --- status --------------------------------------------------------------
  property bool refreshing: false
  property bool loading: true
  property double lastRefreshMs: 0
  property string lastError: ""
  property string actionStatus: ""
  // Days from today; the panel's [ and ] move this.
  property int dateOffset: 0
  property bool panelOpen: false

  // First poll after startup must not fire alerts for games that were already
  // in progress — otherwise restarting the shell mid-game notifies for every
  // run scored before you logged in.
  property bool primed: false
  property var lastGames: ({})
  property var closeNotified: ({})

  signal scoreFlash(string gameId)

  // --- settings ------------------------------------------------------------
  // Manifest defaults are not merged into the injected settings by the shell,
  // so every default is restated here. Changing one means changing both.
  // The file wins: it is the thing the panel writes to and the thing a hand
  // edit changes, and it is never staler than the injected copy.
  function setting(name, fallback) {
    var value = fileSettings ? fileSettings[name] : undefined
    if (value === undefined || value === null) value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "boolean") return value
    var text = String(value).toLowerCase()
    if (text === "true" || text === "1" || text === "yes") return true
    if (text === "false" || text === "0" || text === "no") return false
    return fallback
  }

  // Writes go out through `omarchy bar set`, which is a whole round trip:
  // spawn, read shell.json, edit, write, file watcher, re-parse. Following two
  // things inside that window made the second write compute its new list from
  // the value before the first — so three quick follows kept two.
  //
  // These hold what was just asked for until the file agrees. null means
  // nothing pending, which is distinct from "" meaning follow nothing.
  property var pendingTeams: null
  property var pendingLeagues: null

  readonly property var follows: Model.normalizeFollows(
    pendingTeams !== null ? pendingTeams : setting("followedTeams", ""))
  readonly property var followedLeagues: Model.normalizeLeagues(
    pendingLeagues !== null ? pendingLeagues : setting("followedLeagues", ""))

  // Drop the optimistic value once the file says the same thing.
  function settlePending() {
    if (pendingTeams !== null &&
        Model.normalizeFollows(setting("followedTeams", "")).join(",") ===
        Model.normalizeFollows(pendingTeams).join(","))
      pendingTeams = null
    if (pendingLeagues !== null &&
        Model.normalizeLeagues(setting("followedLeagues", "")).join(",") ===
        Model.normalizeLeagues(pendingLeagues).join(","))
      pendingLeagues = null
  }

  onFileSettingsChanged: settlePending()

  // If a write never lands the optimistic value would stick forever, showing a
  // follow that does not exist. Give up after a few seconds and believe the
  // file again.
  Timer {
    id: pendingGuard
    interval: 8000
    onTriggered: {
      root.pendingTeams = null
      root.pendingLeagues = null
    }
  }
  readonly property int livePollSec: intSetting("livePollSec", 25, 10, 300)
  readonly property int idlePollSec: intSetting("idlePollSec", 900, 60, 7200)
  readonly property string barFormat: String(setting("barFormat", "full"))
  readonly property int rotateSec: intSetting("rotateSec", 6, 3, 60)
  readonly property bool showSituation: boolSetting("showSituation", true)
  readonly property bool showAllGames: boolSetting("showAllGames", false)
  readonly property int finalWindowHours: intSetting("finalWindowHours", 8, 0, 48)
  readonly property bool notifyStart: boolSetting("notifyStart", false)
  readonly property bool notifyScore: boolSetting("notifyScore", false)
  readonly property bool notifyFinal: boolSetting("notifyFinal", false)
  readonly property bool notifyClose: boolSetting("notifyClose", false)
  readonly property bool notifyLeagues: boolSetting("notifyLeagues", false)
  readonly property int closeMargin: intSetting("closeMargin", 1, 1, 20)
  readonly property int closeClockSec: intSetting("closeClockSec", 300, 30, 1800)
  readonly property string espnHost: String(setting("espnHost", "") || "").trim()

  readonly property var providerChain: {
    var raw = String(setting("providerChain", "") || "").trim()
    if (raw === "") return ({})
    try {
      var parsed = JSON.parse(raw)
      return (parsed && typeof parsed === "object") ? parsed : ({})
    } catch (e) {
      return ({})
    }
  }

  // Leagues worth polling: every league a followed team plays in, plus any the
  // user named explicitly. Polling a league nobody follows is pure waste, so
  // the default list is derived rather than hardcoded.
  readonly property var polledLeagues: {
    var seen = {}, out = []
    function add(slug) {
      var name = String(slug || "").trim()
      if (name === "" || seen[name] || !Leagues.resolve(name)) return
      seen[name] = true
      out.push(name)
    }
    for (var i = 0; i < follows.length; i++) add(follows[i].split(":")[0])
    for (var j = 0; j < followedLeagues.length; j++) add(followedLeagues[j])
    // The league currently being browsed, so opening a competition you do not
    // follow still shows its card instead of an empty view.
    add(browsingLeague)
    return out
  }

  // Set by the panel when a league view is open. Cleared on the way out so an
  // idle session does not keep polling a league you glanced at once.
  property string browsingLeague: ""

  // Always today's games, never the browsed day's.
  readonly property var barInfo: Model.barState(games, follows, nowMs, {
    format: barFormat,
    leagues: followedLeagues,
    rotateIndex: rotateIndex,
    finalWindowHours: finalWindowHours,
    formatTime: root.formatTime
  })

  // Ticks for countdowns and relative times. One second while a game is live
  // so the clock reads honestly, a minute otherwise.
  property double nowMs: Date.now()
  Timer {
    interval: root.barInfo.mode === "live" ? 1000 : 30000
    repeat: true
    running: true
    onTriggered: root.nowMs = Date.now()
  }

  property int rotateIndex: 0
  Timer {
    // Only rotates when there is more than one live game to rotate between.
    interval: root.rotateSec * 1000
    repeat: true
    running: root.barInfo.count > 1
    onTriggered: root.rotateIndex = root.rotateIndex + 1
  }

  function formatTime(date) { return Qt.formatTime(date, "h:mm AP") }

  function currentDate() {
    var date = new Date()
    date.setDate(date.getDate() + root.dateOffset)
    return date
  }

  function isToday() { return root.dateOffset === 0 }

  // ------------------------------------------------------------- fetch pool

  // A small fixed pool rather than one process per league: following a dozen
  // leagues should not fork a dozen curls at once.
  component Request: Process {
    id: req
    property string tag: ""
    property var handler: null
    property bool busy: false
    property string lastCommand: ""

    stdout: StdioCollector { id: reqOut; waitForEnd: true }
    stderr: StdioCollector { id: reqErr; waitForEnd: true }

    function send(url, etagPath, onDone) {
      if (req.busy) return false
      req.busy = true
      req.handler = onDone
      // -f so HTTP errors are a nonzero exit rather than an error page parsed
      // as JSON. -L because NHL's /score/now answers 307. --compressed because
      // it turns a 214 KB scoreboard into 20 KB.
      //
      // No -A/--user-agent anywhere, deliberately: site.api.espn.com 403s
      // browser-shaped User-Agents and 200s curl's own. Setting one to "look
      // like a browser" is the classic way to break this plugin.
      var command = ["curl", "-fsSL", "--compressed", "--max-time", "12"]
      if (etagPath !== "") {
        command.push("--etag-compare", etagPath)
        command.push("--etag-save", etagPath)
      }
      command.push(url)
      req.command = command
      req.lastCommand = command.join(" ")
      req.running = true
      return true
    }

    onExited: function(exitCode) {
      var body = String(reqOut.text || "")
      var error = String(reqErr.text || "").trim()
      var callback = req.handler
      req.handler = null

      // The slot stays busy until the callback has run and the stack has
      // unwound. Endurance fetches enqueue their next hop from inside their
      // own callback; releasing the slot first let the drain hand that hop
      // straight back to this Process while it was still inside onExited, and
      // the new command was swallowed — the handler then read the previous
      // response. That is how asking for Le Mans returned São Paulo.
      Qt.callLater(function() {
        req.busy = false
        if (callback) callback(exitCode, body, error)
        root.drainQueue()
      })
    }
  }

  Request { id: slot0 }
  Request { id: slot1 }
  Request { id: slot2 }
  Request { id: slot3 }
  readonly property var pool: [slot0, slot1, slot2, slot3]

  property var queue: []

  function enqueue(job) {
    var next = root.queue.slice()
    next.push(job)
    root.queue = next
    drainQueue()
  }

  function drainQueue() {
    if (root.queue.length === 0) return
    for (var i = 0; i < root.pool.length && root.queue.length > 0; i++) {
      if (root.pool[i].busy) continue
      var next = root.queue.slice()
      var job = next.shift()
      root.queue = next
      root.pool[i].send(job.url, job.etagPath, job.done)
    }
  }

  readonly property string cacheDir: Quickshell.env("HOME") + "/.cache/omarchy/meirdick.scores"

  // curl writes the ETag here and compares against it on the next request; a
  // 304 then comes back as an empty body, which costs nothing to receive.
  //
  // Keyed by the URL, never by the league. An endurance league's URL changes
  // when the event does, and a per-league key meant the ETag from São Paulo's
  // classification was sent when asking for Le Mans — the server answered 304
  // and the panel kept showing the wrong race while the fetch logged the right
  // one.
  function etagPathFor(url) {
    var text = String(url)
    // A URL is far too long and too full of separators to be a filename, so a
    // short hash of it is the key, with a readable prefix to keep the cache
    // directory diagnosable by eye.
    var hash = 5381
    for (var i = 0; i < text.length; i++) hash = ((hash * 33) ^ text.charCodeAt(i)) >>> 0
    var host = text.replace(/^https?:\/\//, "").split("/")[0].replace(/[^A-Za-z0-9.-]/g, "_")
    return root.cacheDir + "/" + host + "-" + hash.toString(36) + ".etag"
  }

  Process { id: mkCache; command: ["mkdir", "-p", root.cacheDir] }

  // ------------------------------------------------------------- scoreboard

  property int _pending: 0

  function refresh() {
    if (root.refreshing) return
    var leagues = root.polledLeagues
    if (leagues.length === 0) {
      root.loading = false
      root.games = []
      root.gamesByLeague = ({})
      return
    }

    root.refreshing = true
    // Today always. When the panel is showing another day, that day is fetched
    // alongside so the bar and the panel can disagree about the date without
    // either going stale.
    var browsing = root.dateOffset !== 0
    root._pending = leagues.length * (browsing ? 2 : 1)

    var today = new Date()
    for (var i = 0; i < leagues.length; i++) fetchLeague(leagues[i], today, false)
    if (!browsing) return
    var browsed = root.currentDate()
    for (var j = 0; j < leagues.length; j++) fetchLeague(leagues[j], browsed, true)
  }

  function fetchLeague(league, date, forBrowse) {
    var chain = Leagues.providersFor(league, root.providerChain)
    fetchLeagueVia(league, date, chain, 0, forBrowse === true)
  }

  // Walk the provider chain: if the first provider fails, fall through to the
  // next rather than leaving the league blank. Only the last failure is
  // reported, because an ESPN hiccup that statsapi covered is not news.
  // Sports car racing takes two hops: the results index names the current
  // event and its sessions, and the classification itself is a separate CSV.
  // Everything else is one request, so this sits beside the normal path rather
  // than complicating it.
  // Resolved season/event per pinned league, and when each league was last
  // fetched. Both exist because of how the results site behaves — see below.
  property var enduranceEvent: ({})
  property var enduranceFetchedMs: ({})

  // Discovery on the results site is unreliable — the event a page describes
  // is shared server-side state that any visitor can change, so asking for a
  // past round returns whatever somebody else selected. The classification CSV
  // it eventually points at, though, is a static file: stable, byte-identical
  // on every request, unaffected by that state.
  //
  // So discovery only has to succeed once. What it finds is written here and
  // used directly from then on, which turns a flaky navigation into a one-off.
  readonly property string enduranceCachePath: root.cacheDir + "/endurance.json"
  property var enduranceResolved: ({})

  FileView {
    id: enduranceCache
    path: root.enduranceCachePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (parsed && typeof parsed === "object") root.enduranceResolved = parsed
      } catch (e) {
        // A truncated write. The next discovery replaces it.
      }
    }
  }

  function rememberEnduranceUrl(league, session) {
    var next = {}
    for (var key in root.enduranceResolved) next[key] = root.enduranceResolved[key]
    next[league] = {
      url: Endurance.classificationUrl(league, session),
      event: session.event,
      session: session.session,
      hour: session.hour,
      stamp: session.stamp
    }
    root.enduranceResolved = next
    enduranceCache.setText(JSON.stringify(next, null, 2))
  }

  function fetchEndurance(league, forBrowse) {
    // Results, not live timing — so this is fetched on the slow cadence and
    // only ever for today's set. Browsing to another day cannot change a
    // finished classification.
    if (forBrowse) { finishLeague(); return }

    // A finished classification does not change. Re-reading it every poll adds
    // nothing and, on this site, actively causes harm — see the session note
    // below. Half an hour is plenty to notice a new race.
    var lastFetch = root.enduranceFetchedMs[league] || 0
    if (root.gamesByLeague[league] !== undefined && (Date.now() - lastFetch) < 1800000) {
      finishLeague()
      return
    }

    // The results site keeps the selected event in a PHP session that is
    // shared by every client — the same PHPSESSID comes back for everyone — so
    // "which event does index.php describe" is global server state that any
    // request can change. Asking for the landing page and then the event page
    // therefore races: another request in between re-points the session, and
    // the event page answers with somebody else's race.
    //
    // So the landing page is read exactly once, to learn which season and
    // event folder this championship wants, and after that only the explicit
    // event URL is ever requested.
    // Already discovered: go straight to the file, skipping the navigation
    // that cannot be trusted.
    var known = root.enduranceResolved[league]
    if (known && known.url) {
      fetchClassification(league, {
        href: "", event: known.event, session: known.session,
        hour: known.hour, stamp: known.stamp, path: "", file: ""
      }, known.url)
      return
    }

    var resolved = root.enduranceEvent[league]
    if (Endurance.isPinned(league) && resolved) {
      fetchEnduranceEvent(league, resolved.season, resolved.event)
      return
    }

    enqueue({
      url: Endurance.indexUrl(league),
      // No ETag on any endurance request: the results site serves whichever
      // event was selected last for this client, so the same URL does not mean
      // the same content and a 304 can hand back the wrong race.
      etagPath: "",
      done: function(exitCode, body, error) {
        if (exitCode !== 0) {
          root.lastError = Leagues.displayName(league) + ": " + (error || "curl exited " + exitCode)
          finishLeague()
          return
        }
        // A 304: the index has not changed, so neither has the session it
        // points at. Keep what we have.
        if (String(body).trim() === "" && root.gamesByLeague[league] !== undefined) {
          finishLeague()
          return
        }

        // A pinned championship — Le Mans — wants one specific round rather
        // than whatever is current, so the season and event selectors on the
        // landing page decide which event page to ask for next.
        if (Endurance.isPinned(league)) {
          var selectors = Endurance.parseSelectors(body)
          var season = Endurance.currentSeason(selectors)
          var wanted = Endurance.chooseEvent(league, selectors)
          traceEndurance(league, {
            pinned: true,
            seasonsSeen: selectors.seasons.length,
            eventsSeen: selectors.events.length,
            chose: wanted ? wanted.value : "none"
          })
          if (!season || !wanted) {
            root.lastError = Leagues.displayName(league) + ": event not in the archive"
            finishLeague()
            return
          }
          var remembered = {}
          for (var key in root.enduranceEvent) remembered[key] = root.enduranceEvent[key]
          remembered[league] = { season: season.value, event: wanted.value }
          root.enduranceEvent = remembered

          fetchEnduranceEvent(league, season.value, wanted.value)
          return
        }

        fetchClassification(league, Endurance.pickLatest(Endurance.parseIndex(body, league)))
      }
    })
  }

  // One specific event of one specific season, then its classification.
  function fetchEnduranceEvent(league, season, event) {
    traceEndurance(league, { season: season, event_requested: event,
                             eventUrl: Endurance.eventIndexUrl(league, season, event) })
    enqueue({
      url: Endurance.eventIndexUrl(league, season, event),
      etagPath: "",
      done: function(exitCode, body, error) {
        if (exitCode !== 0) {
          root.lastError = Leagues.displayName(league) + ": " + (error || "curl exited " + exitCode)
          finishLeague()
          return
        }
        var picked = Endurance.pickLatest(Endurance.parseIndex(body, league), event)
        if (!picked) {
          // The shared session was re-pointed by another request between ours
          // going out and coming back. Say nothing rather than show the wrong
          // race under this name; the next refresh will try again.
          root.lastError = Leagues.displayName(league) + ": results page returned another event"
          finishLeague()
          return
        }
        fetchClassification(league, picked)
      }
    })
  }

  // The last hop: one classification CSV into one normalized event.
  // What each endurance league resolved to, for diagnose(). A wrong event is
  // otherwise indistinguishable from a right one until you read the panel.
  property var enduranceTrace: ({})

  function traceEndurance(league, note) {
    var next = {}
    for (var key in root.enduranceTrace) next[key] = root.enduranceTrace[key]
    var merged = {}
    var existing = next[league] || {}
    for (var a in existing) merged[a] = existing[a]
    for (var b in note) merged[b] = note[b]
    next[league] = merged
    root.enduranceTrace = next
  }

  function fetchClassification(league, session, knownUrl) {
    traceEndurance(league, session
      ? { event: session.event, session: session.session, hour: session.hour,
          url: Endurance.classificationUrl(league, session) }
      : { event: "none" })
    if (!session) {
      root.lastError = Leagues.displayName(league) + ": no classification published"
      finishLeague()
      return
    }

    var csvUrl = knownUrl ? knownUrl : Endurance.classificationUrl(league, session)
    if (csvUrl === "") { finishLeague(); return }
    // Only a freshly discovered session is worth writing down; replaying a
    // cached one would rewrite the same file every half hour.
    if (!knownUrl) rememberEnduranceUrl(league, session)

    // Car numbers followed in this championship, so the entry you care about
    // is shown wherever it finished rather than only the podium.
    var wantedNumbers = []
    for (var i = 0; i < root.follows.length; i++) {
      var parts = root.follows[i].split(":")
      if (parts[0] === league && parts[1]) wantedNumbers.push(parts[1])
    }

    enqueue({
      url: csvUrl,
      etagPath: "",
      done: function(csvExit, csvBody, csvError) {
        if (csvExit !== 0) {
          root.lastError = Leagues.displayName(league) + ": " + (csvError || "curl exited " + csvExit)
          finishLeague()
          return
        }
        if (String(csvBody).trim() === "" && root.gamesByLeague[league] !== undefined) {
          finishLeague()
          return
        }

        var rows = Endurance.parseClassification(csvBody)
        // This league is healthy now; do not keep showing why it once was not.
        root.lastError = ""
        var game = Endurance.toGame(league, session, rows, Date.now(), wantedNumbers)
        var stamped = {}
        for (var f in root.enduranceFetchedMs) stamped[f] = root.enduranceFetchedMs[f]
        stamped[league] = Date.now()
        root.enduranceFetchedMs = stamped
        var next = {}
        for (var key in root.gamesByLeague) next[key] = root.gamesByLeague[key]
        next[league] = game ? [game] : []
        root.gamesByLeague = next
        finishLeague()
      }
    })
  }

  function fetchLeagueVia(league, date, chain, index, forBrowse) {
    if (chain.length > 0 && chain[0] === "endurance") { fetchEndurance(league, forBrowse); return }
    if (index >= chain.length) {
      root.lastError = Leagues.displayName(league) + ": no provider available"
      finishLeague()
      return
    }
    var providerName = chain[index]
    var provider = Providers.get(providerName)
    var url = provider ? provider.scoreboardUrl(league, date, providerName === "espn" && root.espnHost !== "" ? root.espnHost : undefined) : ""
    if (url === "") { fetchLeagueVia(league, date, chain, index + 1, forBrowse); return }

    // The ETag is per league, per provider and per date — sharing one across
    // dates would serve yesterday's card as "unchanged".
    enqueue({
      url: url,
      etagPath: root.etagPathFor(url),
      done: function(exitCode, body, error) {
        if (exitCode !== 0) {
          if (index + 1 < chain.length) { fetchLeagueVia(league, date, chain, index + 1, forBrowse); return }
          root.lastError = Leagues.displayName(league) + ": " + (error || "curl exited " + exitCode)
          finishLeague()
          return
        }

        // Empty body with a clean exit is curl reporting 304 Not Modified.
        // Keep what we already have; it is by definition current.
        var bucket = forBrowse ? root.browseByLeague : root.gamesByLeague
        if (String(body).trim() === "" && bucket[league] !== undefined) {
          finishLeague()
          return
        }

        var parsed = provider.parseScoreboard(body, league, Date.now())
        if (parsed.ok) root.lastError = ""
        if (!parsed.ok) {
          if (index + 1 < chain.length) { fetchLeagueVia(league, date, chain, index + 1, forBrowse); return }
          root.lastError = Leagues.displayName(league) + ": " + parsed.error
          finishLeague()
          return
        }

        var next = {}
        for (var key in bucket) next[key] = bucket[key]
        next[league] = parsed.games
        if (forBrowse) root.browseByLeague = next
        else root.gamesByLeague = next
        finishLeague()
      }
    })
  }

  function finishLeague() {
    root._pending = Math.max(0, root._pending - 1)
    if (root._pending > 0) return

    root.refreshing = false
    root.loading = false
    root.lastRefreshMs = Date.now()
    rebuildGames()
    reschedule()
  }

  function flatten(byLeague) {
    var merged = []
    for (var league in byLeague) {
      var list = byLeague[league]
      for (var i = 0; i < list.length; i++) merged.push(list[i])
    }
    return merged
  }

  function rebuildGames() {
    root.games = flatten(root.gamesByLeague)
    root.browseGames = flatten(root.browseByLeague)
    // Diffing only ever looks at today. Paging the panel to another date is
    // not a score change, and diffing it would alert on games that finished
    // last week.
    emitEvents(root.games)
  }

  // ------------------------------------------------------------- diffing

  function emitEvents(current) {
    var events = Model.diffGames(root.lastGames, current, {
      follows: root.follows,
      leagues: root.followedLeagues,
      notifyLeagues: root.notifyLeagues,
      suppress: !root.primed,
      closeMargin: root.closeMargin,
      closeClockSec: root.closeClockSec
    })

    for (var i = 0; i < events.length; i++) {
      var event = events[i]
      if (event.type === "score") root.scoreFlash(event.game.id)
      if (!wantsNotification(event.type)) continue
      // A close game would otherwise re-notify on every poll it stays close.
      if (event.type === "close") {
        if (root.closeNotified[event.game.id]) continue
        var marked = {}
        for (var key in root.closeNotified) marked[key] = root.closeNotified[key]
        marked[event.game.id] = true
        root.closeNotified = marked
      }
      var text = Model.notificationFor(event, root.nowMs, root.formatTime)
      notify(text.title, text.body)
    }

    var snapshot = {}
    for (var j = 0; j < current.length; j++) snapshot[current[j].id] = current[j]
    root.lastGames = snapshot
    root.primed = true
  }

  function wantsNotification(type) {
    switch (type) {
    case "start": return root.notifyStart
    case "score": return root.notifyScore
    case "final": return root.notifyFinal
    case "close": return root.notifyClose
    }
    return false
  }

  function notify(title, body) {
    Quickshell.execDetached(["omarchy-notification-send", "-g", "󰿈",
                             String(title), String(body || "")])
  }

  // ------------------------------------------------------------- on demand

  function loadStandings(league) {
    if (root.standingsLeague === league && root.standings.length > 0) return
    root.standingsLeague = league
    root.standings = []
    var url = Providers.espn.standingsUrl(league)
    if (url === "") return
    enqueue({
      url: url, etagPath: "",
      done: function(exitCode, body) {
        if (exitCode !== 0 || root.standingsLeague !== league) return
        root.standings = Providers.espn.parseStandings(body)
      }
    })
  }

  function loadSummary(game) {
    if (!game || game.provider !== "espn") { root.summary = null; return }
    if (root.summaryGameId === game.id && root.summary) return
    root.summaryGameId = game.id
    root.summary = null
    var url = Providers.espn.summaryUrl(game.league, game.eventId,
                                        root.espnHost !== "" ? root.espnHost : undefined)
    if (url === "") return
    // No ETag here: this is fetched once when the detail view opens, never
    // polled, so a conditional request would only add a round trip.
    enqueue({
      url: url, etagPath: "",
      done: function(exitCode, body) {
        if (exitCode !== 0 || root.summaryGameId !== game.id) return
        root.summary = Providers.espn.parseSummary(body)
      }
    })
  }

  // Team lists back the follow picker. Fetched once per league, on first
  // search, because a full team list never changes mid-season.
  function loadTeams(leagues) {
    for (var i = 0; i < leagues.length; i++) {
      var league = leagues[i]
      if (root.teamsLoaded[league]) continue
      if (Leagues.isIndividual(league)) continue
      var url = Providers.espn.teamsUrl(league, root.espnHost !== "" ? root.espnHost : undefined)
      if (url === "") continue

      var marked = {}
      for (var key in root.teamsLoaded) marked[key] = root.teamsLoaded[key]
      marked[league] = true
      root.teamsLoaded = marked
      root.teamsLoading = true

      enqueue({
        url: url, etagPath: root.etagPathFor(url),
        done: (function(slug) {
          return function(exitCode, body) {
            root.teamsLoading = false
            if (exitCode !== 0) return
            var parsed = Providers.espn.parseTeams(body, slug)
            if (parsed.length === 0) return
            var merged = root.teams.slice()
            for (var t = 0; t < parsed.length; t++) merged.push(parsed[t])
            root.teams = merged
          }
        })(league)
      })
    }
  }

  // Searching should reach every league that can be browsed, not only the ones
  // currently polled — otherwise you cannot follow a team in a league you have
  // no team in yet, which is every league on first run.
  function loadAllTeams() {
    var list = Leagues.browseList()
    var slugs = []
    for (var i = 0; i < list.length; i++) slugs.push(list[i].id)
    loadTeams(slugs)
  }

  // ------------------------------------------------------------- following

  // shell.json is the single source of truth. Writing through the CLI rather
  // than keeping a private copy means a hand-edited config and a keypress in
  // the panel can never disagree — the same trick the weather plugin uses to
  // persist its location.
  // Following and unfollowing are separate actions on purpose. A single toggle
  // bound to one key means a stray keypress silently empties the follow list
  // and nothing says so — which is exactly how this lost its only team during
  // development.
  function writeSetting(key, value) {
    // Believe it locally straight away; the file catches up.
    if (key === "followedTeams") root.pendingTeams = value
    else if (key === "followedLeagues") root.pendingLeagues = value
    pendingGuard.restart()
    // No --json: these are plain comma-separated strings, and --json makes
    // omarchy-bar try to parse "mlb:TB" as JSON and write nothing at all.
    Quickshell.execDetached(["omarchy", "bar", "set", root.moduleId, key, value])
  }

  function followTeam(league, abbr) {
    var label = String(abbr).toUpperCase()
    if (Model.isFollowedTeam(Model.followSet(root.follows), league, abbr)) {
      flashStatus("Already following " + label)
      return
    }
    writeSetting("followedTeams", Model.addFollow(root.follows, league, abbr).join(","))
    flashStatus("Following " + label)
    // The league may not have been polled before; pick it up without waiting
    // for shell.json to round-trip.
    Qt.callLater(root.refresh)
  }

  function unfollowTeam(league, abbr) {
    var label = String(abbr).toUpperCase()
    if (!Model.isFollowedTeam(Model.followSet(root.follows), league, abbr)) {
      flashStatus("Not following " + label)
      return
    }
    writeSetting("followedTeams", Model.removeFollow(root.follows, league, abbr).join(","))
    flashStatus("Unfollowed " + label)
  }

  function followLeague(slug) {
    var label = Leagues.displayName(slug)
    if (root.followedLeagues.indexOf(String(slug)) >= 0) {
      flashStatus("Already following " + label)
      return
    }
    writeSetting("followedLeagues", Model.addFollowLeague(root.followedLeagues, slug).join(","))
    flashStatus("Following " + label)
    Qt.callLater(root.refresh)
  }

  function unfollowLeague(slug) {
    var label = Leagues.displayName(slug)
    if (root.followedLeagues.indexOf(String(slug)) < 0) {
      flashStatus("Not following " + label)
      return
    }
    writeSetting("followedLeagues", Model.removeFollowLeague(root.followedLeagues, slug).join(","))
    flashStatus("Unfollowed " + label)
  }

  function flashStatus(text) {
    root.actionStatus = String(text || "")
    statusTimer.restart()
  }

  Timer {
    id: statusTimer
    interval: 2600
    onTriggered: root.actionStatus = ""
  }

  function openUrl(url) {
    if (!url) return
    Quickshell.execDetached(["omarchy-launch-browser", String(url)])
  }

  function setDateOffset(days) {
    if (root.dateOffset === days) return
    root.dateOffset = days
    // Only the browsed set is discarded. Today's games stay exactly as they
    // are, so the bar does not blink, resize, or shove the rest of the bar
    // sideways every time you page a day.
    root.browseByLeague = ({})
    root.browseGames = []
    root.loading = days !== 0
    root.refreshing = false
    root._pending = 0
    Qt.callLater(root.refresh)
  }

  // ------------------------------------------------------------- scheduling

  // Adaptive pacing. Polling a free endpoint every 25 seconds all week for
  // games nobody is watching is how a widget becomes a nuisance.
  readonly property int pollSec: Model.pollIntervalSec(games, follows, nowMs, {
    livePollSec: livePollSec,
    idlePollSec: idlePollSec,
    leagues: followedLeagues,
    panelOpen: panelOpen
  })

  function reschedule() { pollTimer.interval = Math.max(5, root.pollSec) * 1000 }

  Timer {
    id: pollTimer
    interval: 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onPollSecChanged: reschedule()
  onPanelOpenChanged: if (panelOpen) Qt.callLater(root.refresh)
  onFollowsChanged: Qt.callLater(root.refresh)
  onFollowedLeaguesChanged: Qt.callLater(root.refresh)
  onBrowsingLeagueChanged: if (browsingLeague !== "") Qt.callLater(root.refresh)

  // A hung curl would otherwise wedge its slot forever, since a league is
  // skipped while its own request is still running. curl's --max-time is the
  // first line of defence; this is the backstop for a process that never
  // reports at all.
  Timer {
    interval: 45000
    repeat: true
    running: root.refreshing
    onTriggered: {
      for (var i = 0; i < root.pool.length; i++) {
        if (!root.pool[i].busy) continue
        root.pool[i].running = false
        root.pool[i].busy = false
      }
      root.queue = []
      root._pending = 0
      root.refreshing = false
      root.loading = false
      root.lastError = "request timed out"
    }
  }

  Component.onCompleted: {
    // Non-library JS gets one context per QML document, so the league catalog
    // has to be handed to each copy. Every file importing Model or Providers
    // does this.
    Model.useLeagues(Leagues)
    Providers.useLeagues(Leagues)
    mkCache.running = true
  }

  // Machine-readable state for `omarchy-shell meirdick.scores diagnose`. QML
  // load failures and bad settings are both silent on screen, so this is the
  // only practical way to see what the widget thinks is true.
  function diagnose() {
    var byLeague = {}
    for (var league in root.gamesByLeague) byLeague[league] = root.gamesByLeague[league].length
    return JSON.stringify({
      follows: root.follows,
      followedLeagues: root.followedLeagues,
      polledLeagues: root.polledLeagues,
      browsingLeague: root.browsingLeague,
      providerChain: root.providerChain,
      espnHost: root.espnHost === "" ? Providers.ESPN_HOST : root.espnHost,
      pending: { teams: root.pendingTeams, leagues: root.pendingLeagues },
      settingsSource: {
        injected: root.settings && root.settings.followedTeams !== undefined
          ? String(root.settings.followedTeams) : null,
        file: root.fileSettings && root.fileSettings.followedTeams !== undefined
          ? String(root.fileSettings.followedTeams) : null
      },
      dateOffset: root.dateOffset,
      gamesByLeague: byLeague,
      totalGames: root.games.length,
      browsedGames: root.browseGames.length,
      bar: { mode: root.barInfo.mode, text: root.barInfo.text, count: root.barInfo.count },
      pollSec: root.pollSec,
      panelOpen: root.panelOpen,
      nowMs: root.nowMs,
      refreshing: root.refreshing,
      queued: root.queue.length,
      lastRefreshMs: root.lastRefreshMs,
      lastError: root.lastError,
      endurance: root.enduranceTrace,
      enduranceResolved: root.enduranceResolved,
      primed: root.primed,
      notifications: {
        start: root.notifyStart, score: root.notifyScore,
        final: root.notifyFinal, close: root.notifyClose,
        leagues: root.notifyLeagues
      }
    }, null, 2)
  }
}
