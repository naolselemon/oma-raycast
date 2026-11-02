import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "../core/Rpc.js" as Rpc
import "../core/Quicklinks.js" as Quicklinks
import "../core/Placeholders.js" as Placeholders

Item {
  id: service
  required property var backend
  property var candidates: []
  readonly property bool ready: store.loaded && !store.readOnly
  property int revision: 0
  property bool running: false

  JsonStore {
    id: store
    path: service.backend.paths.db + "/quicklinks.json"
    migrations: Quicklinks.migrations
    ready: service.backend.directoriesReady
    onChanged: service.refresh()
    onMessage: function(level, text, metadata) {
      service.backend.log(level, "quicklinks", text, metadata)
      if (level === "error") service.backend.emit("general.showToast", { style: "failure", title: text })
    }
  }
  function preferences() {
    var result = backend.callSync("settings.getQuicklinkPreferences", null)
    return result.ok ? result.data : { showPreviews: true, passSelectedTextAsArgument: false }
  }
  function refresh() {
    revision++
    if (!store.loaded) { candidates = []; return }
    try {
      candidates = Quicklinks.rows(store.doc).map(function(row) { return Quicklinks.candidate(row, Placeholders, service.preferences().showPreviews) })
    } catch (e) {
      store.readOnly = true; store.lastError = String(e); candidates = []
      backend.emit("general.showToast", { style: "failure", title: "Quicklinks: " + e })
    }
    backend.emit("quicklinks.updated", { count: candidates.length })
  }
  function newId() { return Date.now().toString(36) + "-" + Math.random().toString(36).slice(2) }
  function change(operation) { return Quicklinks.mutate(store, operation) }
  function requireLoaded() { if (!store.loaded) throw new Error(store.lastError || "Quicklinks are still loading") }
  function initialize() {
    Rpc.register(backend.registry, "quicklinks", {
      list: function(data) {
        service.requireLoaded()
        var query = String(data && data.query || "").toLowerCase()
        return Quicklinks.rows(store.doc).filter(function(row) { return !query || (row.name + " " + row.link + " " + row.tags.join(" ")).toLowerCase().indexOf(query) >= 0 })
      },
      getQuicklink: function(data) { service.requireLoaded(); return Quicklinks.find(store.doc, data.id) },
      save: function(data) { return service.change(function(doc) { return Quicklinks.save(doc, data, Placeholders, service.newId, Date.now(), false) }) },
      update: function(data) { return service.change(function(doc) { return Quicklinks.save(doc, Object.assign({}, Quicklinks.find(doc, data.id), data), Placeholders, service.newId, Date.now(), true) }) },
      delete: function(data) {
        if (data.confirmed !== true) throw new Error("Confirm deletion first")
        return service.change(function(doc) { var item = Quicklinks.find(doc, data.id); doc.items.splice(doc.items.indexOf(item), 1); return { deleted: item.id } })
      },
      getTags: function() { service.requireLoaded(); var tags = []; Quicklinks.rows(store.doc).forEach(function(row) { row.tags.forEach(function(tag) { if (tags.indexOf(tag) < 0) tags.push(tag) }) }); return tags.sort() },
      import: function(data) {
        if (!data.path || data.path[0] !== "/") throw new Error("Choose an absolute local JSON file path")
        return service.run(["cat", "--", data.path]).then(function(text) { return service.change(function(doc) { return Quicklinks.importJson(doc, text, Placeholders, service.newId, Date.now()) }) })
      },
      export: function(data) {
        service.requireLoaded()
        if (!data.path || data.path[0] !== "/") throw new Error("Choose an absolute local JSON file path")
        var text = Quicklinks.exportJson(store.doc, data.id)
        // Fixed program; all user content is positional argv. Noclobber is atomic for new files.
        var script = data.confirmed === true ? 'set -eu; tmp=$(mktemp -- "${1}.XXXXXX"); trap \'rm -f -- "$tmp"\' EXIT; printf "%s" "$2" > "$tmp"; mv -f -- "$tmp" "$1"' : 'set -euC; umask 077; printf "%s" "$2" > "$1"'
        return service.run(["bash", "-c", script, "oma-cast-export", data.path, text]).then(function() { return { path: data.path } })
      },
      preview: function(data) { service.requireLoaded(); return { text: Quicklinks.find(store.doc, data.id).link, network: false } },
      fetchFavicon: function(data) {
        if (!data || data.confirmed !== true) throw new Error("Confirm contacting this website to fetch its favicon")
        if (!service.backend.directoriesReady) throw new Error("Favicon cache directory is not ready")
        var request = Quicklinks.faviconRequest(data.link, service.backend.paths.cache, service.newId())
        return service.run(request.argv).then(function(status) {
          if (status.trim() !== "200") throw new Error("Favicon request returned HTTP " + status.trim() + "; redirects are not followed")
          return { icon: request.path, url: request.url }
        }).catch(function(error) {
          return service.run(["rm", "-f", "--", request.path]).then(function() { throw error }, function() { throw error })
        })
      },
      applications: function() { return service.backend.appEntries().map(function(app) { return { id: app.id, name: app.name, icon: String(app.icon || "") } }) }
    })
    backend.subscribe("settings.quicklinkPreferencesChanged", function() { service.refresh() })
  }
  Component {
    id: processComponent
    Item {
      id: job
      property alias command: process.command
      property alias running: process.running
      property var resolveResult
      property var rejectResult
      property bool settled: false
      property bool started: false
      function fail(message) { if (settled) return; settled = true; process.running = false; rejectResult(new Error(message)); destroy() }
      Timer {
        interval: 1500
        running: true
        onTriggered: if (!job.started) job.fail("Cannot start " + job.command[0])
      }
      Process {
        id: process
        stdout: StdioCollector { id: output }
        stderr: StdioCollector { id: errors }
        onStarted: job.started = true
        onExited: function(code) {
          if (job.settled) return
          job.settled = true
          if (code === 0) job.resolveResult(output.text)
          else job.rejectResult(new Error(errors.text.trim() || "Command failed (" + code + "): " + command[0]))
          job.destroy()
        }
      }
    }
  }
  function run(argv) {
    return new Promise(function(resolve, reject) {
      var process = processComponent.createObject(service, { command: argv, resolveResult: resolve, rejectResult: reject })
      if (!process) { reject(new Error("Cannot create process")); return }
      process.running = true
    })
  }
  function formatDate(date, kind, format, localeName) {
    var locale = localeName ? Qt.locale(localeName.replace(/-/g, "_")) : Qt.locale()
    if (localeName && locale.name === "C" && localeName !== "C") throw new Error("Unknown locale: " + localeName)
    if (!format) {
      if (kind === "day") return locale.dayName(date.getDay() || 7, Locale.LongFormat)
      if (kind === "date") return date.toLocaleDateString(locale, Locale.ShortFormat)
      if (kind === "time") return date.toLocaleTimeString(locale, Locale.ShortFormat)
      return date.toLocaleString(locale, Locale.ShortFormat)
    }
    // Qt shares the common Unicode date fields; translate differing weekday/AM-PM tokens.
    var translated = "", quoted = false
    for (var i = 0; i < format.length;) {
      var c = format[i]
      if (c === "'") { translated += c; quoted = !quoted; i++; continue }
      if (quoted || !/[A-Za-z]/.test(c)) { translated += c; i++; continue }
      var end = i + 1; while (end < format.length && format[end] === c) end++
      var token = format.slice(i, end)
      if (c === "E") translated += token.length >= 4 ? "dddd" : "ddd"
      else if (c === "a") translated += "AP"
      else if (c === "S" && token.length <= 3) translated += token.length === 3 ? "zzz" : "z"
      else if ("yMdHhms".indexOf(c) >= 0) translated += token
      else throw new Error("Unsupported date format token: " + token)
      i = end
    }
    if (quoted) throw new Error("Unclosed date format literal")
    return date.toLocaleString(locale, translated)
  }
  function actions(candidate) {
    return [
      { id: "quicklink-edit", title: "Edit Quicklink" },
      { id: "quicklink-delete", title: "Delete Quicklink", destructive: true },
      { id: "quicklink-export", title: "Export Quicklink" },
      { id: "quicklink-import", title: "Import Quicklinks" }
    ]
  }
  function execute(candidate, data) {
    data = data || {}
    var action = data.action || "open", id = candidate.quicklinkId || candidate.id.slice(10)
    if (action === "quicklink-edit") return { quicklinks: { mode: "edit", id: id } }
    if (action === "quicklink-export") return { quicklinks: { mode: "export", id: id } }
    if (action === "quicklink-import") return { quicklinks: { mode: "import" } }
    if (action === "quicklink-delete") return { quicklinks: { mode: "delete", id: id } }
    if (action !== "open") throw new Error("Unknown quicklink action: " + action)
    requireLoaded()
    if (!ready) throw new Error(store.lastError || "Quicklinks storage is read-only")
    if (running) throw new Error("A quicklink is already opening")
    var row = Quicklinks.find(store.doc, id), parsed = Placeholders.parse(row.link)
    var values = Object.assign({}, data.arguments || {}), env = { nowMs: Date.now(), formatDate: service.formatDate,
      calculate: function(expression) { var result = service.backend.calculate(expression); if (!result) throw new Error("Invalid calculator expression: " + expression); return result.copy } }
    var selected = !!data.hotkey && parsed.arguments.length === 1 && preferences().passSelectedTextAsArgument && !values[parsed.arguments[0].name]
    var work = Promise.resolve()
    if (Placeholders.needs(parsed, "clipboard")) work = work.then(function() { return service.run(["wl-paste", "--no-newline"]).then(function(text) { env.clipboard = text }) })
    if (selected || Placeholders.needs(parsed, "selection")) work = work.then(function() { return service.run(["wl-paste", "--primary", "--no-newline"]).then(function(text) { env.selection = text; if (selected) values[parsed.arguments[0].name] = text }) })
    if (Placeholders.needs(parsed, "uuid")) work = work.then(function() { return service.run(["cat", "/proc/sys/kernel/random/uuid"]).then(function(text) { env.uuid = text.trim() }) })
    running = true
    work.then(function() {
      var expanded = Placeholders.resolve(parsed, values, env)
      var argv = Quicklinks.launchArgv(row, expanded, Quickshell.env("HOME"))
      service.backend.emit("general.closeMainWindow", {})
      return service.run(argv)
    }).then(function() {
      service.change(function(doc) { var current = Quicklinks.find(doc, id); current.openCount = (current.openCount || 0) + 1; current.updatedAt = Date.now() })
      service.backend.recordVisit(candidate.id, data.query || "")
      service.running = false
      service.backend.emit("general.showToast", { style: "success", title: "Opened " + row.name })
    }).catch(function(error) { service.running = false; service.backend.emit("general.showToast", { style: "failure", title: String(error) }) })
    return { pending: true }
  }
}
