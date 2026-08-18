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
    if (route === "search" && filter !== "") return rows.length + " matching  ·  f to follow"
    if (route === "search") return "type to search  ·  f to follow  ·  esc to leave"
    if (filtering) return rows.length + " matching  ·  esc to leave search"
    if (route !== "") return "h or esc to go back"
    if (service.follows.length === 0) return "No teams followed — press / to search, f to follow"
    var live = 0, following = 0
    var set = Model.followSet(service.follows)
    var leagues = Model.leagueSet(service.followedLeagues)
    for (var i = 0; i < service.panelGames.length; i++) {
      if (service.panelGames[i].state === "LIVE") live++
      if (Model.isFollowedGame(set, service.panelGames[i], leagues)) following++
    }
    var parts = []
    if (live > 0) parts.push(live + " live")
    parts.push(following + " of yours")
    parts.push(service.games.length + " games")
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

  onRowsChanged: clampCursor()

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy !== 0 && rows.length > 0) {
      var next = cursorIndex
      for (var guard = 0; guard < rows.length; guard++) {
        next += dy > 0 ? 1 : -1
        if (next < 0 || next >= rows.length) return
        if (selectableAt(next)) { cursorIndex = next; list.positionViewAtIndex(next, ListView.Contain); return }
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
  }

  function pushRoute(next) {
    var remembered = {}
    for (var key in routeCursors) remembered[key] = routeCursors[key]
    remembered[route] = cursorIndex
    routeCursors = remembered
    route = next
    cursorIndex = Model.firstSelectable(rows)
    Qt.callLater(clampCursor)
    Qt.callLater(function() { list.positionViewAtBeginning() })
  }

  function goBack() {
    if (filtering) { stopFiltering(); return }
    if (route === "") { close(); return }
    if (service && route.indexOf("league:") === 0) service.browsingLeague = ""
    var previous = route.indexOf("standings:") === 0 ? "league:" + route.slice(10) : ""
    var restored = routeCursors[previous]
    route = previous
    cursorIndex = restored === undefined ? Model.firstSelectable(rows) : restored
    Qt.callLater(clampCursor)
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
      // still has to fill it.
      service.browsingLeague = row.league
      pushRoute("league:" + row.league)
      return
    }
    if (row.kind === "team") {
      service.followTeam(row.league, row.abbr)
      return
    }
    if (row.kind === "standing") return
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

  function open() {
    root.controller.show()
    if (service) service.panelOpen = true
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
    if (opened) {
      route = ""
      filter = ""
      filtering = false
      cursorIndex = Model.firstSelectable(rows)
      cursorActive = false
      // The view keeps its scroll offset between openings, so without this the
      // panel can reopen halfway down last night's card with the first section
      // clipped off the top.
      list.positionViewAtBeginning()
      Qt.callLater(function() {
        root.cursorIndex = Model.firstSelectable(root.rows)
        list.positionViewAtBeginning()
      })
    }
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
      root.open()
      var target = String(name || "")
      if (target.indexOf("standings:") === 0) root.service.loadStandings(target.slice(10))
      if (target === "search") {
        // Same end state as pressing "/": the field is focused and waiting,
        // rather than a search view with nowhere to type.
        root.startFiltering(true)
        return "route search"
      }
      root.pushRoute(target)
      return "route " + (target === "" ? "today" : target)
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
    if (route.indexOf("standings:") === 0) return "f follow  ·  x unfollow  ·  h back"
    if (route.indexOf("league:") === 0) return "l detail  ·  f follow  ·  o web  ·  h back"
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

      // Followed games carry a spine in the followed team's own colour. It is
      // the only place a team colour is load-bearing, and it is off to the side
      // where it cannot make text unreadable on any theme.
      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: Style.space(5)
        anchors.bottomMargin: Style.space(5)
        width: Math.max(2, Style.space(3))
        radius: width / 2
        visible: row && row.followed
        color: {
          if (!gameRow.game) return root.foreground
          var set = service ? Model.followSet(service.follows) : ({})
          var mine = Model.isFollowedTeam(set, gameRow.game.league, gameRow.game.home.abbr)
            ? gameRow.game.home : gameRow.game.away
          return mine.color !== "" ? mine.color : root.foreground
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
                accent: modelData.team.color !== "" ? modelData.team.color : "transparent"
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
            return (row.followed ? "★  " : "") + String(row.label || "")
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
          text: {
            if (!row) return ""
            var mark = row.kind === "team" ? (row.followed ? "★  " : "☆  ") : ""
            return mark + String(row.label || "")
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
          text: row ? ((row.followed ? "★ " : "") + row.entry.name) : ""
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
