import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Leagues.js" as Leagues
import "Providers.js" as Providers
import "Model.js" as Model

// The bar slot. Owns the service, renders the one-line score, and hands the
// panel everything it needs. The panel is loaded lazily but kept alive, so the
// first open is instant and the poll loop does not restart with it.
BarWidget {
  id: root
  moduleName: "meirdick.scores"


  Service {
    id: service
    settings: root.settings
    onScoreFlash: function(gameId) {
      // Flash whatever the bar is currently showing, not every game that
      // scored — the bar only has room for one.
      if (service.barInfo.game && service.barInfo.game.id === gameId) flashTimer.restart()
    }
  }

  property bool flashing: false
  Timer {
    id: flashTimer
    interval: 1400
    onTriggered: root.flashing = false
    onRunningChanged: if (running) root.flashing = true
  }

  readonly property var barInfo: service.barInfo
  readonly property bool hasError: service.lastError !== "" && service.games.length === 0
  readonly property bool iconOnly: service.barFormat === "icon" || barInfo.mode === "idle"

  readonly property string barText: {
    // Icon states render a drawn mark instead of text — see the ScoresMark
    // below. A Nerd Font codepoint cannot be used here: the shell's font family
    // is the fontconfig alias "monospace", which Qt does not reliably resolve
    // to the concrete Nerd Font, and the private-use codepoint then renders as
    // whatever fallback owns it. It came out as an integral sign.
    if (hasError || iconOnly) return ""
    var text = barInfo.text
    if (text === "") return ""
    // With several live games the bar is a rotation, so say which one of how
    // many you are looking at — otherwise a changing score looks like a bug.
    if (barInfo.count > 1) text += "  " + (barInfo.index + 1) + "/" + barInfo.count
    return text
  }

  readonly property string tooltip: {
    if (service.lastError !== "") return "Scores — " + service.lastError
    if (service.follows.length === 0) return "Scores — no teams followed yet"
    var game = barInfo.game
    if (!game) return "Scores — nothing scheduled"
    var status = Model.statusLabel(game, service.nowMs, service.formatTime)
    var line = game.away.fullName + " at " + game.home.fullName
    return Leagues.displayName(game.league) + " · " + line + (status ? " · " + status : "")
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root, not on the nested panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function refresh() { service.refresh() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = service
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    tooltipText: root.tooltip
    // The widget always holds its slot: hasVisualContent is normally derived
    // from `text`, and the icon states have none.
    hasVisualContent: true
    labelVisible: root.barText !== ""
    fixedWidth: root.barText === "" ? Style.bar.iconSlot : -1
    // Urgent for a score that just landed and for a stuck fetch. Both are
    // "look here", and the bar only has the one colour for that.
    active: root.flashing || root.hasError
    activeColor: root.bar ? root.bar.urgent : Color.urgent
    // Idle and error states recede behind the rest of the bar; a live score
    // does not.
    dimmed: root.iconOnly && !root.flashing && !root.hasError
    // Vertical bars cannot fit a score line, so they rotate the label the way
    // every other text widget does.
    textRotation: root.vertical ? 90 : 0

    onPressed: function(code) {
      if (code === Qt.RightButton) service.refresh()
      else if (code === Qt.MiddleButton) {
        if (root.barInfo.game) service.openUrl(root.barInfo.game.detailUrl)
      } else root.toggle()
    }

    // Scroll cycles the rotation manually when several games are live.
    onWheelMoved: function(delta) {
      if (root.barInfo.count < 2) return
      service.rotateIndex = service.rotateIndex + (delta > 0 ? 1 : -1)
      if (service.rotateIndex < 0) service.rotateIndex = root.barInfo.count - 1
    }

    ScoresMark {
      anchors.centerIn: parent
      visible: root.barText === ""
      markSize: Style.space(13)
      foreground: root.hasError
        ? (root.bar ? root.bar.urgent : Color.urgent)
        : Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.5)
      accent: Color.accent
      // Nothing followed is playing, so nothing is ticking.
      live: false
    }
  }

  Component.onCompleted: {
    // Non-library JS gets one context per QML document, so each file that
    // imports Model or Providers hands them the league catalog itself.
    Model.useLeagues(Leagues)
    Providers.useLeagues(Leagues)
  }
}
