import QtQuick
import qs.Commons

// The plugin's mark: a pitch seen from above — touchline, halfway line, centre
// circle. Drawn rather than set in a Nerd Font, because the shell's font family
// is the fontconfig alias "monospace", which Qt does not reliably resolve to
// the concrete Nerd Font; a private-use codepoint then renders as whatever
// fallback owns it, which is how this first shipped an integral sign.
//
// It replaces an earlier scoreboard drawing that had a boxy outline, two inner
// panels and a pair of feet, and consequently read as a suitcase.
Item {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property real markSize: Style.font.display
  // The centre spot fills and breathes while something is in progress.
  property bool live: false

  implicitWidth: markSize
  implicitHeight: markSize
  width: markSize
  height: markSize

  readonly property real stroke: Math.max(1, Math.round(markSize * 0.07))
  // A real pitch is wider than it is tall; 3:2 keeps that without the shape
  // becoming a letterbox at bar sizes.
  readonly property real pitchWidth: markSize
  readonly property real pitchHeight: Math.round(markSize * 0.68)

  Rectangle {
    id: pitch
    anchors.centerIn: parent
    width: root.pitchWidth
    height: root.pitchHeight
    radius: Math.max(1, Math.round(root.markSize * 0.09))
    color: "transparent"
    border.width: root.stroke
    border.color: root.foreground

    // Halfway line. Drawn full height so it reads as a division even when the
    // centre circle is only a few pixels across.
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: root.stroke
      color: root.foreground
    }

    // Centre circle, and the one thing that carries state: hollow when nothing
    // is on, filled and breathing in the accent while a game is live.
    Rectangle {
      id: centreSpot
      anchors.centerIn: parent
      width: Math.max(root.stroke * 2 + 2, Math.round(root.pitchHeight * 0.42))
      height: width
      radius: width / 2
      color: root.live ? root.accent : "transparent"
      border.width: root.stroke
      border.color: root.live ? root.accent : root.foreground

      SequentialAnimation on opacity {
        running: root.live
        loops: Animation.Infinite
        NumberAnimation { from: 1.0; to: 0.45; duration: 1100; easing.type: Easing.InOutSine }
        NumberAnimation { from: 0.45; to: 1.0; duration: 1100; easing.type: Easing.InOutSine }
      }
    }
  }
}
