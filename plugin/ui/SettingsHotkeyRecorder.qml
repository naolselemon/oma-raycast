import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../core/Hotkeys.js" as Hotkeys

ColumnLayout {
  id: root
  property var hotkey: null
  property bool recording: false
  property string error: ""
  signal recorded(var hotkey)
  spacing: 4

  function cancel() { recording = false; error = "" }

  RowLayout {
    Layout.fillWidth: true
    Button {
      id: recordButton
      Layout.fillWidth: true
      text: root.recording ? qsTr("Press a shortcut…") : (root.hotkey ? Hotkeys.format(root.hotkey) : qsTr("Record Hotkey"))
      Accessible.name: qsTr("Record command hotkey")
      contentItem: SettingsLabel {
        text: recordButton.text
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
      onClicked: {
        root.error = ""
        root.recording = !root.recording
        forceActiveFocus()
      }
      onActiveFocusChanged: { if (!activeFocus) root.recording = false }
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (!root.recording) return
        event.accepted = true
        if (event.isAutoRepeat) return
        if (event.key === Qt.Key_Escape && event.modifiers === Qt.NoModifier) {
          root.cancel()
          return
        }
        try {
          var value = Hotkeys.fromKeyEvent(event)
          if (!value) return
          root.recorded(value)
          root.recording = false
          root.error = ""
        } catch (error) {
          root.error = String(error.message || error)
        }
      }
      Keys.onReleased: function(event) { if (root.recording) event.accepted = true }
    }
    Button {
      text: qsTr("Clear")
      enabled: !!root.hotkey || root.recording
      onClicked: { root.cancel(); root.recorded(null) }
    }
    Button {
      visible: root.recording
      text: qsTr("Cancel")
      onClicked: root.cancel()
    }
  }
  SettingsLabel {
    Layout.fillWidth: true
    text: root.error || (root.recording ? qsTr("Escape cancels. Use a modifier with a key. Existing desktop shortcuts may be intercepted by Hyprland.") : qsTr("The shortcut is applied only when you save. Conflicts leave the existing binding unchanged."))
  }
}
