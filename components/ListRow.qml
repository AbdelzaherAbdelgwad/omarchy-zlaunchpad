import QtQuick
import QtQuick.Controls
import qs.Commons

// Clickable row whose label elides instead of growing. Ui.Button sizes itself
// to its text, so a long command label pushed the row's action buttons off the
// panel. Anchors — not a layout — decide the split here: the detail text takes
// at most 45% on the right, the label gets the rest and elides.
Rectangle {
  id: root

  property string text: ""
  property string detail: ""
  property string tooltipText: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.bodySmall
  property int elideMode: Text.ElideRight
  property bool dimmed: false
  // Number key that runs this row, shown as a small badge on the left.
  property string keyLabel: ""

  signal clicked()

  implicitHeight: label.implicitHeight + Style.space(12)
  radius: Style.cornerRadius
  color: mouseArea.containsMouse ? Style.hoverFillFor(foreground, accent) : "transparent"
  border.width: Style.normalBorderWidth
  border.color: Qt.rgba(foreground.r, foreground.g, foreground.b,
    mouseArea.containsMouse ? 0.3 : 0.16)

  Text {
    id: detailLabel
    visible: root.detail !== "" && root.width > Style.space(200)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, root.width * 0.42)
    horizontalAlignment: Text.AlignRight
    textFormat: Text.PlainText
    text: root.detail
    elide: Text.ElideRight
    color: Qt.darker(root.foreground, 1.5)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    id: keyBadge
    visible: root.keyLabel !== ""
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.keyLabel
    color: Qt.darker(root.foreground, 1.6)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    id: label
    anchors.left: keyBadge.visible ? keyBadge.right : parent.left
    anchors.leftMargin: Style.space(10)
    anchors.right: detailLabel.visible ? detailLabel.left : parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.text
    elide: root.elideMode
    color: root.dimmed ? Qt.darker(root.foreground, 1.35) : root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }

  ToolTip {
    visible: root.tooltipText !== "" && mouseArea.containsMouse
    text: root.tooltipText
    delay: 400
  }
}
