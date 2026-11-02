import QtQuick
import Quickshell
import Quickshell.Io
import "../core/Rpc.js" as Rpc
import "../core/ScriptCommands.js" as Scripts

Item {
  id: service
  required property var backend
  readonly property bool ready: backend.directoriesReady
  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("../scripts/script-commands.bash").toString().replace(/^file:\/\//, ""))
  property var candidates: []
  property var scripts: ({})
  property var inlineResults: ({})
  property var nextRefresh: ({})
  property var runs: ({})
  property int revision: 0
  property int serial: 0
  property bool initialized: false
  property bool environmentReady: false
  property var loginEnvironment: ({})
  property string lastScanError: ""
  property bool unloading: false
  property int scanRetryIndex: 0
  signal runChanged(string runId)

  function text64(value) { return Scripts.decodeRecord(value) }
  function toast(style, title, actions) {
    if (!unloading) backend.emit("general.showToast", {style: style, title: title, actions: actions || []})
  }
  function initialize() {
    Rpc.register(backend.registry, "scriptCommands", {
      getAll: function() { return candidates },
      reload: function() { if (!environmentReady) start(); rescan(true); return {pending: true} },
      create: function(data) { return create(data || {}) },
      execute: function(data) {
        var script = scripts[String(data && (data.id || data.commandId) || "")]
        if (!script) throw new Error("Script command no longer exists")
        return execute(Scripts.candidate(script), data || {})
      },
      cancel: function(data) { return cancel(String(data && data.runId || "")) },
      getRun: function(data) { return publicRun(String(data && data.runId || "")) },
      rerun: function(data) { return rerun(String(data && data.runId || "")) }
    })
    initialized = true
    start()
  }
  function start() {
    if (!initialized || !ready) return
    if (!environmentReady && !environmentProcess.running) {
      environmentProcess.values = ({})
      environmentProcess.failure = ""
      environmentProcess.command = ["timeout", "10s", "/bin/bash", helper, "environment", Quickshell.env("SHELL") || "/bin/bash"]
      environmentProcess.running = true
    }
    rescan()
  }
  onReadyChanged: if (ready) start()
  function directories() {
    var result = backend.callSync("settings.getScriptDirectories", {})
    if (!result.ok) throw new Error(result.error)
    return result.data.directories
  }
  function rescan(notify) {
    if (!initialized || !ready) return
    if (scanProcess.running) { scanProcess.again = true; scanProcess.notify = scanProcess.notify || notify === true; return }
    try {
      scanProcess.found = ({})
      scanProcess.errors = []
      scanProcess.notify = notify === true
      scanProcess.command = ["timeout", "5s", "/bin/bash", helper, "scan"].concat(directories())
      scanProcess.running = true
    } catch (error) { toast("failure", String(error.message || error)) }
  }
  function rebuildCandidates() {
    candidates = Object.keys(scripts).sort().map(function(id) { return Scripts.candidate(scripts[id], inlineResults[id]) })
  }
  function commandEnabled(id) {
    var result = backend.callSync("settings.getCommandSettings", {commandId: id})
    if (!result.ok) throw new Error(result.error)
    return result.data.enabled !== false
  }
  function stopDisabledInline() {
    if (!initialized) return
    Object.keys(runs).forEach(function(id) {
      var run = runs[id]
      if (run.running && run.script.mode === "inline" && !commandEnabled(run.script.id)) cancel(id)
    })
  }
  Connections {
    target: service.backend
    function onStoreRevisionChanged() { service.stopDisabledInline() }
  }
  function scheduleInline() {
    if (!environmentReady || !ready || unloading) return
    var now = Date.now()
    Object.keys(scripts).forEach(function(id) {
      var script = scripts[id]
      if (script.mode !== "inline" || !commandEnabled(id) || (nextRefresh[id] || 0) > now || activeCount() >= 4) return
      var active = Object.keys(runs).some(function(key) { return runs[key].running && runs[key].script.id === id })
      if (active) return
      nextRefresh[id] = now + script.refreshTime
      begin(script, [])
    })
  }
  function activeCount() { return Object.keys(runs).filter(function(id) { return runs[id].running }).length }
  function execute(candidate, data) {
    data = data || {}
    var script = scripts[candidate.id]
    if (!script) throw new Error("Script command no longer exists")
    if (!commandEnabled(script.id)) throw new Error("Script command is disabled")
    if (script.needsConfirmation && !data.confirmed) return {confirm: {title: "Run " + script.title + "?", message: script.description || "This script requests confirmation before running.", primary: "Run Script", destructive: false}}
    var args = Scripts.argumentsFor(script, data.arguments)
    var run = begin(script, args)
    backend.recordVisit(script.id, String(data.query || ""))
    if (script.mode === "fullOutput") return {push: {kind: "script-output", title: script.title, runId: run.id}}
    if (script.mode === "silent") return {close: true, runId: run.id}
    return {pending: true, runId: run.id}
  }
  function begin(script, args) {
    if (!environmentReady) throw new Error("Login-shell environment is not ready; reload script commands to retry")
    if (activeCount() >= 4) throw new Error("Four scripts are already running; cancel one before starting another")
    var completed = Object.keys(runs).filter(function(id) { return !runs[id].running })
    while (completed.length >= 8) delete runs[completed.shift()]
    var id = "script-run-" + (++serial)
    var run = {id: id, script: script, arguments: args, running: true, canceled: false, exitCode: null, output: Scripts.outputState(), process: null, startedAt: Date.now()}
    runs[id] = run
    var object = runnerComponent.createObject(service, {runId: id})
    run.process = object
    if (script.mode === "compact") toast("running", "Running " + script.title + "…", [{id: "script-cancel", title: "Cancel", call: {method: "scriptCommands.cancel", data: {runId: id}}, done: "Script canceled"}])
    // Starting on the next event-loop turn lets the silent outcome dismiss the
    // launcher first, and ensures callers can bind their output view to this id.
    Qt.callLater(function() { if (!unloading && run.running && !run.canceled) object.start() })
    revision++
    return run
  }
  function receive(id, line) {
    var run = runs[id]
    if (!run || !run.running || line.length < 2) return
    var tag = line.slice(0, 2)
    if (tag !== "O:" && tag !== "E:") return
    Scripts.appendOutput(run.output, text64(line.slice(2)), tag === "E:")
    if (run.script.mode === "inline" && run.output.firstLine !== null && inlineResults[run.script.id] !== run.output.firstLine) {
      inlineResults[run.script.id] = run.output.firstLine
      rebuildCandidates()
    }
    revision++
    runChanged(id)
  }
  function finished(id, code, status, failure) {
    var run = runs[id]
    if (!run || !run.running) return
    run.running = false
    run.exitCode = code
    Scripts.finishOutput(run.output)
    var success = !run.canceled && code === 0 && status === 0
    run.message = run.canceled ? "Script canceled" : failure || run.output.lastLine || (success ? "Script finished" : "Script exited with code " + code)
    if (!success && !run.canceled && !failure) run.message = "Exit " + code + ": " + run.message
    if (run.script.mode === "inline") {
      inlineResults[run.script.id] = success ? run.output.firstLine : "Error: " + run.message
      nextRefresh[run.script.id] = Date.now() + run.script.refreshTime
      rebuildCandidates()
    } else if (run.script.mode === "silent") {
      if (!unloading) backend.emit("general.showHUD", {text: run.message})
    } else if (run.script.mode === "compact" || !success) toast(success ? "success" : "failure", run.message)
    if (run.process) { run.process.destroy(); run.process = null }
    revision++
    runChanged(id)
  }
  function cancel(id) {
    var run = runs[id]
    if (!run || !run.running) return {canceled: false}
    run.canceled = true
    if (run.process && run.process.active) run.process.stop()
    else finished(id, 130, 0, "")
    return {canceled: true}
  }
  function publicRun(id) {
    var run = runs[id]
    if (!run) throw new Error("Script output is no longer available")
    return {id: id, title: run.script.title, mode: run.script.mode, running: run.running, canceled: run.canceled, exitCode: run.exitCode, message: run.message || "Running…", segments: run.output.segments, truncated: run.output.truncated}
  }
  function rerun(id) {
    var run = runs[id]
    if (!run) throw new Error("Script output is no longer available")
    if (run.running) throw new Error("This script is still running")
    var script = scripts[run.script.id]
    if (!script) throw new Error("Script command no longer exists")
    if (!commandEnabled(script.id)) throw new Error("Script command is disabled")
    var next = begin(script, run.arguments.slice())
    backend.recordVisit(script.id, "")
    return {runId: next.id}
  }
  function create(data) {
    if (createProcess.running) return Promise.reject(new Error("A script is already being created"))
    var directory = String(data.directory || directories()[0] || "")
    if (!directory || directory.charAt(0) !== "/" || directory.indexOf("\0") >= 0) throw new Error("Choose an absolute script directory")
    if (directories().indexOf(directory) < 0) throw new Error("Add this script directory in Settings first")
    var filename = String(data.filename || "")
    if (!filename || filename.indexOf("/") >= 0 || /[\r\n\0]/.test(filename) || filename === "." || filename === ".." || filename.indexOf(".template.") >= 0) throw new Error("Enter a filename, without a directory or .template. marker")
    var body = Scripts.template(data)
    return new Promise(function(resolve, reject) {
      createProcess.resolveResult = resolve
      createProcess.rejectResult = reject
      createProcess.errorText = ""
      createProcess.path = directory + "/" + filename
      createProcess.command = ["/bin/bash", helper, "create", directory, filename, body]
      createProcess.running = true
    })
  }
  Timer { interval: 15000; repeat: true; running: service.ready && service.initialized && !scanRetry.running; onTriggered: service.rescan() }
  Timer { interval: 1000; repeat: true; running: service.ready && service.initialized; onTriggered: service.scheduleInline() }
  Process {
    id: environmentProcess
    property var values: ({})
    property string failure: ""
    stdout: SplitParser { onRead: function(line) {
      if (line.slice(0, 2) !== "E:") return
      var entry = service.text64(line.slice(2)), separator = entry.indexOf("=")
      if (separator > 0 && /^[A-Za-z_][A-Za-z0-9_]*$/.test(entry.slice(0, separator))) environmentProcess.values[entry.slice(0, separator)] = entry.slice(separator + 1)
    } }
    stderr: SplitParser { onRead: function(line) { environmentProcess.failure = line.slice(-4096) } }
    onExited: function(code, status) {
      if (code !== 0 || status !== 0 || !values.PATH) { service.toast("failure", "Cannot load login-shell environment: " + (failure || "exit " + code)); return }
      delete values.LC_ALL
      service.loginEnvironment = values
      service.environmentReady = true
      service.scheduleInline()
    }
  }
  Timer { id: scanRetry; onTriggered: service.rescan() }
  Process {
    id: scanProcess
    property var found: ({})
    property var errors: []
    property bool notify: false
    property bool again: false
    stdout: SplitParser { onRead: function(line) {
      var parts = line.split(":")
      if (parts[0] === "E") { if (scanProcess.errors.length < 10) scanProcess.errors.push(service.text64(parts[1])); return }
      if (parts[0] !== "S" || parts.length !== 3) return
      var path = service.text64(parts[1])
      try {
        var script = Scripts.parse(path, service.text64(parts[2]))
        if (script) scanProcess.found[script.id] = script
      } catch (error) { if (scanProcess.errors.length < 10) scanProcess.errors.push(path + ": " + String(error.message || error)) }
    } }
    stderr: SplitParser { onRead: function(line) { if (scanProcess.errors.length < 10) scanProcess.errors.push(line.slice(-4096)) } }
    onExited: function(code, status) {
      if (code === 0 && status === 0) { service.scanRetryIndex = 0; scanRetry.stop() }
      else {
        scanRetry.interval = [2000, 5000, 10000, 30000, 60000][Math.min(service.scanRetryIndex++, 4)]
        scanRetry.restart()
      }
      if (code === 0 && status === 0) {
        service.scripts = found
        Object.keys(service.inlineResults).forEach(function(id) { if (!found[id]) { delete service.inlineResults[id]; delete service.nextRefresh[id] } })
        Object.keys(service.runs).forEach(function(id) { var run = service.runs[id]; if (run.running && run.script.mode === "inline" && !found[run.script.id]) service.cancel(id) })
        service.rebuildCandidates()
        service.scheduleInline()
      } else errors.push("Script directory scan failed or timed out (exit " + code + ")")
      var message = errors.join("\n")
      if (message && (message !== service.lastScanError || notify)) service.toast("failure", message)
      else if (notify && !message) service.toast("success", "Reloaded " + Object.keys(found).length + " script commands")
      service.lastScanError = message
      if (again) { again = false; Qt.callLater(function() { service.rescan() }) }
    }
  }
  Process {
    id: createProcess
    property var resolveResult: null
    property var rejectResult: null
    property string errorText: ""
    property string path: ""
    stderr: SplitParser { onRead: function(line) { createProcess.errorText = line.slice(-4096) } }
    onExited: function(code, status) {
      var resolve = resolveResult, reject = rejectResult
      resolveResult = null; rejectResult = null
      if (code === 0 && status === 0) { service.rescan(); if (resolve) resolve({path: path}); service.toast("success", "Script created: " + path) }
      else { var message = errorText || "Could not create script (exit " + code + ")"; if (reject) reject(new Error(message)); service.toast("failure", message) }
    }
  }
  Component {
    id: runnerComponent
    Item {
      id: runner
      required property string runId
      readonly property bool active: process.running
      function start() {
        var run = service.runs[runId]
        process.command = ["/bin/bash", service.helper, "run", run.script.cwd, run.script.path].concat(run.arguments)
        process.running = true
        startupWatch.restart()
      }
      function stop() { process.signal(15) }
      Process {
        id: process
        clearEnvironment: true
        environment: service.loginEnvironment
        stdout: SplitParser { onRead: function(line) { service.receive(runner.runId, line) } }
        stderr: SplitParser { onRead: function(line) { service.receive(runner.runId, "E:" + Qt.btoa(line + "\n")) } }
        onStarted: startupWatch.stop()
        onExited: function(code, status) { service.finished(runner.runId, code, status, "") }
      }
      Timer { id: startupWatch; interval: 1000; onTriggered: if (!process.running) service.finished(runner.runId, 127, 0, "Could not start script process") }
      Component.onDestruction: if (process.running) process.signal(15)
    }
  }
  Component.onDestruction: {
    unloading = true
    Object.keys(runs).forEach(function(id) { if (runs[id].running && runs[id].process) runs[id].process.stop() })
  }
}
