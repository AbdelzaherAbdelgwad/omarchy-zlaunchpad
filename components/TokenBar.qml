import QtQuick
import qs.Commons
import qs.Ui

// Row of placeholder chips shown under a command field. Clicking one emits
// `picked` so the caller can insert it at the cursor of whichever field the
// bar belongs to.
Flow {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property var tokens: []

  signal picked(string token)

  spacing: Style.space(4)

  Repeater {
    model: root.tokens

    delegate: Button {
      required property var modelData
      text: modelData.token
      tooltipText: modelData.hint
      foreground: root.foreground
      accent: root.accent
      bordered: true
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      horizontalPadding: Style.space(7)
      verticalPadding: Style.space(3)
      onClicked: root.picked(modelData.token)
    }
  }
}
