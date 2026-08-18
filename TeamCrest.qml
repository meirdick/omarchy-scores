import QtQuick
import qs.Commons

// A team's badge. The real logo when it loads, and a coloured monogram when it
// does not — which is not an edge case: soccer clubs outside the big leagues
// often have no mark on the CDN, and a row with a hole in it looks broken.
Item {
  id: root

  property string source: ""
  property string abbr: ""
  property color accent: "transparent"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real crestSize: 20
  property bool dimmed: false

  implicitWidth: crestSize
  implicitHeight: crestSize
  width: crestSize
  height: crestSize
  opacity: dimmed ? 0.45 : 1.0

  Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

  readonly property bool usable: source !== "" && logo.status === Image.Ready

  // The monogram. Sits underneath so there is never a frame with nothing in
  // the slot while the logo is still in flight.
  Rectangle {
    anchors.fill: parent
    radius: width / 2
    visible: !root.usable
    color: root.accent !== "transparent" && String(root.accent) !== "#00000000"
      ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.30)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
    border.width: 1
    border.color: root.accent !== "transparent" && String(root.accent) !== "#00000000"
      ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.75)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.28)

    Text {
      anchors.centerIn: parent
      // Two characters is all that fits legibly in a 20px circle.
      text: String(root.abbr).slice(0, 2)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Math.max(7, Math.round(root.crestSize * 0.42))
      font.bold: true
    }
  }

  Image {
    id: logo
    anchors.fill: parent
    source: root.source
    // ESPN only publishes the 500px mark, so downscale on decode rather than
    // holding a 500px texture per team for a 20px slot.
    sourceSize.width: Math.round(root.crestSize * 2)
    sourceSize.height: Math.round(root.crestSize * 2)
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    cache: true
    smooth: true
    visible: root.usable
    opacity: root.usable ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
  }
}
