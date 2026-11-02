import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import "ui"

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property string ipcTarget: "oma-cast"
  property string ipcConfigPath: ""
  property var pathOverrides: null

  readonly property string pluginId: (root.manifest && root.manifest.id) || "typecraft.oma-cast"

  property bool opened: false
  property double openedAt: 0


  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    var wasOpen = root.opened
    root.opened = true
    root.openedAt = Date.now()
    launcher.prepare(payload)
    if (!wasOpen) backend.emit("window.visibilityChanged", { visible: true })
  }

  function close() {
    if (!root.opened) return
    root.opened = false
    backend.emit("window.visibilityChanged", { visible: false })
  }


  function show() {
    if (root.opened) return
    if (root.shell && root.shell.summon(root.pluginId, "{}")) return
    root.open("{}")
  }

  function hide() {
    if (!root.opened) return
    if (root.shell && root.shell.hide(root.pluginId)) {
      root.close()
      return
    }
    root.close()
  }

  function toggle() {
    if (root.opened) root.hide()
    else root.show()
  }

  function run(commandId) {
    var candidate = backend.decorated(commandId)
    if (!candidate) return { ok: false, error: "Unknown command " + commandId }
    var settings = backend.callSync("settings.getCommandSettings", { commandId: commandId })
    if (settings.ok && settings.data.enabled === false) return { ok: false, error: "Command is disabled" }
    if (candidate.arguments && candidate.arguments.length) {
      var prefs = backend.callSync("settings.getQuicklinkPreferences", {})
      if (candidate.kind === "quicklink" && candidate.arguments.length === 1 && prefs.ok && prefs.data.passSelectedTextAsArgument)
        return backend.callSync("rootSearch.performAction", { id: commandId, action: "open", query: "", hotkey: true })
      root.show()
      launcher.promptCommand(candidate)
      return { ok: true, data: { prompted: true } }
    }
    // Explicit command invocation skips power alerts; scripts keep their own confirmation.
    var r = backend.callSync("rootSearch.performAction", { id: commandId, action: "open", query: "", confirmed: candidate.kind !== "script" })
    if (!r.ok) return r
    var outcome = r.data || {}
    if (outcome.push || outcome.confirm) root.show()
    launcher.applyOutcome(outcome, { id: commandId, action: "open", query: "" })
    return r
  }

  Backend {
    id: backend
    ipcTarget: root.ipcTarget
    ipcConfigPath: root.ipcConfigPath
    pathOverrides: root.pathOverrides
    appLibrary: root.shell ? root.shell.appLibrary : null
    summon: function(id, payload) { return root.shell ? root.shell.summon(id, payload) : false }
  }

  Connections {
    target: backend
    function onNotification(method, data) {
      if (method === "agent.launchReady") {
        root.hide()
        launcher.popToRoot()
        Util.execArgv(data.argv)
      } else if (method === "settings.openRequested") {
        root.hide()
        settingsWindow.open(data.page || "general", data.commandId || "")
      } else if (method === "quicklinks.openRequested") {
        root.hide()
        quicklinksWindow.open(data)
      } else if (method === "scriptCommands.createRequested") {
        root.hide()
        scriptWindow.open(data || {})
      } else if (method === "general.closeMainWindow") {
        root.hide()
        launcher.popToRoot()
      }
    }
  }

  LauncherWindow {
    id: launcher
    shown: root.opened
    backend: backend
    appLibrary: backend.appLibrary
    onDismissRequested: root.hide()
  }

  SettingsWindow { id: settingsWindow; backend: backend }
  QuicklinksWindow { id: quicklinksWindow; backend: backend }
  ScriptCommandWindow { id: scriptWindow; backend: backend }

  GlobalShortcut {
    appid: root.ipcTarget
    name: "toggle"
    description: "Toggle oma-cast"
    onPressed: root.toggle()
  }

  IpcHandler {
    target: root.ipcTarget

    function toggle(): string {
      root.toggle()
      return root.opened ? "shown" : "hidden"
    }

    function show(): string {
      root.show()
      return "shown"
    }

    function search(query: string): string {
      root.show()
      launcher.popToRoot()
      launcher.setQuery(query)
      return "shown"
    }

    function settings(page: string): string {
      root.hide()
      settingsWindow.open(page || "general", "")
      return "shown"
    }

    function hide(): string {
      root.hide()
      return "hidden"
    }

    function isOpen(): string {
      return root.opened ? "true" : "false"
    }

    function ping(): string {
      return "ok"
    }

    function run(commandId: string): string {
      return JSON.stringify(root.run(commandId))
    }

    function call(method: string, dataJson: string): string {
      var data = null
      if (dataJson && dataJson.length > 0) {
        try { data = JSON.parse(dataJson) } catch (e) {
          return JSON.stringify({ ok: false, error: "data is not JSON: " + e })
        }
      }
      return JSON.stringify(backend.callSync(method, data))
    }
  }
}
