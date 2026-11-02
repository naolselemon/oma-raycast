import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import "../core/ScriptCommands.js" as Scripts

Window {
  id: window
  required property var backend
  transientParent: null
  width: Style.space(620)
  height: Style.space(650)
  minimumWidth: Style.space(460)
  minimumHeight: Style.space(500)
  title: "Create Script Command — oma-cast"
  color: Commons.Color.menu.background
  property var directories: []
  property string errorText: ""
  property string createdPath: ""
  property bool busy: false
  readonly property color foreground: Commons.Color.menu.text
  readonly property string language: languageField.currentIndex === 1 ? "python" : "bash"
  readonly property string mode: ["fullOutput", "compact", "silent", "inline"][modeField.currentIndex]

  function open(payload) {
    errorText = ""
    createdPath = ""
    var result = backend.callSync("settings.getScriptDirectories", {})
    if (result.ok) directories = result.data.directories
    else errorText = result.error
    if (payload && payload.title) titleField.text = payload.title
    visible = true
    raise()
    requestActivate()
    titleField.forceActiveFocus()
  }
  function suggestedFilename() {
    var name = titleField.text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "date-and-time"
    return name + (language === "python" ? ".py" : ".sh")
  }
  function specification() {
    return {title: titleField.text, filename: filenameField.text || suggestedFilename(), directory: directoryField.currentText, language: language, mode: mode}
  }
  function preview() {
    try { return Scripts.template({title: titleField.text || "Date and Time", language: language, mode: mode}) } catch (error) { return String(error.message || error) }
  }
  function save() {
    if (busy) return
    errorText = ""
    createdPath = ""
    busy = true
    backend.call("scriptCommands.create", specification()).then(function(result) {
      busy = false
      createdPath = result.path
    }, function(error) { busy = false; errorText = String(error.message || error) })
  }
  Shortcut { sequence: "Escape"; onActivated: window.close() }
  Shortcut { sequence: "Ctrl+Return"; enabled: window.visible && !window.busy; onActivated: window.save() }
  component Caption: Text {
    textFormat: Text.PlainText
    color: window.foreground
    font.family: Style.font.menuFamily
    font.pixelSize: Style.font.body
  }
  component Entry: TextField {
    color: window.foreground
    selectByMouse: true
    font.family: Style.font.menuFamily
    background: Rectangle { color: Util.alpha(window.foreground, 0.07); border.color: Util.alpha(window.foreground, 0.2); radius: Style.cornerRadius }
  }
  component Choice: ComboBox {
    contentItem: Text { text: parent.displayText; textFormat: Text.PlainText; color: window.foreground; verticalAlignment: Text.AlignVCenter; leftPadding: Style.space(8); rightPadding: Style.space(24); elide: Text.ElideRight }
    background: Rectangle { color: Util.alpha(window.foreground, 0.07); border.color: Util.alpha(window.foreground, 0.2); radius: Style.cornerRadius }
    delegate: ItemDelegate {
      required property var modelData
      width: ListView.view.width
      contentItem: Text { text: String(modelData); textFormat: Text.PlainText; color: window.foreground; elide: Text.ElideRight }
      background: Rectangle { color: parent.highlighted ? Commons.Color.menu.selectedBackground : Commons.Color.menu.background }
    }
  }
  component ActionButton: Button {
    contentItem: Text { text: parent.text; textFormat: Text.PlainText; color: window.foreground; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
    background: Rectangle { color: Commons.Color.menu.selectedBackground; opacity: parent.enabled ? 1 : 0.4; radius: Style.cornerRadius }
  }
  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Style.space(20)
    spacing: Style.space(10)
    Caption { text: "Create Script Command"; font.bold: true; font.pixelSize: Style.font.title }
    Caption {
      Layout.fillWidth: true
      text: "Create an executable date-and-time script, then open it in your editor to customize it. Only inline scripts run automatically."
      wrapMode: Text.WordWrap
      opacity: 0.7
    }
    GridLayout {
      Layout.fillWidth: true
      columns: 2
      columnSpacing: Style.space(12)
      rowSpacing: Style.space(8)
      Caption { text: "Title" }
      Entry { id: titleField; Layout.fillWidth: true; placeholderText: "Date and Time"; text: "Date and Time" }
      Caption { text: "Language" }
      Choice { id: languageField; Layout.fillWidth: true; model: ["Bash", "Python 3"] }
      Caption { text: "Mode" }
      Choice { id: modeField; Layout.fillWidth: true; model: ["Full Output", "Compact Toast", "Silent HUD", "Inline (every minute)"] }
      Caption { text: "Directory" }
      Choice { id: directoryField; Layout.fillWidth: true; model: window.directories }
      Caption { text: "Filename" }
      Entry { id: filenameField; Layout.fillWidth: true; placeholderText: window.suggestedFilename() }
    }
    Caption { text: "Template preview"; opacity: 0.7 }
    ScrollView {
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      TextArea {
        text: window.preview()
        textFormat: TextEdit.PlainText
        readOnly: true
        selectByMouse: true
        color: window.foreground
        font.family: "monospace"
        font.pixelSize: Style.font.bodySmall
        background: Rectangle { color: Util.alpha(window.foreground, 0.04) }
      }
    }
    Caption {
      Layout.fillWidth: true
      visible: !!window.errorText || !!window.createdPath
      text: window.errorText || "Created " + window.createdPath
      wrapMode: Text.Wrap
    }
    RowLayout {
      Layout.fillWidth: true
      Item { Layout.fillWidth: true }
      ActionButton { text: "Close"; onClicked: window.close() }
      ActionButton { text: "Open in Editor"; visible: !!window.createdPath; onClicked: Util.execArgv(["xdg-open", window.createdPath]) }
      ActionButton { text: window.busy ? "Creating…" : "Create (Ctrl+Enter)"; enabled: !window.busy && window.directories.length > 0; onClicked: window.save() }
    }
  }
}
