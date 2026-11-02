import QtQuick
import Quickshell.Io
import Quickshell.Services.Mpris
import "../core/SystemActions.js" as SystemActions
import "../core/Rpc.js" as Rpc

Item {
  id: service
  required property var backend
  readonly property bool ready: backend.directoriesReady
  readonly property var candidates: SystemActions.candidates()
  readonly property bool busy: service.activeCandidate !== null
  property var activeCandidate: null
  property var activePlan: null
  property string output: ""
  property string errors: ""
  property string lastLightTheme: ""
  property string lastDarkTheme: ""

  function initialize() {
    Rpc.register(backend.registry, "systemActions", {
      getCommands: function() { return service.candidates },
      execute: function(data) {
        // Keep the root action's disabled-command checks and power confirmation.
        var id = String(data && data.id || "")
        if (!SystemActions.handles(id)) throw new Error("Unknown system action " + id)
        var result = backend.callSync("rootSearch.performAction", {
          id: id, action: "open", query: String(data && data.query || ""),
          arguments: data && data.arguments || {}, confirmed: !!(data && data.confirmed)
        })
        if (!result.ok) throw new Error(result.error)
        return result.data
      }
    })
  }

  function execute(candidate, data) {
    if (!service.ready) throw new Error("System actions are not ready")
    if (service.busy) throw new Error("Wait for the current system action to finish")
    var actionPlan = SystemActions.plan(candidate.id, data || {}, Mpris.players.values)
    var argv = actionPlan.appearance
      ? ["bash", "-c", SystemActions.APPEARANCE_SCRIPT, "oma-cast-appearance", service.lastLightTheme, service.lastDarkTheme]
      : ["bash", "-c", SystemActions.EXEC_SCRIPT, "oma-cast-system"].concat(actionPlan.argv)
    service.activeCandidate = candidate
    service.activePlan = actionPlan
    service.output = ""
    service.errors = ""
    runner.command = argv
    if (actionPlan.power || actionPlan.panel) backend.emit("general.closeMainWindow", {})
    runner.running = true
    startCheck.restart()
    backend.emit("general.showToast", { style: "running", title: candidate.title + "…" })
    return { pending: true }
  }

  function rememberTheme(line) {
    if (!service.activePlan || !service.activePlan.appearance) return
    var match = /^OMA_THEME_(?:CURRENT|APPLIED)\t(light|dark)\t(.+)$/.exec(line)
    if (!match) return
    if (match[1] === "light") service.lastLightTheme = match[2]
    else service.lastDarkTheme = match[2]
  }

  function finish(exitCode, exitStatus) {
    startCheck.stop()
    if (!service.activeCandidate) return
    var result = SystemActions.completionMessage(service.activeCandidate, service.activePlan,
      exitCode, exitStatus, service.errors, service.output)
    service.activeCandidate = null
    service.activePlan = null
    backend.emit("general.showToast", result)
  }

  Timer {
    id: startCheck
    interval: 1000
    onTriggered: {
      if (service.busy && !runner.running) {
        service.errors = "Could not start bash to execute the system action"
        service.finish(127, 0)
      }
    }
  }

  Process {
    id: runner
    stdout: SplitParser {
      onRead: function(line) {
        service.rememberTheme(line)
        service.output = (service.output + line + "\n").slice(-4096)
      }
    }
    stderr: SplitParser {
      onRead: function(line) { service.errors = (service.errors + line + "\n").slice(-4096) }
    }
    onExited: function(exitCode, exitStatus) { service.finish(exitCode, exitStatus) }
  }
}
