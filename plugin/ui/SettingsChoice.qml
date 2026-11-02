import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

ColumnLayout {
  id: root
  property string label: ""
  property var options: []
  property var value
  signal chosen(var value)
  spacing: 4

  SettingsLabel { text: root.label; Layout.fillWidth: true }
  ComboBox {
    Layout.fillWidth: true
    model: root.options
    textRole: "label"
    currentIndex: {
      for (var i = 0; i < root.options.length; i++)
        if (root.options[i].value === root.value) return i
      return -1
    }
    Accessible.name: root.label
    onActivated: root.chosen(root.options[currentIndex].value)
  }
}
