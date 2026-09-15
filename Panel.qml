import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell.Io
import qs.Commons
import qs.Ui
import "services"
import "components"

Panel {
  id: root
  moduleName: "io.github.abdelzaherabdelgwad.zlaunchpad"
  ipcTarget: "io.github.abdelzaherabdelgwad.zlaunchpad"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color muted: Qt.darker(foreground, 1.4)
  readonly property color okColor: "#55d878"
  readonly property color dirtyColor: "#e5a33c"
  readonly property color activeIconColor: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool showGitStatus: setting("showGitStatus", true) !== false
  readonly property bool showPaths: setting("showPaths", true) !== false

  // Path of the directory whose command drawer is open, "" when closed.
  // Keyed by path, not index, so a refresh or an unpin cannot move the drawer
  // onto a different directory.
  property string expandedPath: ""

  // Drawer editor drafts live here rather than inside the delegate: a Git
  // refresh replaces the model and rebuilds delegates, which would otherwise
  // wipe whatever is half-typed.
  property string draftLabel: ""
  property string draftCommand: ""
  property bool draftHold: false
  property string draftDefaultLabel: ""
  property string draftDefaultCommand: ""
  property bool draftDefaultHold: false
  // PanelKeyCatcher takes keys before descendants, so every inline editor
  // registers its focus here and the catcher stands down while one is active.
  property int editingCount: 0
  property bool presetsOpen: false
  property bool settingsOpen: false
  property bool recordingKeybind: false
  property Item forgeScreenshotTarget: content

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      editingCount = 0
      data_.refreshAll()
      Qt.callLater(function() { digitCatcher.forceActiveFocus() })
    } else {
      dirField.text = ""
      data_.clearSuggestions()
      expandedPath = ""
    }
  }

  DataService { id: data_; settings: root.settings }

  // Placeholders a command may use. Each one expands to a shell variable, and
  // the values are passed as positional arguments rather than pasted into the
  // script, so a directory name with spaces or quotes stays one literal word.
  readonly property var tokens: [
    { token: "{name}", variable: "$LP_NAME", hint: "Display name of the directory in Launchpad" },
    { token: "{path}", variable: "$LP_PATH", hint: "Full path, e.g. /home/you/Code/api" },
    { token: "{dir}", variable: "$LP_PATH", hint: "Same as {path}" },
    { token: "{basename}", variable: "$LP_BASENAME", hint: "Last path segment, e.g. api" },
    { token: "{parent}", variable: "$LP_PARENT", hint: "Parent directory" },
    { token: "{branch}", variable: "$LP_BRANCH", hint: "Current Git branch (empty for non-Git)" }
  ]

  // Insert a placeholder at the field's cursor. insert() does not emit
  // textEdited, so the caller copies the new text back into its draft.
  function insertToken(field, token) {
    if (!field) return
    field.insert(field.cursorPosition, token)
    field.forceActiveFocus()
  }

  function expandTokens(command) {
    var body = String(command || "")
    for (var i = 0; i < tokens.length; i++)
      body = body.split(tokens[i].token).join("\"" + tokens[i].variable + "\"")
    return body
  }

  // Every command runs in a terminal opened at the directory. An empty
  // command just opens the terminal. keepOpen replaces the command process
  // with a login shell afterwards so short commands stay readable.
  function run(entry, command, keepOpen) {
    if (!entry) return
    var argv = ["xdg-terminal-exec", "--dir=" + entry.path]
    var body = expandTokens(command).trim()
    if (body !== "") {
      var script = "LP_NAME=$1; LP_PATH=$2; LP_BASENAME=$3; LP_PARENT=$4; LP_BRANCH=$5\n"
        + body
        + (keepOpen ? "\nexec \"$SHELL\" -l" : "")
      var path = String(entry.path)
      argv = argv.concat(["--", "bash", "-lc", script, "launchpad",
        String(entry.name || ""),
        path,
        path.slice(path.lastIndexOf("/") + 1),
        path.slice(0, path.lastIndexOf("/")) || "/",
        String(entry.branch || "")])
    }
    Util.execArgv(argv)
    root.close()
  }

  function runDefault(index) {
    if (index < 0 || index >= data_.entries.length) return
    var entry = data_.entries[index]
    root.run(entry, entry.defaultCommand.command, entry.defaultCommand.keepOpen)
  }

  function toggleDrawer(path) {
    if (expandedPath === path) {
      expandedPath = ""
      return
    }
    expandedPath = path
    draftLabel = ""
    draftCommand = ""
    draftHold = false
    var index = data_.indexOfPath(path)
    if (index >= 0) {
      data_.select(index)
      var current = data_.entries[index].defaultCommand
      draftDefaultLabel = current.label
      draftDefaultCommand = current.command
      draftDefaultHold = current.keepOpen === true
    }
  }

  function refresh() { data_.refreshAll() }

  // Qt key event -> Hyprland key name. Only the keys Hyprland names the same
  // way are accepted; anything else is rejected rather than guessed at.
  function hyprKeyName(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F12) return "F" + (key - Qt.Key_F1 + 1)
    switch (key) {
      case Qt.Key_Space: return "SPACE"
      case Qt.Key_Return:
      case Qt.Key_Enter: return "RETURN"
      case Qt.Key_Tab: return "TAB"
      case Qt.Key_Backspace: return "BACKSPACE"
      case Qt.Key_Comma: return "COMMA"
      case Qt.Key_Period: return "PERIOD"
      case Qt.Key_Slash: return "SLASH"
      case Qt.Key_Semicolon: return "SEMICOLON"
      case Qt.Key_Minus: return "MINUS"
      case Qt.Key_Equal: return "EQUAL"
      case Qt.Key_Backslash: return "BACKSLASH"
      case Qt.Key_BracketLeft: return "BRACKETLEFT"
      case Qt.Key_BracketRight: return "BRACKETRIGHT"
      case Qt.Key_Left: return "LEFT"
      case Qt.Key_Right: return "RIGHT"
      case Qt.Key_Up: return "UP"
      case Qt.Key_Down: return "DOWN"
      case Qt.Key_Home: return "HOME"
      case Qt.Key_End: return "END"
    }
    return ""
  }

  function hyprModifiers(modifiers) {
    var mods = []
    if (modifiers & Qt.MetaModifier) mods.push("SUPER")
    if (modifiers & Qt.ControlModifier) mods.push("CTRL")
    if (modifiers & Qt.AltModifier) mods.push("ALT")
    if (modifiers & Qt.ShiftModifier) mods.push("SHIFT")
    return mods
  }

  function captureKeybind(event) {
    if (event.key === Qt.Key_Escape) {
      recordingKeybind = false
      data_.notice = "Keybind unchanged."
      return true
    }
    // A modifier on its own is the user still assembling the chord.
    if (event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R
      || event.key === Qt.Key_Control || event.key === Qt.Key_Alt
      || event.key === Qt.Key_Shift || event.key === Qt.Key_Meta) return true
    var name = hyprKeyName(event.key)
    if (name === "") {
      data_.notice = "That key cannot be bound. Try a letter, digit or F-key."
      return true
    }
    var mods = hyprModifiers(event.modifiers)
    if (mods.length === 0) {
      data_.notice = "Hold at least one modifier (SUPER, CTRL, ALT, SHIFT)."
      return true
    }
    recordingKeybind = false
    data_.setKeybind(mods.join(" ") + ", " + name)
    return true
  }

  // 1 is always the default command; 2-9 are the drawer commands in order, so
  // the number beside a command in the drawer is the key that runs it.
  function runNumberedCommand(digit) {
    var entry = data_.selectedEntry
    if (!entry) return
    if (digit === 1) {
      root.run(entry, entry.defaultCommand.command, entry.defaultCommand.keepOpen)
      return
    }
    var index = digit - 2
    if (index < 0 || index >= entry.commands.length) return
    root.run(entry, entry.commands[index].command, entry.commands[index].keepOpen)
  }

  // Key number shown next to a drawer command; "" past the ninth.
  function commandKeyLabel(index) {
    return index + 2 <= 9 ? String(index + 2) : ""
  }

  // Ctrl+1-9 run the shared presets, in the selected directory.
  function runNumberedPreset(digit) {
    var entry = data_.selectedEntry
    if (!entry) return
    var index = digit - 1
    if (index < 0 || index >= data_.presets.length) return
    root.run(entry, data_.presets[index].command, data_.presets[index].keepOpen)
  }

  function presetKeyLabel(index) {
    return index + 1 <= 9 ? "^" + (index + 1) : ""
  }

  // Full fzf picker in a terminal. The selection is handed back over IPC, so
  // the panel does not have to stay open while the user browses.
  function pickWithFzf() {
    var script = ""
      + "if command -v fd >/dev/null; then\n"
      + "  finder=(fd --type d --hidden --absolute-path --follow --exclude .git --exclude node_modules . \"$HOME\")\n"
      + "else\n"
      + "  finder=(find \"$HOME\" -maxdepth 6 -type d -not -path '*/.git/*' -not -path '*/node_modules/*')\n"
      + "fi\n"
      + "selection=$(\"${finder[@]}\" | fzf --prompt='Pin directory> ' --height=100% --border --preview 'ls -la {}') || exit 0\n"
      + "[ -n \"$selection\" ] && omarchy-shell io.github.abdelzaherabdelgwad.zlaunchpad add \"$selection\"\n"
    Util.execArgv(["xdg-terminal-exec", "--title=Launchpad · pick a directory",
      "--app-id=launchpad-picker", "--", "bash", "-lc", script])
    root.close()
  }

  // Ui.Button has no eliding, so trim long default-command labels for the
  // header button and leave the full text in its tooltip.
  function shortLabel(label) {
    var value = String(label || "")
    return value.length > 16 ? value.slice(0, 15) + "…" : value
  }

  // Clicking a preset in the manager loads it back into the editor below.
  function draftPresetFrom(index) {
    if (index < 0 || index >= data_.presets.length) return
    var preset = data_.presets[index]
    presetLabel.text = preset.label
    presetCommand.text = preset.command
    presetHoldButton.checked = preset.keepOpen === true
  }

  function pinSuggestion(path) {
    data_.add(path)
    dirField.text = ""
    data_.clearSuggestions()
  }

  function noteEditFocus(active) {
    editingCount = Math.max(0, editingCount + (active ? 1 : -1))
  }

  function moveSelection(delta) {
    if (data_.entries.length === 0) return
    var next = data_.selectedIndex + delta
    if (next < 0) next = 0
    if (next > data_.entries.length - 1) next = data_.entries.length - 1
    data_.select(next)
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { data_.refreshAll() }
    function add(path: string): void { data_.add(path) }
    function remove(path: string): void { data_.removeByPath(path) }
    function list(): string { return data_.describe() }
    function keybind(value: string): string {
      data_.setKeybind(value)
      return data_.prefs.keybind
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.opened
    tooltipText: "zLaunchpad"
    // The SVG is drawn in white and recolored to the bar foreground, so the
    // icon follows the theme the way a glyph would.
    iconComponent: Component {
      Item {
        Image {
          id: iconSource
          anchors.fill: parent
          source: Qt.resolvedUrl("assets/icon.svg")
          sourceSize.width: width * 2
          sourceSize.height: height * 2
          fillMode: Image.PreserveAspectFit
          smooth: true
          mipmap: true
          visible: false
        }
        MultiEffect {
          anchors.fill: parent
          source: iconSource
          colorization: 1.0
          // Red while the panel is open, theme foreground otherwise.
          colorizationColor: root.opened ? root.activeIconColor : root.barForeground
          Behavior on colorizationColor { ColorAnimation { duration: 120 } }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) data_.refreshAll()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: popout
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: digitCatcher
    contentWidth: popout.fittedContentWidth(Style.space(560))
    contentHeight: popout.fittedContentHeight(Math.min(content.implicitHeight, Style.space(760)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingCount > 0 || root.recordingKeybind
      onCloseRequested: root.close()
      onActivateRequested: root.runDefault(data_.selectedIndex)
      onMoveRequested: function(dx, dy) { root.moveSelection(dy) }
      onTextKey: function(text) {
        if (text === "r") data_.refreshAll()
        else if (text === "K") data_.move(data_.selectedIndex, -1)
        else if (text === "J") data_.move(data_.selectedIndex, 1)
      }

      // Holds focus so digits arrive here first, with their modifiers intact —
      // PanelKeyCatcher's textKey signal carries no modifier state, so Ctrl+1
      // and 1 would be indistinguishable there. Anything else is left
      // unaccepted and propagates up to the catcher as usual.
      Item {
        id: digitCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          // A QML Keys handler accepts by default, which would swallow every
          // other key; explicitly decline so j/k, r, Esc and the rest keep
          // propagating up to PanelKeyCatcher.
          event.accepted = false
          if (root.recordingKeybind || root.editingCount > 0) return
          if (event.key < Qt.Key_1 || event.key > Qt.Key_9) return
          var digit = event.key - Qt.Key_0
          if (event.modifiers & Qt.ControlModifier) root.runNumberedPreset(digit)
          else root.runNumberedCommand(digit)
          event.accepted = true
        }
      }

      // Grabs keys ahead of everything else while a chord is being recorded.
      Item {
        id: keybindRecorder
        anchors.fill: parent
        focus: root.recordingKeybind
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (!root.recordingKeybind) return
          event.accepted = root.captureKeybind(event)
        }
        onActiveFocusChanged: if (!activeFocus && root.recordingKeybind) root.recordingKeybind = false
      }

      // Keeps Git state current while the panel sits open, without stomping on
      // a half-typed command (refreshes skip the model when nothing changed).
      Timer {
        running: root.opened && data_.prefs.autoRefresh && root.editingCount === 0
        interval: Math.max(5, data_.prefs.autoRefreshSec) * 1000
        repeat: true
        onTriggered: data_.refreshAll()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: panelFlick.width
          spacing: Style.space(12)

          // --- header ---------------------------------------------------
          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: "zLaunchpad"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Item { Layout.fillWidth: true }
            Text {
              text: data_.statusLabel
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            PanelActionButton {
              iconText: "󰑐"
              tooltipText: "Refresh Git state"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: data_.refreshAll()
            }
            PanelActionButton {
              iconText: "󰅖"
              tooltipText: "Close"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.close()
            }
          }

          PanelSeparator { foreground: root.foreground }

          // --- add a directory ------------------------------------------
          PanelSectionHeader {
            width: parent.width
            text: "ADD A DIRECTORY"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: dirField
              width: parent.width - addButton.width - fzfButton.width - parent.spacing * 2
              placeholderText: "~/Work  ·  or type to search"
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              onActiveFocusChanged: root.noteEditFocus(activeFocus)
              Component.onDestruction: if (activeFocus) root.noteEditFocus(false)
              onTextChanged: {
                if (text.trim().length < 2) data_.clearSuggestions()
                else suggestTimer.restart()
              }
              Keys.onReturnPressed: addButton.clicked()
            }
            Button {
              id: fzfButton
              text: "󰍉"
              tooltipText: "Search directories with fzf in a terminal"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              fontFamily: root.fontFamily
              onClicked: root.pickWithFzf()
            }
            Button {
              id: addButton
              text: "Add"
              foreground: root.foreground
              accent: root.accent
              active: true
              fontFamily: root.fontFamily
              horizontalPadding: Style.space(18)
              onClicked: {
                data_.add(dirField.text)
                dirField.text = ""
                data_.clearSuggestions()
              }
            }
          }

          // Inline fuzzy results, refreshed a moment after typing stops.
          Timer {
            id: suggestTimer
            interval: 180
            onTriggered: data_.suggest(dirField.text)
          }

          Column {
            visible: data_.suggestions.length > 0
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: data_.suggestions

              delegate: ListRow {
                required property var modelData
                width: content.width
                text: modelData
                tooltipText: modelData
                elideMode: Text.ElideMiddle
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.pinSuggestion(modelData)
              }
            }
          }

          Text {
            width: parent.width
            text: data_.notice !== "" ? data_.notice
              : "Any directory works. Git directories also show branch and status."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: data_.state === "error"
            width: parent.width
            text: data_.lastError
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: data_.state === "empty"
            width: parent.width
            text: "No directories pinned yet."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          // --- directories ----------------------------------------------
          PanelSectionHeader {
            visible: data_.entries.length > 0
            width: parent.width
            text: "DIRECTORIES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: data_.entries

            delegate: Rectangle {
              id: entryCard
              required property int index
              required property var modelData
              readonly property bool drawerOpen: root.expandedPath === modelData.path

              width: content.width
              implicitHeight: entryColumn.implicitHeight + Style.space(18)
              radius: Style.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.025)
              border.width: Style.normalBorderWidth
              // Selected directory gets a green outline; the rest stay neutral.
              border.color: index === data_.selectedIndex ? root.okColor
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)

              Column {
                id: entryColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(9)
                spacing: Style.space(8)

                // Row: identity, git state, default-command button, actions.
                // Anchored rather than laid out: the buttons are pinned to the
                // right edge and the identity column takes exactly what is
                // left, so a long path or branch name can never push them out
                // of the panel.
                Item {
                  width: parent.width
                  implicitHeight: Math.max(identity.implicitHeight, actions.implicitHeight)

                  Rectangle {
                    id: statusDot
                    width: Style.space(9)
                    height: Style.space(9)
                    radius: width / 2
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    color: !entryCard.modelData.isGit ? Qt.darker(root.foreground, 2.0)
                      : entryCard.modelData.dirty ? root.dirtyColor : root.okColor
                  }

                  Row {
                    id: actions
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)

                    Button {
                      text: root.shortLabel(entryCard.modelData.defaultCommand.label)
                      tooltipText: entryCard.modelData.defaultCommand.command !== ""
                        ? entryCard.modelData.defaultCommand.command
                        : "Open a terminal in " + entryCard.modelData.path
                      foreground: root.foreground
                      accent: root.accent
                      active: true
                      fontFamily: root.fontFamily
                      onClicked: root.runDefault(entryCard.index)
                    }
                    PanelActionButton {
                      iconText: entryCard.drawerOpen ? "󰅀" : "󰅂"
                      tooltipText: "Commands"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: root.toggleDrawer(entryCard.modelData.path)
                    }
                    PanelActionButton {
                      iconText: "󰩹"
                      tooltipText: "Unpin directory"
                      foreground: root.foreground
                      hoverColor: bar ? bar.urgent : Color.urgent
                      fontFamily: root.fontFamily
                      onClicked: {
                        if (root.expandedPath === entryCard.modelData.path) root.expandedPath = ""
                        data_.removeAt(data_.indexOfPath(entryCard.modelData.path))
                      }
                    }
                  }

                  Column {
                    id: identity
                    anchors.left: statusDot.right
                    anchors.leftMargin: Style.space(8)
                    anchors.right: actions.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)

                    Text {
                      width: parent.width
                      text: entryCard.modelData.name
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.subtitle
                      font.bold: true
                      elide: Text.ElideRight
                    }
                    Text {
                      visible: root.showPaths
                      width: parent.width
                      text: entryCard.modelData.path
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideMiddle
                    }
                    Item {
                      visible: root.showGitStatus && entryCard.modelData.isGit
                      width: parent.width
                      implicitHeight: branchLabel.implicitHeight

                      Text {
                        id: dirtyLabel
                        anchors.right: parent.right
                        text: entryCard.modelData.dirty ? "Uncommitted changes" : "Clean"
                        color: entryCard.modelData.dirty ? root.dirtyColor : root.okColor
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      Text {
                        id: branchLabel
                        anchors.left: parent.left
                        anchors.right: dirtyLabel.left
                        anchors.rightMargin: Style.space(8)
                        text: "󰘬 " + (entryCard.modelData.branch || "unknown")
                        color: root.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }
                    }
                  }
                }

                // Drawer: command list, preset copies, editors.
                Column {
                  visible: entryCard.drawerOpen
                  width: parent.width
                  spacing: Style.space(8)

                  PanelSeparator { width: parent.width; foreground: root.foreground }

                  Item {
                    width: parent.width
                    implicitHeight: orderButtons.implicitHeight

                    Text {
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      text: "POSITION " + (data_.indexOfPath(entryCard.modelData.path) + 1)
                        + " OF " + data_.entries.length
                      color: Qt.darker(root.foreground, 1.4)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                    Row {
                      id: orderButtons
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(4)

                      PanelActionButton {
                        iconText: "󰁝"
                        tooltipText: "Move up (Shift+K)"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: data_.move(data_.indexOfPath(entryCard.modelData.path), -1)
                      }
                      PanelActionButton {
                        iconText: "󰁅"
                        tooltipText: "Move down (Shift+J)"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: data_.move(data_.indexOfPath(entryCard.modelData.path), 1)
                      }
                    }
                  }

                  PanelSectionHeader {
                    width: parent.width
                    text: "COMMANDS"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  Text {
                    visible: entryCard.modelData.commands.length === 0
                    width: parent.width
                    text: "No extra commands yet."
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Repeater {
                    model: entryCard.modelData.commands

                    delegate: Item {
                      required property int index
                      required property var modelData
                      width: entryColumn.width
                      implicitHeight: Math.max(commandRow.implicitHeight, commandActions.implicitHeight)

                      Row {
                        id: commandActions
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(4)

                        PanelActionButton {
                          iconText: "󰐃"
                          tooltipText: "Make this the default command"
                          foreground: root.foreground
                          fontFamily: root.fontFamily
                          onClicked: data_.promoteCommand(data_.indexOfPath(entryCard.modelData.path), index)
                        }
                        PanelActionButton {
                          iconText: "󰅖"
                          tooltipText: "Remove command"
                          foreground: root.foreground
                          hoverColor: bar ? bar.urgent : Color.urgent
                          fontFamily: root.fontFamily
                          onClicked: data_.removeCommand(data_.indexOfPath(entryCard.modelData.path), index)
                        }
                      }
                      ListRow {
                        id: commandRow
                        anchors.left: parent.left
                        anchors.right: commandActions.left
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        keyLabel: root.commandKeyLabel(index)
                        text: modelData.label
                        detail: modelData.command
                        tooltipText: modelData.command
                        foreground: root.foreground
                        accent: root.accent
                        fontFamily: root.fontFamily
                        onClicked: root.run(entryCard.modelData, modelData.command, modelData.keepOpen)
                      }
                    }
                  }

                  // Add a command to this directory.
                  RowLayout {
                    width: parent.width
                    spacing: Style.space(6)

                    TextField {
                      id: newLabel
                      Layout.preferredWidth: Style.space(110)
                      placeholderText: "Label"
                      text: root.draftLabel
                      foreground: root.foreground
                      accent: root.accent
                      font.family: root.fontFamily
                      onActiveFocusChanged: root.noteEditFocus(activeFocus)
                      Component.onDestruction: if (activeFocus) root.noteEditFocus(false)
                      onTextEdited: root.draftLabel = text
                    }
                    TextField {
                      id: newCommand
                      Layout.fillWidth: true
                      Layout.preferredWidth: 1
                      placeholderText: "nvim .   ·   dx {name}"
                      text: root.draftCommand
                      foreground: root.foreground
                      accent: root.accent
                      font.family: root.fontFamily
                      onActiveFocusChanged: root.noteEditFocus(activeFocus)
                      Component.onDestruction: if (activeFocus) root.noteEditFocus(false)
                      onTextEdited: root.draftCommand = text
                      Keys.onReturnPressed: addCommandButton.clicked()
                    }
                    Button {
                      id: keepOpenButton
                      text: "Hold"
                      tooltipText: "Keep the terminal open with a shell after the command ends"
                      foreground: root.foreground
                      accent: root.accent
                      bordered: true
                      selected: root.draftHold
                      fontFamily: root.fontFamily
                      onClicked: root.draftHold = !root.draftHold
                    }
                    Button {
                      id: addCommandButton
                      text: "Add"
                      foreground: root.foreground
                      accent: root.accent
                      active: true
                      fontFamily: root.fontFamily
                      onClicked: {
                        data_.addCommand(data_.indexOfPath(entryCard.modelData.path),
                          root.draftLabel, root.draftCommand, root.draftHold)
                        root.draftLabel = ""
                        root.draftCommand = ""
                        root.draftHold = false
                      }
                    }
                  }

                  TokenBar {
                    width: parent.width
                    tokens: root.tokens
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onPicked: function(token) {
                      root.insertToken(newCommand, token)
                      root.draftCommand = newCommand.text
                    }
                  }

                  // Edit the default command of this directory.
                  PanelSectionHeader {
                    width: parent.width
                    text: "DEFAULT COMMAND"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  RowLayout {
                    width: parent.width
                    spacing: Style.space(6)

                    TextField {
                      id: defaultLabel
                      Layout.preferredWidth: Style.space(110)
                      placeholderText: "Label"
                      text: root.draftDefaultLabel
                      foreground: root.foreground
                      accent: root.accent
                      font.family: root.fontFamily
                      onActiveFocusChanged: root.noteEditFocus(activeFocus)
                      Component.onDestruction: if (activeFocus) root.noteEditFocus(false)
                      onTextEdited: root.draftDefaultLabel = text
                    }
                    TextField {
                      id: defaultCommand
                      Layout.fillWidth: true
                      Layout.preferredWidth: 1
                      placeholderText: "empty opens a plain terminal · {name} {path} {branch}"
                      text: root.draftDefaultCommand
                      foreground: root.foreground
                      accent: root.accent
                      font.family: root.fontFamily
                      onActiveFocusChanged: root.noteEditFocus(activeFocus)
                      Component.onDestruction: if (activeFocus) root.noteEditFocus(false)
                      onTextEdited: root.draftDefaultCommand = text
                      Keys.onReturnPressed: saveDefaultButton.clicked()
                    }
                    Button {
                      id: defaultHoldButton
                      text: "Hold"
                      tooltipText: "Keep the terminal open with a shell after the command ends"
                      foreground: root.foreground
                      accent: root.accent
                      bordered: true
                      selected: root.draftDefaultHold
                      fontFamily: root.fontFamily
                      onClicked: root.draftDefaultHold = !root.draftDefaultHold
                    }
                    Button {
                      id: saveDefaultButton
                      text: "Save"
                      foreground: root.foreground
                      accent: root.accent
                      active: true
                      fontFamily: root.fontFamily
                      onClicked: data_.setDefaultCommand(data_.indexOfPath(entryCard.modelData.path),
                        root.draftDefaultLabel, root.draftDefaultCommand, root.draftDefaultHold)
                    }
                  }

                  TokenBar {
                    width: parent.width
                    tokens: root.tokens
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onPicked: function(token) {
                      root.insertToken(defaultCommand, token)
                      root.draftDefaultCommand = defaultCommand.text
                    }
                  }

                  // Shared presets, runnable here or copied into this directory.
                  PanelSectionHeader {
                    visible: data_.presets.length > 0
                    width: parent.width
                    text: "PRESETS"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  Repeater {
                    model: data_.presets

                    delegate: Item {
                      required property int index
                      required property var modelData
                      width: entryColumn.width
                      implicitHeight: Math.max(presetRow.implicitHeight, presetCopy.implicitHeight)

                      PanelActionButton {
                        id: presetCopy
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        iconText: "󰐕"
                        tooltipText: "Copy preset into this directory"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: data_.copyPresetTo(data_.indexOfPath(entryCard.modelData.path), index)
                      }
                      ListRow {
                        id: presetRow
                        anchors.left: parent.left
                        anchors.right: presetCopy.left
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        keyLabel: root.presetKeyLabel(index)
                        text: modelData.label
                        detail: modelData.command
                        tooltipText: modelData.command
                        foreground: root.foreground
                        accent: root.accent
                        dimmed: true
                        fontFamily: root.fontFamily
                        onClicked: root.run(entryCard.modelData, modelData.command, modelData.keepOpen)
                      }
                    }
                  }
                }
              }

              TapHandler {
                onTapped: data_.select(entryCard.index)
              }
              HoverHandler { cursorShape: Qt.PointingHandCursor }
            }
          }

          // --- shared presets manager -----------------------------------
          PanelSeparator { foreground: root.foreground }

          RowLayout {
            width: parent.width
            PanelSectionHeader {
              Layout.fillWidth: true
              text: "SHARED PRESETS (" + data_.presets.length + ")"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            PanelActionButton {
              iconText: root.presetsOpen ? "󰅀" : "󰅂"
              tooltipText: "Manage shared presets"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.presetsOpen = !root.presetsOpen
            }
          }

          Column {
            visible: root.presetsOpen
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: "Presets appear inside every directory drawer and can be copied into one."
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: data_.presets

              delegate: Item {
                required property int index
                required property var modelData
                width: content.width
                implicitHeight: Math.max(presetManagerRow.implicitHeight, presetRemove.implicitHeight)

                PanelActionButton {
                  id: presetRemove
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰅖"
                  tooltipText: "Remove preset"
                  foreground: root.foreground
                  hoverColor: bar ? bar.urgent : Color.urgent
                  fontFamily: root.fontFamily
                  onClicked: data_.removePreset(index)
                }
                ListRow {
                  id: presetManagerRow
                  keyLabel: root.presetKeyLabel(index)
                  anchors.left: parent.left
                  anchors.right: presetRemove.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.label
                  detail: modelData.command + (modelData.keepOpen ? "  · hold" : "")
                  tooltipText: modelData.command
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.draftPresetFrom(index)
                }
              }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: presetLabel
                Layout.preferredWidth: Style.space(110)
                placeholderText: "Label"
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                onActiveFocusChanged: root.noteEditFocus(activeFocus)
                Component.onDestruction: if (activeFocus) root.noteEditFocus(false)
              }
              TextField {
                id: presetCommand
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                placeholderText: "lazygit   ·   dx {name}"
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                onActiveFocusChanged: root.noteEditFocus(activeFocus)
                Component.onDestruction: if (activeFocus) root.noteEditFocus(false)
                Keys.onReturnPressed: addPresetButton.clicked()
              }
              Button {
                id: presetHoldButton
                property bool checked: false
                text: "Hold"
                tooltipText: "Keep the terminal open with a shell after the command ends"
                foreground: root.foreground
                accent: root.accent
                bordered: true
                selected: checked
                fontFamily: root.fontFamily
                onClicked: checked = !checked
              }
              Button {
                id: addPresetButton
                text: "Add"
                foreground: root.foreground
                accent: root.accent
                active: true
                fontFamily: root.fontFamily
                onClicked: {
                  data_.addPreset(presetLabel.text, presetCommand.text, presetHoldButton.checked)
                  presetLabel.text = ""
                  presetCommand.text = ""
                  presetHoldButton.checked = false
                }
              }
            }

            TokenBar {
              width: parent.width
              tokens: root.tokens
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onPicked: function(token) { root.insertToken(presetCommand, token) }
            }
          }

          PanelSeparator { foreground: root.foreground }

          RowLayout {
            width: parent.width
            PanelSectionHeader {
              Layout.fillWidth: true
              text: "SETTINGS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            PanelActionButton {
              iconText: root.settingsOpen ? "󰅀" : "󰅂"
              tooltipText: "Keybind and refresh settings"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.settingsOpen = !root.settingsOpen
            }
          }

          Column {
            visible: root.settingsOpen
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: keybindButtons.implicitHeight

              Column {
                anchors.left: parent.left
                anchors.right: keybindButtons.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: "Global keybind"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  width: parent.width
                  text: root.recordingKeybind ? "Press the combination… (Esc cancels)"
                    : (data_.prefs.keybind !== "" ? data_.prefs.keybind : "Not bound")
                  color: root.recordingKeybind ? root.accent : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              Row {
                id: keybindButtons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Button {
                  text: root.recordingKeybind ? "Recording…" : "Record"
                  tooltipText: "Bind a key combination to toggle Launchpad"
                  foreground: root.foreground
                  accent: root.accent
                  active: root.recordingKeybind
                  bordered: !root.recordingKeybind
                  fontFamily: root.fontFamily
                  onClicked: {
                    root.recordingKeybind = !root.recordingKeybind
                    if (root.recordingKeybind) {
                      data_.notice = "Press the combination to bind."
                      Qt.callLater(function() { keybindRecorder.forceActiveFocus() })
                    } else {
                      digitCatcher.forceActiveFocus()
                    }
                  }
                }
                Button {
                  text: "Clear"
                  enabled: data_.prefs.keybind !== ""
                  foreground: root.muted
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: data_.setKeybind("")
                }
              }
            }

            Text {
              width: parent.width
              text: "Written to ~/.local/state/omarchy/toggles/hypr/zlaunchpad.lua, "
                + "which Hyprland's Lua config already loads, then applied with hyprctl reload."
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Item {
              width: parent.width
              implicitHeight: refreshControls.implicitHeight

              Column {
                anchors.left: parent.left
                anchors.right: refreshControls.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: "Auto-refresh while open"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  width: parent.width
                  text: data_.prefs.autoRefresh
                    ? "Every " + data_.prefs.autoRefreshSec + "s"
                    : "Off — press r to refresh"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
              Row {
                id: refreshControls
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Button {
                  text: "−"
                  enabled: data_.prefs.autoRefreshSec > 5
                  foreground: root.foreground
                  accent: root.accent
                  bordered: true
                  fontFamily: root.fontFamily
                  onClicked: data_.setPref("autoRefreshSec", data_.prefs.autoRefreshSec - 5)
                }
                Button {
                  text: "+"
                  enabled: data_.prefs.autoRefreshSec < 300
                  foreground: root.foreground
                  accent: root.accent
                  bordered: true
                  fontFamily: root.fontFamily
                  onClicked: data_.setPref("autoRefreshSec", data_.prefs.autoRefreshSec + 5)
                }
                Button {
                  text: data_.prefs.autoRefresh ? "On" : "Off"
                  foreground: root.foreground
                  accent: root.accent
                  bordered: true
                  selected: data_.prefs.autoRefresh
                  fontFamily: root.fontFamily
                  onClicked: data_.setPref("autoRefresh", !data_.prefs.autoRefresh)
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // Flow, not a row of fillWidth labels: the hints wrap onto a second
          // line instead of overlapping when the panel is narrow.
          Flow {
            width: parent.width
            spacing: Style.space(14)

            Repeater {
              model: [
                "r  Refresh",
                "Enter / 1  Default",
                "2-9  Command",
                "Ctrl+1-9  Preset",
                "Shift+J/K  Move",
                "Esc  Close"
              ]
              delegate: Text {
                required property var modelData
                textFormat: Text.PlainText
                text: modelData
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }
}
