import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Leagues.js" as Leagues
import "Providers.js" as Providers
import "Model.js" as Model

Panel {
  id: root
  moduleName: "meirdick.scores"
  ipcTarget: "meirdick.scores"
  manageIpc: false

  property var anchorItem: null
  // The bar tracks the widget in its slot, not this nested panel, so the
  // popout coordinator and Tab-switching must both identify as the widget.
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root

  // --- theme ---------------------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // Live state reads as the theme accent throughout. Red is loud and this
  // widget is live most of the time it is visible; reserving it for genuine
  // problems keeps it meaningful when it does appear.
  readonly property color accent: Color.accent
  readonly property color divider: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.09)
  // What club colours are drawn against, so their contrast can be judged.
  readonly property color panelBackground: Color.popups.background
  readonly property string panelBackgroundHex: {
    function hex(v) {
      var n = Math.max(0, Math.min(255, Math.round(v * 255))).toString(16)
      return n.length === 1 ? "0" + n : n
    }
    return "#" + hex(panelBackground.r) + hex(panelBackground.g) + hex(panelBackground.b)
  }
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color fainter: Qt.darker(foreground, 2.1)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // --- navigation ----------------------------------------------------------
  // "" is today's card; everything else is a drill-down. One flat cursor over
  // one ListView — the body is heterogeneous but every row is a row, so
  // movement never has to know which section it is in.
  property string route: ""
  property int cursorIndex: 0
  property bool cursorActive: false
  property string filter: ""
  property bool filtering: false
  // Where the cursor sat in each route, restored on the way back. Coming back
  // from a league to find the cursor reset to the top is the small thing that
  // makes a drill-down feel like a maze.
  property var routeCursors: ({})

  readonly property double nowMs: service ? service.nowMs : 0

  readonly property var rows: service ? Model.buildRows({
    route: route,
    games: service.panelGames,
    follows: service.follows,
    followedLeagues: service.followedLeagues,
    now: nowMs,
    filter: filter,
    loading: service.loading,
    showAll: service.showAllGames,
    standings: service.standings,
    standingsLeague: service.standingsLeague,
    // Only the league view distinguishes "still fetching" from "nothing on".
    // Feeding `refreshing` into the general loading flag would make the Today
    // card flash "Loading…" on every poll.
    leagueLoading: service.refreshing || service.loading,
    summary: service.summary,
    teams: service.teams,
    teamsLoading: service.teamsLoading,
    leagueCounts: leagueCounts,
    formatTime: service.formatTime
  }) : []

  readonly property var leagueCounts: {
    var counts = {}
    if (!service) return counts
    var source = service.dateOffset === 0 ? service.gamesByLeague : service.browseByLeague
    for (var league in source) counts[league] = source[league].length
    return counts
  }

  readonly property int liveCount: {
    if (!service) return 0
    var count = 0
    for (var i = 0; i < service.panelGames.length; i++)
      if (service.panelGames[i].state === "LIVE") count++
    return count
  }

  readonly property var currentRow: rows.length > 0 && cursorIndex >= 0 && cursorIndex < rows.length
    ? rows[cursorIndex] : null

  // --- hero ----------------------------------------------------------------
  readonly property string heroTitle: {
    if (filtering && route !== "search") return "Search"
    if (route === "search") return "Follow a team"
    if (route === "leagues") return "Leagues"
    if (route.indexOf("standings:") === 0) return Leagues.displayName(route.slice(10)) + " standings"
    if (route.indexOf("league:") === 0) return Leagues.displayName(route.slice(7))
    if (route.indexOf("game:") === 0) {
      var open = currentGame()
      return open ? (open.away.abbr + "  at  " + open.home.abbr) : "Game"
    }
    return dateTitle
  }

  readonly property string dateTitle: {
    if (!service) return "Scores"
    if (service.dateOffset === 0) return "Today"
    if (service.dateOffset === 1) return "Tomorrow"
    if (service.dateOffset === -1) return "Yesterday"
    return Qt.formatDate(service.currentDate(), "ddd d MMM")
  }

  readonly property string heroMeta: {
    if (!service) return ""
    if (service.lastError !== "") return service.lastError
    if (service.actionStatus !== "") return service.actionStatus
    if (route === "search" && filter !== "") {
      // Count the results, not the rows — the section headings are not matches.
      var hits = 0
      for (var h = 0; h < rows.length; h++)
        if (rows[h].kind === "team" || rows[h].kind === "league") hits++
      return hits + (hits === 1 ? " match" : " matches") + "  ·  enter or f to follow"
    }
    if (route === "search") return "type to search  ·  f to follow  ·  esc to leave"
    if (filtering) return rows.length + " matching  ·  esc to leave search"
    if (route !== "") return "h or esc to go back"
    if (service.follows.length === 0 && service.followedLeagues.length === 0)
      return "Nothing followed — press / for teams, L for leagues"
    // Counted off the rows, not off everything polled. A league is fetched to
    // find one club's game, and saying "11 games" above a card showing one
    // was just wrong.
    var live = 0, total = 0
    for (var i = 0; i < rows.length; i++) {
      if (!Model.isFixtureRow(rows[i])) continue
      total++
      if (rows[i].game.state === "LIVE") live++
    }
    if (total === 0) return "Nothing you follow is on today"
    var parts = []
    if (live > 0) parts.push(live + " live")
    parts.push(total + (total === 1 ? " game" : " games"))
    return parts.join("  ·  ")
  }

  readonly property string heroDetail: service && service.refreshing ? "SYNC" : ""

  // ------------------------------------------------------------- navigation

  function selectableAt(index) {
    if (index < 0 || index >= rows.length) return false
    return rows[index].selectable !== false
  }

  function clampCursor() {
    if (rows.length === 0) { cursorIndex = 0; return }
    if (cursorIndex >= rows.length) cursorIndex = rows.length - 1
    if (cursorIndex < 0) cursorIndex = 0
    if (selectableAt(cursorIndex)) return
    for (var i = cursorIndex; i < rows.length; i++) if (selectableAt(i)) { cursorIndex = i; return }
    for (var j = cursorIndex; j >= 0; j--) if (selectableAt(j)) { cursorIndex = j; return }
  }

  // The row the cursor is on, tracked by identity rather than position.
  //
  // Following a team rewrites shell.json, which rebuilds every row and moves
  // the team into a different section. Holding the cursor at an index then
  // leaves it pointing at some unrelated row, and replacing the ListView's
  // model scrolls it back to the top — so acting on a row threw you to the top
  // of the panel looking at something else.
  property string cursorKey: ""

  function rememberCursor() {
    var row = rows.length > 0 && cursorIndex >= 0 && cursorIndex < rows.length ? rows[cursorIndex] : null
    cursorKey = row ? String(row.key) : ""
  }

  function indexOfKey(key) {
    if (key === "") return -1
    for (var i = 0; i < rows.length; i++) if (String(rows[i].key) === key) return i
    return -1
  }

  onRowsChanged: {
    var restored = indexOfKey(cursorKey)
    if (restored >= 0 && restored !== cursorIndex) cursorIndex = restored
    clampCursor()
    // The model was replaced, so the view is back at the top whatever the
    // cursor says. Put it back under the row the cursor is on.
    if (cursorActive) Qt.callLater(function() { list.positionViewAtIndex(root.cursorIndex, ListView.Contain) })
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy !== 0 && rows.length > 0) {
      var next = cursorIndex
      for (var guard = 0; guard < rows.length; guard++) {
        next += dy > 0 ? 1 : -1
        if (next < 0 || next >= rows.length) return
        if (selectableAt(next)) {
          cursorIndex = next
          rememberCursor()
          list.positionViewAtIndex(next, ListView.Contain)
          return
        }
      }
      return
    }
    // Left and right are the drill-down axis, not horizontal movement: there
    // is only ever one column.
    if (dx > 0) activateCursor()
    else if (dx < 0) goBack()
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = index
    clampCursor()
    rememberCursor()
  }

  function pushRoute(next) {
    var remembered = {}
    for (var key in routeCursors) remembered[key] = routeCursors[key]
    remembered[route] = cursorIndex
    routeCursors = remembered
    route = next
    cursorIndex = Model.firstSelectable(rows)
    cursorKey = ""
    Qt.callLater(function() {
      root.clampCursor()
      root.rememberCursor()
      list.positionViewAtBeginning()
    })
  }

  function goBack() {
    if (filtering) { stopFiltering(); return }
    if (route === "") { close(); return }
    if (service && route.indexOf("league:") === 0) service.browsingLeague = ""
    var previous = route.indexOf("standings:") === 0 ? "league:" + route.slice(10) : ""
    var restored = routeCursors[previous]
    route = previous
    cursorIndex = restored === undefined ? Model.firstSelectable(rows) : restored
    cursorKey = ""
    Qt.callLater(function() {
      root.clampCursor()
      root.rememberCursor()
    })
  }

  function activateCursor() {
    var row = currentRow
    if (!row || row.selectable === false) return

    if (row.kind === "game") {
      if (route.indexOf("game:") === 0) { service.openUrl(row.game.detailUrl); return }
      service.loadSummary(row.game)
      pushRoute("game:" + row.game.id)
      return
    }
    if (row.kind === "league") {
      // Polling follows the view: opening a competition you do not follow
      // still has to fill it. Standings come along because they are what the
      // view is mostly made of.
      service.browsingLeague = row.league
      service.loadStandings(row.league)
      pushRoute("league:" + row.league)
      return
    }
    if (row.kind === "team") {
      service.followTeam(row.league, row.abbr)
      return
    }
    // Enter on a standings row follows that team. It is the obvious thing to
    // want from a list of every club in a competition, and it saves going back
    // out to the search view to type a name you are already looking at.
    if (row.kind === "standing") {
      if (row.followed) service.flashStatus("Already following " + row.entry.abbr)
      else service.followTeam(row.league, row.entry.abbr)
      return
    }
    if (row.kind === "action") {
      if (row.action === "leagues") { pushRoute("leagues"); return }
      if (row.action === "search") { startFiltering(true); return }
      if (row.action === "open") {
        var game = currentGame()
        if (game) service.openUrl(game.detailUrl)
        return
      }
      if (String(row.action).indexOf("standings:") === 0) {
        service.loadStandings(String(row.action).slice(10))
        pushRoute(row.action)
        return
      }
    }
  }

  function currentGame() {
    if (route.indexOf("game:") !== 0 || !service) return null
    var id = route.slice(5)
    for (var i = 0; i < service.panelGames.length; i++)
      if (service.panelGames[i].id === id) return service.panelGames[i]
    return null
  }

  // `f` follows, `x` unfollows. Never one key that does both: a toggle bound to
  // a single key removes a team the moment you press it twice, or once by
  // accident, and nothing on screen says a follow just disappeared.
  function followCurrent() { applyFollow(true) }
  function unfollowCurrent() { applyFollow(false) }

  function applyFollow(add) {
    var row = currentRow
    if (!row || !service) return

    if (row.kind === "league") {
      if (add) service.followLeague(row.league)
      else service.unfollowLeague(row.league)
      return
    }
    if (row.kind === "team") {
      if (add) service.followTeam(row.league, row.abbr)
      else service.unfollowTeam(row.league, row.abbr)
      return
    }
    if (row.kind === "standing") {
      if (add) service.followTeam(row.league, row.entry.abbr)
      else service.unfollowTeam(row.league, row.entry.abbr)
      return
    }
    if (row.kind !== "game") return

    // A game names two teams, so "follow this row" is ambiguous. Adding takes
    // the home side unless the home side is already followed, which makes
    // pressing f twice on a derby follow both rather than nothing.
    var game = row.game
    var set = Model.followSet(service.follows)
    var home = Model.isFollowedTeam(set, game.league, game.home.abbr)
    var away = Model.isFollowedTeam(set, game.league, game.away.abbr)

    if (add) {
      if (!home) service.followTeam(game.league, game.home.abbr)
      else if (!away) service.followTeam(game.league, game.away.abbr)
      else service.flashStatus("Following both already")
      return
    }
    if (away) service.unfollowTeam(game.league, game.away.abbr)
    else if (home) service.unfollowTeam(game.league, game.home.abbr)
    else service.flashStatus("Not following either team")
  }

  function openCurrent() {
    var row = currentRow
    if (row && row.kind === "game") { service.openUrl(row.game.detailUrl); return }
    var game = currentGame()
    if (game) service.openUrl(game.detailUrl)
  }

  function startFiltering(searchTeams) {
    filtering = true
    if (searchTeams) {
      service.loadAllTeams()
      if (route !== "search") pushRoute("search")
    }
    filter = ""
    Qt.callLater(function() {
      filterField.text = ""
      filterField.forceActiveFocus()
    })
  }

  function stopFiltering() {
    filtering = false
    filter = ""
    if (route === "search") goBack()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function shiftDate(days) {
    if (!service) return
    service.setDateOffset(service.dateOffset + days)
    route = ""
    cursorIndex = 0
  }

  // ------------------------------------------------------------- lifecycle

  // A route the caller wants applied once the panel is up. Without this the
  // reset below, which fires when `opened` flips, lands after the caller's
  // pushRoute and throws it away.
  property string pendingRoute: ""

  function open() {
    // Reset here rather than only in onOpenedChanged: summoning a panel that
    // is already open changes nothing about `opened`, so the handler never
    // runs and the panel stays on whatever league you last drilled into.
    resetToToday()
    root.controller.show()
    if (service) service.panelOpen = true
  }

  function resetToToday() {
    route = pendingRoute
    pendingRoute = ""
    filter = ""
    // One invariant instead of a sequence: the search route always has its
    // field open. Leaving that to the caller meant re-entering search while
    // already on it reset the field away again, and the keystrokes fell
    // through to the panel's own bindings.
    filtering = route === "search"
    cursorActive = false
    if (service) {
      if (route.indexOf("league:") !== 0) service.browsingLeague = ""
      // The date is part of "where you were", same as the route. Opening the
      // panel to find it still on next Tuesday because you paged there an hour
      // ago is the same disorientation as opening it inside a league you have
      // forgotten you drilled into.
      service.setDateOffset(0)
    }
    cursorIndex = Model.firstSelectable(rows)
    cursorKey = ""
    list.positionViewAtBeginning()
    Qt.callLater(function() {
      root.cursorIndex = Model.firstSelectable(root.rows)
      root.rememberCursor()
      list.positionViewAtBeginning()
    })
  }

  function close() {
    if (filtering) { filtering = false; filter = "" }
    if (service) service.panelOpen = false
    root.controller.hide()
  }

  function toggle() { opened ? close() : open() }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  onOpenedChanged: {
    if (service) service.panelOpen = opened
    // Deliberately no reset here. open() already does it, and running it again
    // when `opened` flips would land after the caller has chosen a route and
    // throw that choice away.
  }

  Component.onCompleted: {
    Model.useLeagues(Leagues)
    Providers.useLeagues(Leagues)
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { if (root.service) root.service.refresh() }
    // Quickshell's IPC matches on exact arity, so a league cannot be an
    // optional second argument to follow() — it needs its own pair.
    function follow(league: string, abbr: string): string {
      if (!root.service) return "no service"
      root.service.followTeam(league, abbr)
      return "following " + league + ":" + String(abbr).toUpperCase()
    }
    function unfollow(league: string, abbr: string): string {
      if (!root.service) return "no service"
      root.service.unfollowTeam(league, abbr)
      return "unfollowed " + league + ":" + String(abbr).toUpperCase()
    }
    function followLeague(league: string): string {
      if (!root.service) return "no service"
      root.service.followLeague(league)
      return "following league " + league
    }
    function unfollowLeague(league: string): string {
      if (!root.service) return "no service"
      root.service.unfollowLeague(league)
      return "unfollowed league " + league
    }
    function following(): string {
      if (!root.service) return "no service"
      return JSON.stringify({
        teams: root.service.follows,
        leagues: root.service.followedLeagues
      }, null, 2)
    }
    // QML load failures and bad settings are both silent on screen, so this is
    // the only practical way to see what the widget believes.
    // Jump straight to a view: "", "leagues", "league:mlb", "standings:nfl".
    // Bindable to a hotkey, and the only way to drive the panel headlessly.
    function route(name: string): string {
      var target = String(name || "")
      // Handed to the panel rather than pushed after open(), because opening
      // resets the view and would discard it.
      root.pendingRoute = target
      root.open()
      if (target.indexOf("standings:") === 0) root.service.loadStandings(target.slice(10))
      // A league view is mostly its standings, so entering one over IPC has to
      // fetch them the same way clicking into it does.
      if (target.indexOf("league:") === 0) {
        var slug = target.slice(7)
        root.service.browsingLeague = slug
        root.service.loadStandings(slug)
      }
      if (target === "search") {
        // Same end state as pressing "/": the field is focused and waiting,
        // rather than a search view with nowhere to type.
        root.startFiltering(true)
        return "route search"
      }
      return "route " + (target === "" ? "today" : target)
    }

    // Where the panel is, as opposed to what the service holds. Route and
    // focus are not visible from diagnose(), and both matter when a keypress
    // does something unexpected.
    function state(): string {
      return JSON.stringify({
        opened: root.opened,
        route: root.route === "" ? "today" : root.route,
        filtering: root.filtering,
        filter: root.filter,
        cursorIndex: root.cursorIndex,
        cursorKey: root.cursorKey,
        cursorActive: root.cursorActive,
        rows: root.rows.length,
        fieldFocused: filterField.activeFocus,
        catcherFocused: keyCatcher.activeFocus
      }, null, 2)
    }

    function diagnose(): string { return root.service ? root.service.diagnose() : "no service" }
  }

  // ------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
    // Sized to content and capped: a fixed tall card leaves a three-game
    // evening three-quarters empty. list.contentHeight is the sum of delegate
    // heights and does not depend on the view's own height, so this does not
    // feed back into itself; past the cap the list scrolls.
    contentHeight: panel.fittedContentHeight(
      header.implicitHeight + Style.space(14) + list.contentHeight + legend.implicitHeight,
      Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.filtering

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive && dy !== 0) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.unfollowCurrent()
      onCloseRequested: root.goBack()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        switch (text) {
        case "/": root.startFiltering(true); break
        case "f": root.followCurrent(); break
        case "o": root.openCurrent(); break
        case "r": if (root.service) root.service.refresh(); break
        case "[": root.shiftDate(-1); break
        case "]": root.shiftDate(1); break
        case "t": root.shiftDate(-(root.service ? root.service.dateOffset : 0)); break
        case "L": root.pushRoute("leagues"); break
        case "g": root.setCursor(Model.firstSelectable(root.rows)); list.positionViewAtBeginning(); break
        case "G": root.setCursor(root.rows.length - 1); list.positionViewAtEnd(); break
        }
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(10)

        Column {
          id: header
          width: parent.width
          spacing: Style.space(8)

          PanelHero {
            width: parent.width
            title: root.heroTitle
            meta: root.heroMeta
            detail: root.heroDetail
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              ScoresMark {
                foreground: root.foreground
                accent: root.accent
                markSize: Style.font.display
                live: root.liveCount > 0
              }
            }

            // One button, not two. Search covers teams and leagues both, so a
            // separate "add a league" control would be a second door into the
            // same room. It sits in the header so it is reachable from every
            // view, not only from the bottom of the Today card.
            trailingControl: Component {
              PanelActionButton {
                iconText: "+"
                tooltipText: "Follow a team or league"
                foreground: root.foreground
                hoverColor: root.accent
                fontFamily: root.fontFamily
                bordered: true
                visible: root.route !== "search"
                onClicked: root.startFiltering(true)
              }
            }
          }

          TextField {
            id: filterField
            visible: root.filtering
            width: parent.width
            placeholderText: root.route === "search" ? "Search every team…" : "Filter games…"
            onTextChanged: root.filter = text
            Keys.onEscapePressed: root.stopFiltering()
            Keys.onReturnPressed: {
              // Leaving the field but keeping the query is what makes
              // search-then-follow one gesture instead of two.
              root.filtering = false
              Qt.callLater(function() { keyCatcher.forceActiveFocus() })
            }
            Keys.onDownPressed: {
              root.filtering = false
              root.cursorActive = true
              Qt.callLater(function() { keyCatcher.forceActiveFocus() })
            }
          }
        }

        ListView {
          id: list
          width: parent.width
          height: Math.max(0, content.height - header.implicitHeight - legend.implicitHeight - Style.space(20))
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          model: root.rows
          spacing: Style.space(1)
          currentIndex: root.cursorIndex

          delegate: Loader {
            id: rowLoader
            required property var modelData
            required property int index
            width: list.width
            sourceComponent: modelData.kind === "section" ? sectionComponent
              : modelData.kind === "note" ? noteComponent
              : modelData.kind === "game" ? gameComponent
              : modelData.kind === "event" ? eventComponent
              : modelData.kind === "league" ? leagueComponent
              : modelData.kind === "standing" ? standingComponent
              : modelData.kind === "play" ? playComponent
              : modelData.kind === "leader" ? leaderComponent
              : modelData.kind === "linescore" ? linescoreComponent
              : simpleComponent

            // Bound, not assigned in onLoaded. ListView reuses a delegate when
            // the next row wants the same component, and onLoaded does not fire
            // again for a reused item — a one-shot assignment then leaves the
            // row rendering its old game and reporting a stale index to the
            // click handler.
            Binding {
              target: rowLoader.item
              property: "row"
              value: rowLoader.modelData
              when: rowLoader.item !== null
              restoreMode: Binding.RestoreNone
            }
            Binding {
              target: rowLoader.item
              property: "rowIndex"
              value: rowLoader.index
              when: rowLoader.item !== null
              restoreMode: Binding.RestoreNone
            }
          }
        }

        Text {
          id: legend
          width: parent.width
          text: root.legendText
          color: root.fainter
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          maximumLineCount: 1
        }
      }
    }
  }

  readonly property string legendText: {
    if (filtering) return "type to filter  ·  ↓ or enter to the list  ·  esc cancels"
    if (route === "search") return "f follow  ·  x unfollow  ·  / search again  ·  esc back"
    if (route.indexOf("game:") === 0) return "o open on the web  ·  f follow  ·  h back"
    if (route === "leagues") return "f follow league  ·  x unfollow  ·  l open  ·  h back"
    if (route.indexOf("standings:") === 0) return "enter or f follow  ·  x unfollow  ·  h back"
    if (route.indexOf("league:") === 0) return "enter follow  ·  x unfollow  ·  o web  ·  h back"
    return "l detail  ·  f follow  ·  x unfollow  ·  / search  ·  [ ] day"
  }

  // ------------------------------------------------------------- delegates

  component RowBase: Rectangle {
    id: rowBase
    property var row: null
    property int rowIndex: -1
    readonly property bool selected: root.cursorActive && root.cursorIndex === rowIndex
    readonly property bool selectable: row && row.selectable !== false
    width: ListView.view ? ListView.view.width : 0
    radius: Style.cornerRadius
    color: selected ? root.selectedFill : (hover.containsMouse && selectable ? root.hoverFill : "transparent")

    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: true
      enabled: rowBase.selectable
      cursorShape: rowBase.selectable ? Qt.PointingHandCursor : Qt.ArrowCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      onClicked: function(mouse) {
        root.setCursor(rowBase.rowIndex)
        if (mouse.button === Qt.MiddleButton) root.openCurrent()
        else root.activateCursor()
      }
    }
  }

  Component {
    id: sectionComponent
    RowBase {
      implicitHeight: sectionLabel.implicitHeight + Style.space(26)
      PanelSectionHeader {
        id: sectionLabel
        anchors.left: parent.left
        anchors.right: sectionCount.left
        anchors.rightMargin: Style.space(8)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(3)
        anchors.leftMargin: Style.space(4)
        text: row ? row.title : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      // The count belongs on the heading, not in it: "Live 3" as one string
      // would be indistinguishable from a section actually called that.
      Text {
        id: sectionCount
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.baseline: sectionLabel.baseline
        visible: text !== ""
        text: row ? String(row.meta || "") : ""
        color: root.fainter
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Component {
    id: noteComponent
    RowBase {
      implicitHeight: noteText.implicitHeight + Style.space(14)
      Text {
        id: noteText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)
        text: row ? row.text : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }
  }

  // The scoreboard row. One line per team rather than "AWAY 6 · HOME 7" on a
  // single line: it is how every scores app lays this out, because it puts the
  // crests, the names and the two numbers in fixed columns the eye can scan
  // down instead of parsing left to right.
  Component {
    id: gameComponent
    RowBase {
      id: gameRow
      implicitHeight: gameBody.implicitHeight + Style.space(20)

      readonly property var game: row ? row.game : null
      readonly property string token: game ? Model.stateToken(game) : "none"
      readonly property string leader: game ? Model.leaderSide(game) : ""
      readonly property string winner: game ? Model.winnerSide(game) : ""
      readonly property bool isLive: token === "live"

      // Change detection for the motion below. Keyed on the game id as well as
      // the activity, because ListView recycles delegates: without the id
      // check, scrolling would look like every game just scored.
      property string seenGameId: ""
      property string seenActivity: ""
      property int seenHome: -1
      property int seenAway: -1

      function syncActivity() {
        if (!game) return
        var activity = Model.activityKey(game)
        if (seenGameId !== game.id) {
          // First sight of this game in this delegate: adopt its state without
          // animating. Nothing has happened, we just arrived.
          seenGameId = game.id
          seenActivity = activity
          seenHome = game.home.score === null ? -1 : game.home.score
          seenAway = game.away.score === null ? -1 : game.away.score
          return
        }
        if (activity === seenActivity) return
        seenActivity = activity

        var home = game.home.score === null ? -1 : game.home.score
        var away = game.away.score === null ? -1 : game.away.score
        var scored = (home > seenHome) || (away > seenAway)
        seenHome = home
        seenAway = away

        if (!isLive) return
        if (scored) scorePulse.restart()
        else playSweep.restart()
      }

      onRowChanged: syncActivity()
      Component.onCompleted: syncActivity()

      // A play happened but nobody scored: a light sweep across the row. Quiet
      // enough to notice only if you are looking at it.
      Rectangle {
        id: sweep
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Style.space(90)
        radius: Style.cornerRadius
        opacity: 0
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: "transparent" }
          GradientStop { position: 0.5; color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18) }
          GradientStop { position: 1.0; color: "transparent" }
        }
      }

      SequentialAnimation {
        id: playSweep
        PropertyAction { target: sweep; property: "opacity"; value: 1 }
        NumberAnimation {
          target: sweep; property: "x"
          from: -Style.space(90); to: gameRow.width
          duration: 850; easing.type: Easing.InOutQuad
        }
        PropertyAction { target: sweep; property: "opacity"; value: 0 }
      }

      // Somebody scored: the whole row lifts for a moment. Louder than the
      // sweep on purpose — this is the event the widget exists for.
      Rectangle {
        id: scoreWash
        anchors.fill: parent
        radius: Style.cornerRadius
        color: root.accent
        opacity: 0
      }

      SequentialAnimation {
        id: scorePulse
        NumberAnimation { target: scoreWash; property: "opacity"; from: 0.0; to: 0.22; duration: 160; easing.type: Easing.OutCubic }
        NumberAnimation { target: scoreWash; property: "opacity"; from: 0.22; to: 0.0; duration: 900; easing.type: Easing.InCubic }
      }

      // A spine in your club's own colour, off to the side where it cannot
      // make text unreadable on any theme.
      //
      // Only a club you follow gets one. A followed league also makes a game
      // "yours", but marking all ten of its fixtures identically makes the one
      // you actually care about impossible to pick out.
      //
      // Two halves rather than one bar, because following both clubs in a
      // derby is the one case a single colour cannot answer "which of these is
      // mine?". With one club followed both halves take the same colour and it
      // reads as a single spine.
      Column {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: Style.space(5)
        anchors.bottomMargin: Style.space(5)
        width: Math.max(2, Style.space(3))
        visible: row && row.followedByTeam

        readonly property var set: service ? Model.followSet(service.follows) : ({})
        readonly property bool awayMine: gameRow.game
          && Model.isFollowedTeam(set, gameRow.game.league, gameRow.game.away.abbr)
        readonly property bool homeMine: gameRow.game
          && Model.isFollowedTeam(set, gameRow.game.league, gameRow.game.home.abbr)
        readonly property bool both: awayMine && homeMine

        Repeater {
          model: gameRow.game ? [gameRow.game.away, gameRow.game.home] : []
          Rectangle {
            required property var modelData
            required property int index
            width: parent.width
            height: parent.height / 2
            // Rounded at the outer ends only, so a split spine still reads as
            // one object rather than two floating pills.
            radius: parent.both ? 0 : parent.width / 2
            color: {
              var team = parent.both
                ? modelData
                : (parent.homeMine ? gameRow.game.home : gameRow.game.away)
              // Two thirds of clubs have a near-black primary that would be
              // invisible here; teamAccent falls back to the club's own bright
              // alternate before giving up.
              var picked = Model.teamAccent(team, root.panelBackgroundHex)
              return picked !== "" ? picked : root.foreground
            }
          }
        }
      }

      // Hairline between games in the same section. Not under the last one:
      // the section heading below already separates them.
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(8)
        height: 1
        visible: row && row.lastInGroup !== true
        color: root.divider
      }

      Item {
        id: gameBody
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(8)
        implicitHeight: teamStack.implicitHeight

        readonly property real statusWidth: Style.space(104)

        Column {
          id: teamStack
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.rightMargin: gameBody.statusWidth
          spacing: Style.space(6)

          Repeater {
            // Away first, then home — the order every scoreboard uses, and the
            // order the "AWAY @ HOME" name reads in.
            model: gameRow.game ? [
              { side: "away", team: gameRow.game.away },
              { side: "home", team: gameRow.game.home }
            ] : []

            Item {
              required property var modelData
              width: teamStack.width
              implicitHeight: Math.max(crest.height, teamName.implicitHeight, scoreText.implicitHeight)

              readonly property bool ahead: gameRow.leader === modelData.side
              readonly property bool won: gameRow.winner === modelData.side
              readonly property bool lost: gameRow.winner !== "" && gameRow.winner !== modelData.side
              // Before anything has happened neither team is faded; once it
              // has, the team that is behind recedes.
              readonly property bool faded: gameRow.token === "upcoming" ? false
                : (gameRow.winner !== "" ? lost : (gameRow.leader !== "" && !ahead))

              TeamCrest {
                id: crest
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                crestSize: Style.space(21)
                source: modelData.team.logo
                abbr: modelData.team.abbr
                accent: {
                  var picked = Model.teamAccent(modelData.team, root.panelBackgroundHex)
                  return picked !== "" ? picked : "transparent"
                }
                foreground: root.foreground
                fontFamily: root.fontFamily
                dimmed: parent.faded
              }

              Text {
                id: teamAbbr
                anchors.left: crest.right
                anchors.leftMargin: Style.space(9)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(42)
                text: modelData.team.abbr
                color: parent.faded ? root.dim : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: parent.ahead || parent.won
                Behavior on color { ColorAnimation { duration: 200 } }
              }

              Text {
                id: teamName
                anchors.left: teamAbbr.right
                anchors.right: scoreText.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.team.name
                elide: Text.ElideRight
                color: parent.faded ? root.fainter : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // Winner mark. A caret rather than a colour, so the result is
              // still readable in a monochrome theme or to a colour-blind eye.
              Text {
                id: wonMark
                anchors.right: scoreText.left
                anchors.rightMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                visible: parent.won
                text: "\u25b8"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: scoreText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                width: Style.space(30)
                visible: gameRow.token !== "upcoming"
                text: Model.fmtScore(modelData.team.score)
                color: parent.faded ? root.dim : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: parent.ahead || parent.won
                Behavior on color { ColorAnimation { duration: 200 } }
              }

              // Start time replaces the score column before the game exists as
              // a contest, so the column is never a pair of meaningless zeroes.
              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: gameRow.token === "upcoming" && modelData.side === "away"
                text: gameRow.game && gameRow.game.startUtc
                  ? Model.clockTime(gameRow.game.startUtc, service ? service.formatTime : null) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            width: teamStack.width
            visible: text !== ""
            elide: Text.ElideRight
            topPadding: Style.space(5)
            text: {
              if (!gameRow.game) return ""
              var parts = []
              if (root.route === "" || root.route.indexOf("game:") === 0)
                parts.push(Leagues.displayName(gameRow.game.league))
              var situation = (service && service.showSituation) ? row.situation : ""
              if (situation !== "") parts.push(situation)
              else if (gameRow.token === "upcoming" && gameRow.game.away.record !== "")
                parts.push(gameRow.game.away.record + "  ·  " + gameRow.game.home.record)
              else if (gameRow.game.venue !== "" && gameRow.token === "final")
                parts.push(gameRow.game.venue)
              return parts.join("   ·   ")
            }
            color: root.fainter
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Status column: the state indicator, the provider's own wording, and
        // for a live game a coarse sense of how far through it is.
        Column {
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: Style.space(2)
          width: gameBody.statusWidth - Style.space(8)
          spacing: Style.space(5)

          Row {
            anchors.right: parent.right
            spacing: Style.space(6)

            Indicators {
              anchors.verticalCenter: parent.verticalCenter
              token: gameRow.token
              foreground: root.foreground
              accent: root.accent
              urgent: root.urgent
              size: Style.space(7)
              // Nothing animates behind a closed panel.
              animate: root.opened
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: row ? row.status : ""
              horizontalAlignment: Text.AlignRight
              color: gameRow.isLive ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: gameRow.isLive
            }
          }

          Rectangle {
            anchors.right: parent.right
            visible: gameRow.isLive && Model.progressFraction(gameRow.game) > 0
            width: Style.space(58)
            height: Math.max(1, Style.space(2))
            radius: height / 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: parent.width * Model.progressFraction(gameRow.game)
              radius: parent.radius
              color: root.accent
              Behavior on width { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
            }
          }
        }
      }
    }
  }

  Component {
    id: leagueComponent
    RowBase {
      implicitHeight: leagueRow.implicitHeight + Style.space(16)

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(6)
        height: 1
        visible: row && row.lastInGroup !== true
        color: root.divider
      }

      Item {
        id: leagueRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(6)
        implicitHeight: Math.max(leagueCrest.height, leagueLabel.implicitHeight)

        TeamCrest {
          id: leagueCrest
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          crestSize: Style.space(21)
          source: row ? Leagues.logoFor(row.league) : ""
          abbr: row ? Leagues.shortLabel(row.league) : ""
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
        Text {
          id: leagueLabel
          anchors.left: leagueCrest.right
          anchors.leftMargin: Style.space(10)
          anchors.right: leagueHint.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: {
            if (!row) return ""
            var label = String(row.label || "")
            return row.followed ? label + "  ★" : label
          }
          elide: Text.ElideRight
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row && row.followed === true
        }
        Text {
          id: leagueHint
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: row ? String(row.hint || "") : ""
          color: row && String(row.hint || "").indexOf("today") >= 0 ? root.accent : root.fainter
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // Racing, golf, tennis and MMA: one event with a field, not two sides. The
  // event is the headline and the top of the leaderboard is the score.
  Component {
    id: eventComponent
    RowBase {
      id: eventRow
      implicitHeight: eventBody.implicitHeight + Style.space(20)

      readonly property var game: row ? row.game : null
      readonly property string token: game ? Model.stateToken(game) : "none"

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(8)
        height: 1
        visible: row && row.lastInGroup !== true
        color: root.divider
      }

      Item {
        id: eventBody
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(8)
        implicitHeight: eventColumn.implicitHeight

        readonly property real statusWidth: Style.space(104)

        Column {
          id: eventColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.rightMargin: eventBody.statusWidth
          spacing: Style.space(4)

          Text {
            width: parent.width
            text: eventRow.game ? eventRow.game.name : ""
            elide: Text.ElideRight
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            visible: text !== ""
            elide: Text.ElideRight
            text: {
              if (!eventRow.game) return ""
              var parts = []
              if (root.route === "") parts.push(Leagues.displayName(eventRow.game.league))
              if (eventRow.game.sessionLabel !== "") parts.push(eventRow.game.sessionLabel)
              if (eventRow.game.venue !== "") parts.push(eventRow.game.venue)
              return parts.join("   ·   ")
            }
            color: root.fainter
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // The top of the field. Absent before an event starts, which is the
          // honest thing to show rather than a row of dashes.
          Repeater {
            model: eventRow.game ? eventRow.game.leaders : []
            Item {
              required property var modelData
              required property int index
              width: eventColumn.width
              implicitHeight: entrantName.implicitHeight + Style.space(2)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(18)
                text: String(modelData.order)
                color: root.fainter
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                id: entrantName
                anchors.left: parent.left
                anchors.leftMargin: Style.space(18)
                anchors.right: entrantDetail.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.name || "")
                elide: Text.ElideRight
                color: index === 0 || modelData.followed ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: index === 0 || modelData.followed === true
              }
              Text {
                id: entrantDetail
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.detail || "")
                color: index === 0 || modelData.followed ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: index === 0 || modelData.followed === true
              }
            }
          }
        }

        Row {
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(6)

          Indicators {
            anchors.verticalCenter: parent.verticalCenter
            token: eventRow.token
            foreground: root.foreground
            accent: root.accent
            urgent: root.urgent
            size: Style.space(7)
            animate: root.opened
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: row ? row.status : ""
            color: eventRow.token === "live" ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: eventRow.token === "live"
          }
        }
      }
    }
  }

  Component {
    id: simpleComponent
    RowBase {
      implicitHeight: simpleRow.implicitHeight + Style.space(12)
      Item {
        id: simpleRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(6)
        implicitHeight: Math.max(simpleLabel.implicitHeight, simpleHint.implicitHeight)

        Text {
          id: simpleLabel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          // The star trails the name. Leading it shifted every character right
          // the moment you followed something, so the row you just acted on
          // jumped sideways under the cursor.
          text: {
            if (!row) return ""
            var label = String(row.label || "")
            return row.kind === "team" && row.followed ? label + "  ★" : label
          }
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          id: simpleHint
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: row ? String(row.hint || "") : ""
          elide: Text.ElideLeft
          width: Math.min(implicitWidth, parent.width * 0.5)
          color: root.fainter
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  Component {
    id: standingComponent
    RowBase {
      implicitHeight: standingRow.implicitHeight + Style.space(13)

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(6)
        height: 1
        visible: row && row.lastInGroup !== true
        color: root.divider
      }

      Item {
        id: standingRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(6)
        implicitHeight: standingName.implicitHeight

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(26)
          text: row ? String(row.rank) : ""
          color: root.fainter
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        TeamCrest {
          id: standingCrest
          anchors.left: parent.left
          anchors.leftMargin: Style.space(24)
          anchors.verticalCenter: parent.verticalCenter
          crestSize: Style.space(17)
          source: row ? row.entry.logo : ""
          abbr: row ? row.entry.abbr : ""
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
        Text {
          id: standingName
          anchors.left: standingCrest.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: row ? (row.entry.name + (row.followed ? "  ★" : "")) : ""
          elide: Text.ElideRight
          width: parent.width - Style.space(150)
          // Top of the table gets the emphasis; everyone else is reference.
          color: row && row.rank === 1 ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: row && row.rank === 1
        }
        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: row ? (row.record + (row.entry.streak ? "   " + row.entry.streak : "")) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  Component {
    id: playComponent
    RowBase {
      implicitHeight: playText.implicitHeight + Style.space(10)
      Text {
        id: playText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(6)
        text: {
          if (!row || !row.play) return ""
          var play = row.play
          var when = play.periodLabel !== "" ? play.periodLabel
            : (play.period !== null ? "P" + play.period : "")
          if (play.clock !== "") when = when === "" ? play.clock : (when + " " + play.clock)
          var head = play.teamAbbr ? (play.teamAbbr + "  ") : ""
          var tail = (play.away !== null && play.home !== null) ? ("   " + play.away + "-" + play.home) : ""
          return head + play.text + tail + (when !== "" ? "   ·   " + when : "")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  Component {
    id: leaderComponent
    RowBase {
      implicitHeight: leaderText.implicitHeight + Style.space(10)
      Text {
        id: leaderText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(6)
        text: row && row.leader
          ? (row.leader.teamAbbr + "  " + row.leader.athlete + "  ·  " + row.leader.value)
          : ""
        elide: Text.ElideRight
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Component {
    id: linescoreComponent
    RowBase {
      implicitHeight: linescoreColumn.implicitHeight + Style.space(12)
      Column {
        id: linescoreColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(6)
        spacing: Style.space(3)

        // Period numbers. Without them the grid is a row of unlabelled digits.
        Row {
          spacing: Style.space(6)
          Item { width: Style.space(44); height: 1 }
          Repeater {
            model: {
              if (!row || !row.game) return 0
              return Math.max(row.game.home.lines.length, row.game.away.lines.length)
            }
            Text {
              required property int index
              width: Style.space(20)
              horizontalAlignment: Text.AlignRight
              text: String(index + 1)
              color: root.fainter
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          Text {
            width: Style.space(30)
            horizontalAlignment: Text.AlignRight
            text: "T"
            color: root.fainter
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Repeater {
          model: row && row.game ? [row.game.away, row.game.home] : []
          Row {
            required property var modelData
            spacing: Style.space(6)
            Text {
              width: Style.space(44)
              text: modelData.abbr
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Repeater {
              model: modelData.lines
              Text {
                required property var modelData
                width: Style.space(20)
                horizontalAlignment: Text.AlignRight
                text: modelData === null ? "-" : String(modelData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
            Text {
              width: Style.space(30)
              horizontalAlignment: Text.AlignRight
              text: Model.fmtScore(modelData.score)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
