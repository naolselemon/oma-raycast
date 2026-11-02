import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../core/Hotkeys.js" as Hotkeys
import "../core/Rpc.js" as Rpc

Item {
  id: service
  required property var backend
  readonly property bool ready: backend.directoriesReady && backend.ready
  readonly property string ipcTarget: backend.ipcTarget || "oma-cast"
  readonly property string ipcConfigPath: backend.ipcConfigPath || ""
  property string sessionTarget: ""
  property string owner: Date.now().toString(36) + "-" + Math.random().toString(36).slice(2)
  property bool initialized: false
  property bool acquired: false
  property bool disposed: false
  property int generation: 0
  property int sequence: 0
  property var active: ({})
  property var failures: ({})
  property var queue: Promise.resolve()
  property string lastError: ""

  function initialize() {
    if (initialized) return
    initialized = true
    Rpc.register(backend.registry, "hotkey", {
      getAll: function() { return service.status() },
      getStatus: function() { return service.status() },
      normalize: function(data) { return Hotkeys.normalize(data && data.hotkey) },
      setCommand: function(data) { return service.setCommand(data) },
      getConflicts: function(data) { return service.inspect(data) },
      reconcile: function() { service.schedule(); return { pending: true } }
    })
    schedule()
  }

  function settings() {
    var result = backend.callSync("settings.getAllCommandSettings")
    if (!result.ok) throw new Error(result.error)
    return result.data || {}
  }

  function enabled(id) { return !!backend.candidatesById[id] && (settings()[id] || {}).enabled !== false }

  function status() {
    return { active: active, conflicts: failures, error: lastError, ready: ready && acquired, ipcTarget: ipcTarget }
  }

  function enqueue(callback) {
    var result = queue.then(function() {
      if (disposed) throw new Error("Hotkey service unloaded")
      return callback()
    })
    queue = result.catch(function() {})
    return result
  }

  function run(argv) {
    return new Promise(function(resolve, reject) {
      var child = runner.createObject(service, { argv: argv, resolveResult: resolve, rejectResult: reject })
      child.start()
    })
  }

  function evaluate(code) {
    return run(["hyprctl", "eval", code]).then(function(text) {
      if (text.trim() !== "ok") throw new Error(text.trim() || "Hyprland did not acknowledge the binding")
    })
  }

  function acquire() {
    if (acquired) return Promise.resolve()
    sessionTarget = ipcTarget
    var expectedGeneration = generation
    return evaluate(Hotkeys.acquireLua(sessionTarget, owner)).then(function() {
      if (expectedGeneration !== generation) throw new Error("Hyprland reloaded during hotkey setup")
      acquired = true
      active = ({})
    })
  }

  function check(id, hotkey, binds) {
    var commands = settings()
    for (var other in commands) {
      if (other !== id && enabled(other) && commands[other].hotkey
          && Hotkeys.identity(commands[other].hotkey) === Hotkeys.identity(hotkey))
        throw new Error(Hotkeys.format(hotkey) + " is assigned to " + (backend.candidatesById[other].title || other))
    }
    // acquire() disabled every previous handle in this target's private Lua
    // registry. Dormant handles stay until config reload: deleting a handle in
    // Hyprland 0.56 would also delete user shortcuts sharing that chord.
    var ownedPrefix = Hotkeys.prefix(ipcTarget)
    var ignored = binds.filter(function(bind) {
      return String(bind.description || "").indexOf(ownedPrefix) === 0
    }).map(function(bind) { return bind.description })
    return Hotkeys.conflicts(hotkey, binds, ignored)
  }

  function inspect(data) {
    var id = String(data && data.commandId || "")
    var hotkey = Hotkeys.normalize(data && data.hotkey)
    return enqueue(function() {
      return acquire().then(function() { return run(["hyprctl", "binds", "-j"]) }).then(function(text) {
        return { hotkey: hotkey, conflicts: check(id, hotkey, JSON.parse(text)) }
      })
    })
  }

  function setCommand(data) {
    var id = String(data && data.commandId || "")
    var hotkey
    var patch = {}
    try {
      if (!ready) throw new Error("Command settings are not loaded")
      if (!backend.candidatesById[id]) throw new Error("Unknown command " + id)
      if (data.hotkey !== undefined) hotkey = Hotkeys.normalize(data.hotkey)
      if (data.enabled !== undefined) {
        if (typeof data.enabled !== "boolean") throw new Error("Enabled must be a boolean")
        patch.enabled = data.enabled
      }
      if (data.alias !== undefined) {
        if (data.alias !== null && typeof data.alias !== "string") throw new Error("Alias must be text")
        patch.alias = String(data.alias || "").trim().toLowerCase()
        if (/\s/.test(patch.alias)) throw new Error("An alias cannot contain spaces")
      }
      var health = backend.callSync("system.healthDatabase")
      if (!health.ok || !health.data || health.data.readOnly || (health.data.settings && health.data.settings.readOnly))
        throw new Error("Command settings are read-only")
    } catch (error) { return Promise.reject(error) }
    return enqueue(function() {
      if (patch.alias) {
        var commands = settings()
        for (var other in commands) {
          if (other !== id && commands[other].alias === patch.alias) throw new Error("Alias is already used by " + other)
        }
      }
      return apply(id, hotkey === undefined ? Hotkeys.normalize((settings()[id] || {}).hotkey) : hotkey, true, patch)
    })
  }

  function apply(id, hotkey, persist, patch) {
    var old = active[id]
    var token = ""
    var activated = false
    var expectedGeneration = generation
    var originalSettings = JSON.stringify(settings()[id] || {})
    patch = patch || {}
    var commandEnabled = patch.enabled === undefined ? enabled(id) : patch.enabled && !!backend.candidatesById[id]
    var desired = hotkey && commandEnabled ? hotkey : null
    function stillCurrent() {
      if (disposed || expectedGeneration !== generation || ipcTarget !== sessionTarget
          || JSON.stringify(settings()[id] || {}) !== originalSettings
          || ((desired || persist) && !backend.candidatesById[id])) throw new Error("Command or compositor changed while assigning its hotkey; try again")
    }
    return acquire().then(function() {
      stillCurrent()
      if (!desired) return
      return run(["hyprctl", "binds", "-j"]).then(function(text) {
        var collisions = check(id, desired, JSON.parse(text))
        if (collisions.length) throw new Error(Hotkeys.format(desired) + " conflicts with " + collisions.map(function(c) { return c.description }).join(", "))
        token = owner + ":" + (++sequence)
        return evaluate(Hotkeys.stageLua(ipcTarget, owner, token, id, desired, ipcConfigPath))
      }).then(function() { return run(["hyprctl", "binds", "-j"]) }).then(function(text) {
        stillCurrent()
        var binds = JSON.parse(text)
        var collisions = check(id, desired, binds)
        if (collisions.length) throw new Error(Hotkeys.format(desired) + " conflicts with " + collisions.map(function(c) { return c.description }).join(", "))
        if (!binds.some(function(b) { return b.description === Hotkeys.prefix(ipcTarget) + token }))
          throw new Error("Hyprland did not retain the staged hotkey")
      })
    }).then(function() {
      stillCurrent()
      return evaluate(Hotkeys.activateLua(ipcTarget, owner, token, old && old.token))
    }).then(function() {
      activated = true
      stillCurrent()
      // updateCommand must throw on an unloaded/read-only store. Settings are
      // changed only after the compositor accepted the new active state.
      if (persist) backend.updateCommand(id, function(command) {
        if (hotkey) command.hotkey = hotkey
        else delete command.hotkey
        if (patch.alias !== undefined) {
          if (patch.alias) command.alias = patch.alias
          else delete command.alias
        }
        if (patch.enabled !== undefined) {
          if (patch.enabled === false) command.enabled = false
          else delete command.enabled
        }
        return command
      })
      var next = Object.assign({}, active)
      if (desired) next[id] = { hotkey: desired, token: token }
      else delete next[id]
      active = next
      var errors = Object.assign({}, failures)
      delete errors[id]
      failures = errors
      lastError = ""
      backend.emit("hotkey.changed", { commandId: id, hotkey: hotkey, active: !!desired })
      return settings()[id] || {}
    }).catch(function(error) {
      // An unactivated staged handle is already disabled. Roll back only this
      // session's handles, never the key chord or another client's shortcuts.
      if (!activated || expectedGeneration !== generation) throw error
      return evaluate(Hotkeys.activateLua(ipcTarget, owner, old && enabled(id) ? old.token : "", token)).then(
        function() { throw error },
        function(rollbackError) { throw new Error(error.message + "; hotkey rollback failed: " + rollbackError.message) })
    })
  }

  function schedule() {
    if (initialized && ready && !disposed) reconcileTimer.restart()
  }

  function reconcile() {
    return enqueue(function() {
      return acquire().then(function() {
        var commands = settings()
        var ids = Object.keys(active)
        Object.keys(commands).forEach(function(id) { if (commands[id].hotkey && ids.indexOf(id) < 0) ids.push(id) })
        var work = Promise.resolve()
        ids.forEach(function(id) {
          work = work.then(function() {
            var desired = enabled(id) ? Hotkeys.normalize((settings()[id] || {}).hotkey) : null
            if (Hotkeys.identity(desired) === Hotkeys.identity(active[id] && active[id].hotkey)) return
            return apply(id, desired, false)
          }).catch(function(error) {
            var errors = Object.assign({}, failures)
            errors[id] = String(error.message || error)
            failures = errors
            lastError = errors[id]
            backend.emit("general.showToast", { style: "failure", title: "Hotkey: " + errors[id] })
          })
        })
        return work
      })
    }).catch(function(error) { lastError = String(error.message || error) })
  }

  function reloadBindings() {
    generation++
    acquired = false
    active = ({})
    schedule()
  }

  onReadyChanged: schedule()
  onIpcTargetChanged: {
    if (sessionTarget) Quickshell.execDetached(["hyprctl", "eval", Hotkeys.releaseLua(sessionTarget, owner)])
    reloadBindings()
  }
  onIpcConfigPathChanged: {
    if (sessionTarget) Quickshell.execDetached(["hyprctl", "eval", Hotkeys.releaseLua(sessionTarget, owner)])
    reloadBindings()
  }
  Component.onDestruction: {
    disposed = true
    generation++
    if (sessionTarget) Quickshell.execDetached(["hyprctl", "eval", Hotkeys.releaseLua(sessionTarget, owner)])
  }

  Connections {
    target: service.backend
    function onStoreRevisionChanged() { service.schedule() }
    function onCandidatesRevisionChanged() { service.schedule() }
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) { if (event.name === "configreloaded") service.reloadBindings() }
  }
  Timer { id: reconcileTimer; interval: 80; onTriggered: service.reconcile() }

  Component {
    id: runner
    Process {
      id: process
      property var argv
      property var resolveResult
      property var rejectResult
      property string output: ""
      property string errors: ""
      property bool finished: false
      command: argv
      function start() { deadline.start(); running = true }
      function finish(error) {
        if (finished) return
        finished = true
        deadline.stop()
        if (error) rejectResult(new Error(error))
        else resolveResult(output)
        destroy()
      }
      stdout: SplitParser { onRead: function(line) { process.output += line + "\n"; if (process.output.length > 1048576) { process.running = false; process.finish("Hyprland binding output exceeded 1 MiB") } } }
      stderr: SplitParser { onRead: function(line) { process.errors = (process.errors + line + "\n").slice(-4096) } }
      onExited: function(code, status) { finish(code !== 0 || status !== 0 ? errors.trim() || "hyprctl failed (" + code + ")" : "") }
      property Timer deadline: Timer {
        interval: 5000
        onTriggered: { process.running = false; process.finish("Hyprland hotkey request timed out") }
      }
    }
  }
}
