import QtQuick
import qs.Commons

// The one place the three lifecycle states get their visual language, so a
// game reads the same way in every surface that shows one.
//
//   upcoming  hollow ring, dim        — nothing has happened yet
//   live      filled dot, breathing   — happening now
//   final     flat bar, muted         — done
//   delayed   hollow ring, urgent     — should be happening and is not
//
// Drawn from primitives rather than glyphs: a Nerd Font codepoint that is
// missing renders as a blank box and looks like a layout bug, and these have
// to be legible at 6 pixels.
Item {
  id: root

  property string token: "upcoming"
  property color foreground: Color.foreground
  // Live is not an alarm. It gets the theme accent; `urgent` is kept for the
  // states that mean something is wrong — delayed, suspended, failing.
  property color accent: Color.accent
  property color urgent: Color.urgent
  property real size: 7
  // Motion is opt-out so a panel that is closed is not animating offscreen.
  property bool animate: true

  readonly property bool live: token === "live"
  readonly property bool delayed: token === "delayed"

  implicitWidth: size
  implicitHeight: size
  width: size
  height: size

  // Final: a flat bar, not a dot. A finished game is a horizontal line through
  // it, and the different silhouette is readable without relying on colour.
  Rectangle {
    visible: root.token === "final"
    anchors.centerIn: parent
    width: root.size
    height: Math.max(1, Math.round(root.size * 0.28))
    radius: height / 2
    color: Qt.darker(root.foreground, 2.0)
  }

  // Postponed or cancelled: an empty slot, kept so rows stay aligned.
  Item {
    visible: root.token === "off" || root.token === "none"
    anchors.fill: parent
  }

  // Upcoming and delayed: a ring. Nothing has happened inside it yet.
  Rectangle {
    visible: root.token === "upcoming" || root.delayed
    anchors.centerIn: parent
    width: root.size
    height: root.size
    radius: width / 2
    color: "transparent"
    border.width: Math.max(1, Math.round(root.size * 0.2))
    border.color: root.delayed ? root.urgent : Qt.darker(root.foreground, 1.9)

    SequentialAnimation on opacity {
      running: root.delayed && root.animate
      loops: Animation.Infinite
      NumberAnimation { from: 1.0; to: 0.35; duration: 900; easing.type: Easing.InOutSine }
      NumberAnimation { from: 0.35; to: 1.0; duration: 900; easing.type: Easing.InOutSine }
    }
  }

  // Live: a filled dot with a halo that breathes. The halo carries the motion
  // so the dot itself stays a fixed, readable size.
  Item {
    visible: root.live
    anchors.centerIn: parent
    width: root.size
    height: root.size

    Rectangle {
      id: halo
      anchors.centerIn: parent
      width: root.size * 2.1
      height: width
      radius: width / 2
      color: root.accent
      opacity: 0.0

      SequentialAnimation {
        running: root.live && root.animate
        loops: Animation.Infinite
        ParallelAnimation {
          NumberAnimation { target: halo; property: "opacity"; from: 0.30; to: 0.0; duration: 1600; easing.type: Easing.OutCubic }
          NumberAnimation { target: halo; property: "scale"; from: 0.55; to: 1.0; duration: 1600; easing.type: Easing.OutCubic }
        }
        PauseAnimation { duration: 260 }
      }
    }

    Rectangle {
      anchors.centerIn: parent
      width: root.size
      height: root.size
      radius: width / 2
      color: root.accent
    }
  }
}
