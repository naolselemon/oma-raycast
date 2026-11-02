import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "../core/Hotkeys.js" as Hotkeys

// Settings is a normal toplevel, not a keyboard-exclusive launcher layer.
Item {
  id: root
  required property var backend
  property string page: "general"
  property var general: ({})
  property var commands: []
  property var fallbacks: []
  property var directories: []
  property var quicklinkPreferences: ({})
  property string selectedId: ""
  property var selectedCommand: null
  property string draftAlias: ""
  property var draftHotkey: null
  property bool draftEnabled: true
  property bool busy: false
  property string error: ""
  property string notice: ""
  property string commandFilter: ""
  readonly property var pages: [
    {id: "general", title: qsTr("General")},
    {id: "launcher", title: qsTr("Launcher")},
    {id: "keyboard", title: qsTr("Keyboard")},
    {id: "commands", title: qsTr("Commands / Extensions")},
    {id: "quicklinks", title: qsTr("Quicklinks")},
    {id: "scripts", title: qsTr("Script Commands")},
    {id: "about", title: qsTr("About")}
  ]
  readonly property var filteredCommands: {
    var needle = commandFilter.trim().toLowerCase()
    return commands.filter(function(command) {
      return !needle || [command.title, command.subtitle, command.type, command.kind,
        command.alias, command.id, command.hotkey ? Hotkeys.format(command.hotkey) : ""].join(" ").toLowerCase().indexOf(needle) !== -1
    })
  }
  readonly property bool dirty: !!selectedCommand &&
    (draftAlias !== String(selectedCommand.alias || "") || draftEnabled !== (selectedCommand.enabled !== false)
      || JSON.stringify(draftHotkey) !== JSON.stringify(selectedCommand.hotkey || null))

  function readSetting(method) {
    var response = backend.callSync(method, {})
    if (!response.ok) throw new Error(response.error)
    return response.data
  }

  function revealFocus(item) {
    if (!item) return
    var ancestor = item
    while (ancestor && ancestor !== settingsBody) ancestor = ancestor.parent
    if (!ancestor) return
    var top = item.mapToItem(settingsBody, 0, 0).y
    var flick = contentScroll.contentItem
    var margin = Style.space(12)
    if (top < flick.contentY + margin)
      flick.contentY = Math.max(0, top - margin)
    else if (top + item.height > flick.contentY + flick.height - margin)
      flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), top + item.height - flick.height + margin)
  }
  function refresh() {
    var failures = []

    function load(method, assign) {
      try { assign(root.readSetting(method)) }
      catch (failure) { failures.push(String(failure.message || failure)) }
    }
    load("settings.getGeneralSettings", function(value) { root.general = value })
    load("settings.getCommands", function(value) { root.commands = value })
    load("settings.getFallbackCommands", function(value) { root.fallbacks = value })
    load("settings.getScriptDirectories", function(value) { root.directories = value.directories })
    load("settings.getQuicklinkPreferences", function(value) { root.quicklinkPreferences = value })
    if (failures.length) root.error = failures.join("\n")
  }

  function selectCommand(id) {
    hotkeyRecorder.cancel()
    selectedId = id || ""
    selectedCommand = null
    for (var i = 0; i < commands.length; i++) {
      if (commands[i].id === selectedId) { selectedCommand = commands[i]; break }
    }
    draftAlias = selectedCommand ? String(selectedCommand.alias || "") : ""
    draftHotkey = selectedCommand ? selectedCommand.hotkey || null : null
    draftEnabled = !selectedCommand || selectedCommand.enabled !== false
    for (var j = 0; j < filteredCommands.length; j++) {
      if (filteredCommands[j].id === selectedId) { commandList.currentIndex = j; break }
    }
  }

  function changePage(id) {
    if (busy) return
    selectCommand("")
    page = id
    error = ""
    notice = ""
    contentScroll.contentItem.contentY = 0
  }

  function open(requestedPage, commandId) {
    error = ""
    notice = ""
    refresh()
    var route = String(requestedPage || "general").replace(/^\//, "")
    if (route === "extensions" || route === "shortcuts") route = "commands"
    if (route === "script-commands") route = "scripts"
    if (commandId) route = "commands"
    page = pages.some(function(item) { return item.id === route }) ? route : "general"
    commandFilter = ""
    commandSearch.text = ""
    selectCommand(commandId || "")
    settingsWindow.visible = true
    settingsWindow.raise()
    settingsWindow.requestActivate()
    Qt.callLater(function() {
      if (root.page === "commands" && root.selectedCommand) {
        commandList.positionViewAtIndex(commandList.currentIndex, ListView.Contain)
        if (commandList.currentItem) commandList.currentItem.forceActiveFocus()
      } else if (root.page === "commands") commandSearch.forceActiveFocus()
      else pageSearch.forceActiveFocus()
    })
  }

  function update(method, payload, onSuccess) {
    if (busy) return
    busy = true
    error = ""
    notice = ""
    backend.call(method, payload).then(function(result) {
      root.busy = false
      root.refresh()
      if (onSuccess) onSuccess(result)
      if (!root.error) root.notice = qsTr("Saved")
    }).catch(function(failure) {
      root.busy = false
      // Re-read persisted values instead of leaving an unsuccessful toggle displayed.
      root.refresh()
      root.error = String(failure.message || failure)
    })
  }

  function updateGeneral(key, value) {
    var patch = {}
    patch[key] = value
    update("settings.updateGeneralSettings", patch)
  }

  function saveCommand() {
    var id = selectedId
    var patch = {commandId: id}
    if (draftAlias !== String(selectedCommand.alias || "")) patch.alias = draftAlias
    if (draftEnabled !== (selectedCommand.enabled !== false)) patch.enabled = draftEnabled
    if (JSON.stringify(draftHotkey) !== JSON.stringify(selectedCommand.hotkey || null)) patch.hotkey = draftHotkey
    update("settings.updateCommandSettings", patch, function() { root.selectCommand(id) })
  }

  function setFallback(id, enabled) {
    var ids = fallbacks.filter(function(item) { return item.enabled && item.id !== id }).map(function(item) { return item.id })
    if (enabled) ids.push(id)
    update("settings.setFallbackCommands", {ids: ids})
  }

  function moveFallback(id, direction) {
    var ids = fallbacks.filter(function(item) { return item.enabled }).map(function(item) { return item.id })
    var index = ids.indexOf(id)
    var next = index + direction
    if (index < 0 || next < 0 || next >= ids.length) return
    var moved = ids.splice(index, 1)[0]
    ids.splice(next, 0, moved)
    update("settings.setFallbackCommands", {ids: ids})
  }

  function addDirectory() {
    var directory = directoryInput.text.trim()
    if (!directory) { error = qsTr("Enter an absolute directory path."); return }
    if (directories.indexOf(directory) !== -1) { error = qsTr("That directory is already included."); return }
    update("settings.updateScriptDirectories", {directories: directories.concat([directory])}, function() { directoryInput.text = "" })
  }

  Window {
    id: settingsWindow
    visible: false
    transientParent: null
    title: qsTr("oma-cast Settings")
    color: Commons.Color.menu.background
    width: 980
    height: 740
    minimumWidth: 760
    minimumHeight: 540
    onVisibleChanged: {
      if (!visible) { root.selectCommand(""); directoryInput.text = "" }
    }

    Control {
      id: surface
      anchors.fill: parent
      padding: Style.space(16)
      font.pixelSize: Style.font.body
      palette.window: Commons.Color.menu.background
      palette.windowText: Commons.Color.menu.text
      palette.base: Commons.Color.menu.background
      palette.alternateBase: Commons.Color.menu.selectedBackground
      palette.text: Commons.Color.menu.text
      palette.button: Commons.Color.menu.selectedBackground
      palette.buttonText: Commons.Color.menu.text
      palette.highlight: Commons.Color.menu.selectedText
      font.family: Style.font.menuFamily
      palette.highlightedText: Commons.Color.menu.background
      palette.placeholderText: Util.alpha(Commons.Color.menu.text, 0.55)
      palette.mid: Util.alpha(Commons.Color.menu.text, 0.3)
      palette.light: Util.alpha(Commons.Color.menu.text, 0.16)
      palette.dark: Util.alpha(Commons.Color.menu.text, 0.4)

      Shortcut {
        sequence: "Ctrl+W"
        enabled: settingsWindow.visible && !hotkeyRecorder.recording
        onActivated: settingsWindow.visible = false
      }
      Shortcut {
        sequence: "Ctrl+S"
        enabled: settingsWindow.visible && root.page === "commands" && root.dirty && !root.busy && !hotkeyRecorder.recording

        onActivated: root.saveCommand()
      }
      Connections {
        target: surface.Window.window
        function onActiveFocusItemChanged() {
          root.revealFocus(surface.Window.window.activeFocusItem)
        }
      }

      contentItem: ColumnLayout {
        spacing: Style.space(12)
        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(20)
          ColumnLayout {
            Layout.preferredWidth: Style.space(210)
            Layout.fillHeight: true
            TextField {
              id: pageSearch
              Layout.fillWidth: true
              placeholderText: qsTr("Find a settings page")
              Accessible.name: placeholderText
            }
            Repeater {
              model: root.pages
              Button {
                required property var modelData
                Layout.fillWidth: true
                visible: !pageSearch.text || modelData.title.toLowerCase().indexOf(pageSearch.text.toLowerCase()) !== -1
                enabled: !root.busy
                highlighted: root.page === modelData.id
                text: modelData.title
                onClicked: root.changePage(modelData.id)
              }
            }
            Item { Layout.fillHeight: true }
          }
          Rectangle { Layout.fillHeight: true; width: 1; color: Util.alpha(Commons.Color.menu.text, 0.15) }
          ScrollView {
            id: contentScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
              id: settingsBody
              width: contentScroll.availableWidth
              spacing: Style.space(16)
              SettingsLabel {
                Layout.fillWidth: true
                font.pixelSize: Style.font.heading
                font.bold: true
                text: {
                  for (var i = 0; i < root.pages.length; i++) if (root.pages[i].id === root.page) return root.pages[i].title
                  return ""
                }
              }

              ColumnLayout {
                visible: root.page === "general"
                enabled: !root.busy
                Layout.fillWidth: true
                spacing: Style.space(14)
                SettingsLabel { Layout.fillWidth: true; text: qsTr("Appearance follows your active Omarchy theme live. Change it using Omarchy’s theme menu.") }
                SettingsChoice {
                  Layout.fillWidth: true
                  label: qsTr("Interface Size")
                  value: root.general.uiZoom
                  options: [{label: qsTr("Default (100%)"), value: 1}, {label: qsTr("Large (110%)"), value: 1.1}, {label: qsTr("Larger (120%)"), value: 1.2}]
                  onChosen: function(value) { root.updateGeneral("uiZoom", value) }
                }
                SettingsChoice {
                  Layout.fillWidth: true
                  label: qsTr("Window Mode")
                  value: root.general.windowMode
                  options: [{label: qsTr("Expanded"), value: "expanded"}, {label: qsTr("Compact"), value: "compact"}]
                  onChosen: function(value) { root.updateGeneral("windowMode", value) }
                }
                CheckBox {
                  Layout.fillWidth: true
                  text: qsTr("Show Favorites in Compact Mode")
                  checked: root.general.showFavoritesInCompactMode === true
                  onClicked: root.updateGeneral("showFavoritesInCompactMode", checked)
                }
              }

              ColumnLayout {
                visible: root.page === "launcher"
                enabled: !root.busy
                Layout.fillWidth: true
                spacing: Style.space(14)
                SettingsChoice {
                  Layout.fillWidth: true
                  label: qsTr("Show Launcher On")
                  value: root.general.windowPresentationMode
                  options: [{label: qsTr("Screen with pointer"), value: "mouse-screen"}, {label: qsTr("Active screen"), value: "active-screen"}, {label: qsTr("Primary screen"), value: "primary-screen"}]
                  onChosen: function(value) { root.updateGeneral("windowPresentationMode", value) }
                }
                SettingsChoice {
                  Layout.fillWidth: true
                  label: qsTr("Return to Root Search After Closing")
                  value: root.general.popToRootTimeout
                  options: [0, 5, 15, 30, 60, 90, 120, 180].map(function(seconds) { return {label: seconds ? qsTr("%1 seconds").arg(seconds) : qsTr("Immediately"), value: seconds} })
                  onChosen: function(value) { root.updateGeneral("popToRootTimeout", value) }
                }
                SettingsChoice {
                  Layout.fillWidth: true
                  label: qsTr("Root Search Sensitivity")
                  value: root.general.rootSearchSensitivity
                  options: [{label: qsTr("Low"), value: "low"}, {label: qsTr("Medium"), value: "medium"}, {label: qsTr("High"), value: "high"}]
                  onChosen: function(value) { root.updateGeneral("rootSearchSensitivity", value) }
                }
                SettingsLabel { text: qsTr("Fallback Commands"); font.bold: true }
                SettingsLabel { Layout.fillWidth: true; text: qsTr("Enabled commands appear beneath search results in this order. Newly enabled fallbacks are added at the end.") }
                Repeater {
                  model: root.fallbacks
                  RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    CheckBox {
                      checked: modelData.enabled
                      Accessible.name: qsTr("Enable %1 fallback").arg(modelData.title)
                      onClicked: root.setFallback(modelData.id, checked)
                    }
                    SettingsLabel { Layout.fillWidth: true; text: modelData.title }
                    Button {
                      text: qsTr("Up")
                      Accessible.name: qsTr("Move %1 up").arg(modelData.title)
                      enabled: modelData.enabled && root.fallbacks.filter(function(item) { return item.enabled }).map(function(item) { return item.id }).indexOf(modelData.id) > 0
                      onClicked: root.moveFallback(modelData.id, -1)
                    }
                    Button {
                      text: qsTr("Down")
                      Accessible.name: qsTr("Move %1 down").arg(modelData.title)
                      enabled: modelData.enabled && root.fallbacks.filter(function(item) { return item.enabled }).slice(-1)[0].id !== modelData.id
                      onClicked: root.moveFallback(modelData.id, 1)
                    }
                  }
                }
              }

              ColumnLayout {
                visible: root.page === "keyboard"
                enabled: !root.busy
                Layout.fillWidth: true
                spacing: Style.space(14)
                SettingsChoice {
                  Layout.fillWidth: true
                  label: qsTr("Escape Key Behavior")
                  value: root.general.escapeKeyBehavior
                  options: [{label: qsTr("Navigate back or close window"), value: "pop-back-or-close"}, {label: qsTr("Close window and return to root"), value: "close-and-pop-to-root"}]
                  onChosen: function(value) { root.updateGeneral("escapeKeyBehavior", value) }
                }
                SettingsChoice {
                  Layout.fillWidth: true
                  label: qsTr("Navigation Bindings")
                  value: root.general.navigationBindings
                  options: [{label: qsTr("Emacs (Ctrl+N)"), value: "emacs"}, {label: qsTr("Vim motions (Ctrl+J/K)"), value: "vim-motions"}]
                  onChosen: function(value) { root.updateGeneral("navigationBindings", value) }
                }
                SettingsLabel { Layout.fillWidth: true; text: qsTr("Ctrl+P opens the root filter. In Vim mode the action panel uses Alt+K instead of Ctrl+K. Per-command global shortcuts are recorded on Commands / Extensions.") }
                Button { text: qsTr("Edit Command Hotkeys"); onClicked: root.changePage("commands") }
                SettingsLabel { text: qsTr("Launcher Shortcut"); font.bold: true }
                SettingsLabel { Layout.fillWidth: true; text: qsTr("Alt+Space is the default. Set up the launcher binding with ‘oma-cast setup hyprland’, then customize ~/.config/hypr/oma-cast.lua. oma-cast never replaces Omarchy’s Super+Space menu binding.") }
                SettingsLabel { text: qsTr("Hyper Key"); font.bold: true }
                SettingsLabel { Layout.fillWidth: true; text: qsTr("oma-cast does not remap keys. Configure keyd, kanata, or XKB yourself to make Caps Lock a Hyper key (Ctrl+Alt+Shift+Super). For keyd, a common mapping is ‘capslock = overload(hyper, esc)’; XKB offers ‘caps:hyper’. Check your remapper’s documentation and existing Hyprland bindings before applying changes. Record the resulting combination as a command hotkey here.") }
              }

              ColumnLayout {
                visible: root.page === "commands"
                Layout.fillWidth: true
                spacing: Style.space(10)
                SettingsLabel { Layout.fillWidth: true; text: qsTr("Applications, built-ins, quicklinks and scripts, including disabled commands. Extension runtime installation is not available in this phase.") }
                TextField {
                  id: commandSearch
                  Layout.fillWidth: true
                  placeholderText: qsTr("Search name, type, alias, hotkey or ID")
                  Accessible.name: placeholderText
                  onTextEdited: root.commandFilter = text
                  Keys.onDownPressed: {
                    if (commandList.count) { commandList.currentIndex = 0; commandList.currentItem.forceActiveFocus() }
                  }
                }
                RowLayout {
                  Layout.fillWidth: true
                  SettingsLabel { Layout.fillWidth: true; text: qsTr("Name"); font.bold: true }
                  SettingsLabel { Layout.preferredWidth: 80; text: qsTr("Type"); font.bold: true }
                  SettingsLabel { Layout.preferredWidth: 70; text: qsTr("Alias"); font.bold: true }
                  SettingsLabel { Layout.preferredWidth: 135; text: qsTr("Hotkey"); font.bold: true }
                }
                ListView {
                  id: commandList
                  Layout.fillWidth: true
                  Layout.preferredHeight: Math.max(180, Math.min(300, settingsWindow.height * 0.35))
                  clip: true
                  model: root.filteredCommands
                  keyNavigationEnabled: true
                  boundsBehavior: Flickable.StopAtBounds
                  ScrollBar.vertical: ScrollBar {}
                  delegate: ItemDelegate {
                    id: commandRow
                    required property var modelData
                    required property int index
                    width: commandList.width
                    highlighted: root.selectedId === modelData.id
                    enabled: !root.busy
                    Accessible.name: modelData.title + (modelData.enabled === false ? qsTr(", disabled") : "")
                    onClicked: root.selectCommand(modelData.id)
                    Keys.onDownPressed: {
                      commandList.currentIndex = Math.min(commandList.count - 1, index + 1)
                      commandList.currentItem.forceActiveFocus()
                    }
                    Keys.onUpPressed: {
                      commandList.currentIndex = Math.max(0, index - 1)
                      commandList.currentItem.forceActiveFocus()
                    }
                    contentItem: RowLayout {
                      SettingsLabel {
                        Layout.fillWidth: true
                        text: commandRow.modelData.title + (commandRow.modelData.enabled === false ? qsTr(" (disabled)") : "")
                        elide: Text.ElideRight
                        wrapMode: Text.NoWrap
                      }
                      SettingsLabel { Layout.preferredWidth: 80; text: commandRow.modelData.kind || commandRow.modelData.type; elide: Text.ElideRight; wrapMode: Text.NoWrap }
                      SettingsLabel { Layout.preferredWidth: 70; text: commandRow.modelData.alias || ""; elide: Text.ElideRight; wrapMode: Text.NoWrap }
                      SettingsLabel { Layout.preferredWidth: 135; text: commandRow.modelData.hotkey ? Hotkeys.format(commandRow.modelData.hotkey) : ""; elide: Text.ElideRight; wrapMode: Text.NoWrap }
                    }
                  }
                  SettingsLabel { anchors.centerIn: parent; visible: commandList.count === 0; text: qsTr("No matching commands") }
                }
                ColumnLayout {
                  visible: !!root.selectedCommand
                  enabled: !root.busy
                  Layout.fillWidth: true
                  SettingsLabel { Layout.fillWidth: true; text: root.selectedCommand ? root.selectedCommand.title : ""; font.bold: true }
                  SettingsLabel { Layout.fillWidth: true; text: root.selectedId; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WrapAnywhere }
                  CheckBox { text: qsTr("Enabled in Root Search"); checked: root.draftEnabled; onClicked: root.draftEnabled = checked }
                  SettingsLabel { text: qsTr("Alias") }
                  TextField {
                    id: aliasInput
                    Layout.fillWidth: true
                    text: root.draftAlias
                    placeholderText: qsTr("Optional exact-match alias")
                    Accessible.name: qsTr("Command alias")
                    onTextEdited: root.draftAlias = text
                    onAccepted: { if (root.dirty) root.saveCommand() }
                  }
                  SettingsLabel { text: qsTr("Global Hotkey") }
                  SettingsHotkeyRecorder {
                    id: hotkeyRecorder
                    Layout.fillWidth: true
                    hotkey: root.draftHotkey
                    onRecorded: function(value) { root.draftHotkey = value }
                  }
                  RowLayout {
                    Button { text: qsTr("Save"); enabled: root.dirty; onClicked: root.saveCommand() }
                    Button { text: qsTr("Cancel"); onClicked: root.selectCommand(root.selectedId) }
                    SettingsLabel { Layout.fillWidth: true; text: root.dirty ? qsTr("Unsaved changes") : qsTr("Up to date") }
                  }
                  SettingsLabel { Layout.fillWidth: true; text: qsTr("Save applies this command’s changes. Cancel, choosing another command, changing pages or closing this window discards its unsaved draft.") }
                }
              }

              ColumnLayout {
                visible: root.page === "quicklinks"
                enabled: !root.busy
                Layout.fillWidth: true
                spacing: Style.space(14)
                CheckBox {
                  text: qsTr("Show Link Previews")
                  checked: root.quicklinkPreferences.showPreviews === true
                  onClicked: root.update("settings.updateQuicklinkPreferences", {showPreviews: checked})
                }
                CheckBox {
                  text: qsTr("Pass Selected Text as Argument")
                  checked: root.quicklinkPreferences.passSelectedTextAsArgument === true
                  onClicked: root.update("settings.updateQuicklinkPreferences", {passSelectedTextAsArgument: checked})
                }
                SettingsLabel { Layout.fillWidth: true; text: qsTr("Use Create Quicklink, Search Quicklinks, Import Quicklinks and Export Quicklinks from the launcher to manage links. Enable and reorder argument-based quicklinks as fallbacks on the Launcher page.") }
              }

              ColumnLayout {
                visible: root.page === "scripts"
                enabled: !root.busy
                Layout.fillWidth: true
                spacing: Style.space(14)
                SettingsLabel { Layout.fillWidth: true; text: qsTr("Script directories are scanned for Raycast Script Command metadata. Add only directories you trust: executing a command runs its local script with your permissions.") }
                Repeater {
                  model: root.directories
                  RowLayout {
                    required property string modelData
                    required property int index
                    Layout.fillWidth: true
                    SettingsLabel { Layout.fillWidth: true; text: modelData; wrapMode: Text.WrapAnywhere }
                    Button {
                      text: qsTr("Remove")
                      Accessible.name: qsTr("Remove directory %1").arg(modelData)
                      onClicked: {
                        var next = root.directories.slice()
                        next.splice(index, 1)
                        root.update("settings.updateScriptDirectories", {directories: next})
                      }
                    }
                  }
                }
                SettingsLabel { Layout.fillWidth: true; visible: !root.directories.length; text: qsTr("No script directories configured.") }
                TextField {
                  id: directoryInput
                  Layout.fillWidth: true
                  placeholderText: qsTr("Absolute path to a script directory")
                  Accessible.name: placeholderText
                  onAccepted: root.addDirectory()
                }
                RowLayout {
                  Button { text: qsTr("Add Directory"); onClicked: root.addDirectory() }
                  Button { text: qsTr("Cancel"); enabled: !!directoryInput.text; onClicked: directoryInput.text = "" }
                }
                SettingsLabel { Layout.fillWidth: true; text: qsTr("Directory changes are saved immediately and trigger a rescan. Use Reload Script Commands after editing script metadata, and Create Script Command for a new script.") }
              }

              ColumnLayout {
                visible: root.page === "about"
                Layout.fillWidth: true
                spacing: Style.space(14)
                SettingsLabel { text: qsTr("oma-cast %1").arg(root.backend.version); font.bold: true }
                SettingsLabel { Layout.fillWidth: true; text: qsTr("A clean-room launcher for Omarchy, running inside omarchy-shell. QML and plain JavaScript; no Raycast assets, account, store, sync or telemetry.") }
                SettingsLabel { Layout.fillWidth: true; text: qsTr("Theme: Omarchy\nUpdates: update the installed oma-cast checkout, then run ‘oma-cast reload’.\nDiagnostics: ‘oma-cast doctor’.\nSettings, quicklinks and history are stored locally without application-level encryption.") }
              }
            }
          }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Util.alpha(Commons.Color.menu.text, 0.15) }
        RowLayout {
          Layout.fillWidth: true
          SettingsLabel {
            Layout.fillWidth: true
            text: root.busy ? qsTr("Saving…") : root.error || root.notice || qsTr("Settings apply immediately except command drafts.")
            color: root.error ? Commons.Color.urgent : Commons.Color.menu.text
            maximumLineCount: 5
            elide: Text.ElideRight
          }
          Button { text: qsTr("Refresh"); enabled: !root.busy; onClicked: { root.error = ""; root.notice = ""; root.refresh(); root.selectCommand(root.selectedId) } }
          Button { text: qsTr("Close"); onClicked: settingsWindow.visible = false }
        }
      }
    }
  }
}
