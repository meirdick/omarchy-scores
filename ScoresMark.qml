import QtQuick
import qs.Commons

// The plugin's own mark: a scoreboard with two score panels, drawn from
// primitives. Built rather than set in a Nerd Font because the shell's font
// family is the fontconfig alias "monospace", which Qt does not always resolve
// to the concrete Nerd Font — a private-use codepoint then renders as whatever
// fallback happens to own it, which is how this first shipped an integral sign.
Item {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property real markSize: Style.font.display
  // Lights up when something is actually in progress.
  property bool live: false

  implicitWidth: markSize
  implicitHeight: markSize
  width: markSize
  height: markSize

  Rectangle {
    id: body
    anchors.centerIn: parent
    width: root.markSize
    height: Math.round(root.markSize * 0.78)
    radius: Math.max(2, Math.round(root.markSize * 0.14))
    color: "transparent"
    border.width: Math.max(1, Math.round(root.markSize * 0.075))
    border.color: root.foreground

    Row {
      anchors.centerIn: parent
      spacing: Math.max(2, Math.round(root.markSize * 0.09))

      Repeater {
        model: 2
        Rectangle {
          required property int index
          width: Math.round(root.markSize * 0.26)
          height: Math.round(root.markSize * 0.36)
          radius: Math.max(1, Math.round(root.markSize * 0.05))
          color: root.live && index === 1 ? root.accent : root.foreground
          opacity: root.live && index === 1 ? 1.0 : 0.55

          // The right-hand panel ticks over while a game is live: the mark
          // itself says whether anything is happening.
          SequentialAnimation on opacity {
            running: root.live && index === 1
            loops: Animation.Infinite
            NumberAnimation { from: 1.0; to: 0.35; duration: 1100; easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.35; to: 1.0; duration: 1100; easing.type: Easing.InOutSine }
          }
        }
      }
    }
  }

  // Feet, so the mark reads as a standing scoreboard rather than a text box.
  Row {
    anchors.top: body.bottom
    anchors.horizontalCenter: body.horizontalCenter
    spacing: Math.round(root.markSize * 0.34)
    Repeater {
      model: 2
      Rectangle {
        width: Math.max(1, Math.round(root.markSize * 0.075))
        height: Math.round(root.markSize * 0.14)
        color: root.foreground
        opacity: 0.75
      }
    }
  }
}
