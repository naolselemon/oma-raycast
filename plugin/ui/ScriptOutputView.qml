import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

Item {
  id: view
  required property var backend
  property string runId: ""
  property var run: null
  property var lines: []
  property string errorText: ""
  property bool followOutput: true
  readonly property var service: backend.scriptCommandsService
  readonly property color foreground: Commons.Color.menu.text
  readonly property color backgroundColor: Commons.Color.menu.background

  function refresh() {
    if (!runId) return
    try {
      run = service.publicRun(runId)
      var result = [], line = []
      run.segments.forEach(function(segment) {
        var parts = segment.text.split("\n")
        for (var i = 0; i < parts.length; i++) {
          if (parts[i]) line.push({text: parts[i], color: segment.color, bold: segment.bold})
          if (i < parts.length - 1) { result.push(line); line = [] }
        }
      })
      result.push(line)
      lines = result.slice(-2000)
      if (result.length > 2000) run.truncated = true
      if (followOutput) Qt.callLater(function() { output.contentY = Math.max(0, output.contentHeight - output.height) })
    } catch (error) { errorText = String(error.message || error) }
  }
  function cancel() {
    try { service.cancel(runId); refresh() } catch (error) { errorText = String(error.message || error) }
  }
  function rerun() {
    try { runId = service.rerun(runId).runId; errorText = ""; followOutput = true; refresh() } catch (error) { errorText = String(error.message || error) }
  }
  function copyOutput() {
    if (!run || copyProcess.running) return
    copyProcess.content = run.segments.map(function(segment) { return segment.text }).join("")
    copyProcess.stdinEnabled = true
    copyProcess.running = true
  }
  function handleKey(event) {
    var control = !!(event.modifiers & Qt.ControlModifier)
    if (control && event.key === Qt.Key_C) {
      if (event.modifiers & Qt.ShiftModifier || !run || !run.running) copyOutput()
      else cancel()
    } else if (control && event.key === Qt.Key_R) rerun()
    else if (event.key === Qt.Key_Up) { followOutput = false; output.contentY = Math.max(0, output.contentY - 30) }
    else if (event.key === Qt.Key_Down) { followOutput = false; output.contentY = Math.min(Math.max(0, output.contentHeight - output.height), output.contentY + 30) }
    else if (event.key === Qt.Key_PageUp) { followOutput = false; output.contentY = Math.max(0, output.contentY - output.height) }
    else if (event.key === Qt.Key_PageDown) { followOutput = false; output.contentY = Math.min(Math.max(0, output.contentHeight - output.height), output.contentY + output.height) }
    else if (event.key === Qt.Key_Home) { followOutput = false; output.contentY = 0 }
    else if (event.key === Qt.Key_End) { followOutput = true; output.contentY = Math.max(0, output.contentHeight - output.height) }
    else return false
    event.accepted = true
    return true
  }
  onRunIdChanged: refresh()
  Component.onCompleted: refresh()
  Connections {
    target: view.service
    function onRunChanged(id) { if (id === view.runId && !refreshDelay.running) refreshDelay.start() }
  }
  Timer { id: refreshDelay; interval: 60; onTriggered: view.refresh() }
  Shortcut { sequence: "Ctrl+C"; enabled: view.visible && !!view.run && view.run.running; onActivated: view.cancel() }
  Shortcut { sequence: "Ctrl+R"; enabled: view.visible && !!view.run && !view.run.running; onActivated: view.rerun() }

  Process {
    id: copyProcess
    property string content: ""
    command: ["wl-copy"]
    onStarted: { write(content); stdinEnabled = false }
    onExited: function(code) { if (code !== 0) view.errorText = "Could not copy script output" }
  }
  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Style.space(12)
    spacing: Style.space(8)
    RowLayout {
      Layout.fillWidth: true
      Text {
        Layout.fillWidth: true
        text: view.errorText || (view.run ? view.run.message : "Loading output…")
        textFormat: Text.PlainText
        color: view.foreground
        elide: Text.ElideRight
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
      }
      Button {
        visible: !!view.run && view.run.running
        text: "Cancel (Ctrl+C)"
        onClicked: view.cancel()
        contentItem: Text { text: parent.text; textFormat: Text.PlainText; color: view.foreground; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
        background: Rectangle { color: Commons.Color.menu.selectedBackground; radius: Style.cornerRadius }
      }
      Button {
        visible: !!view.run && !view.run.running
        text: "Run Again (Ctrl+R)"
        onClicked: view.rerun()
        contentItem: Text { text: parent.text; textFormat: Text.PlainText; color: view.foreground; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
        background: Rectangle { color: Commons.Color.menu.selectedBackground; radius: Style.cornerRadius }
      }
    }
    Text {
      visible: !!view.run && view.run.truncated
      text: "Earlier output omitted (128 KiB / 2,000 displayed lines)."
      textFormat: Text.PlainText
      color: view.foreground
      opacity: 0.65
      font.pixelSize: Style.font.bodySmall
    }
    Flickable {
      id: output
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      contentWidth: Math.max(width, outputLines.implicitWidth)
      contentHeight: outputLines.implicitHeight
      onMovementStarted: view.followOutput = false
      onMovementEnded: view.followOutput = contentY + height >= contentHeight - 10
      ScrollBar.vertical: ScrollBar {}
      ScrollBar.horizontal: ScrollBar {}
      Column {
        id: outputLines
        Repeater {
          model: view.lines
          Row {
            required property var modelData
            height: Math.max(Style.font.body + Style.space(5), implicitHeight)
            Repeater {
              model: parent.modelData
              Text {
                required property var modelData
                text: modelData.text
                textFormat: Text.PlainText
                color: modelData.color || view.foreground
                font.family: "monospace"
                font.pixelSize: Style.font.body
                font.bold: modelData.bold
              }
            }
          }
        }
      }
    }
    Text {
      Layout.fillWidth: true
      text: "Ctrl+Shift+C copies output · Ctrl+C cancels · Ctrl+R runs again"
      textFormat: Text.PlainText
      color: view.foreground
      opacity: 0.55
      font.pixelSize: Style.font.bodySmall
    }
  }
}
