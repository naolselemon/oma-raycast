// Pure metadata, argument and bounded output handling shared by QML and Node.
var MAX_FILE_SIZE = 2 * 1024 * 1024
var OUTPUT_LIMIT = 128 * 1024
var COLORS = ["#242424", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#dddddd", "#777777", "#ff8088", "#b5e890", "#ffdc98", "#90c8ff", "#e6a0ff", "#8ce5ec", "#ffffff"]

function decodeRecord(value) {
  var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  var bits = 0, count = 0, encoded = "", fallback = ""
  for (var i = 0; i < value.length; i++) {
    var digit = alphabet.indexOf(value.charAt(i))
    if (digit < 0) continue
    bits = (bits << 6) | digit
    count += 6
    if (count >= 8) {
      count -= 8
      var byte = (bits >> count) & 255
      encoded += "%" + ("0" + byte.toString(16)).slice(-2)
      fallback += String.fromCharCode(byte)
    }
  }
  try { return decodeURIComponent(encoded) } catch (error) { return fallback }
}

function resolvePath(base, value) {
  var parts = (String(value || "").charAt(0) === "/" ? value : base + "/" + (value || ".")).split("/")
  var result = []
  parts.forEach(function(part) { if (part === "..") result.pop(); else if (part && part !== ".") result.push(part) })
  return "/" + result.join("/")
}
function eligible(name, size, executable, directory) {
  return !directory && executable && size > 0 && size <= MAX_FILE_SIZE && name.indexOf(".template.") < 0
}
function refreshInterval(value) {
  var match = /^(\d+)(s|m|h|d)$/.exec(String(value || ""))
  if (!match) throw new Error("refreshTime must use seconds, minutes, hours or days (for example 30s)")
  return Math.max(10000, Number(match[1]) * {s: 1000, m: 60000, h: 3600000, d: 86400000}[match[2]])
}
function parse(path, text) {
  var header = Object.create(null)
  String(text).split(/\r?\n/).forEach(function(line) {
    var match = /^(?:#|REM|::|\/{2})\s*@raycast\.(\w+)\s+(.*)/i.exec(line)
    if (match) header[match[1].toLowerCase()] = match[2].trim()
  })
  if (!Object.keys(header).length) return null
  if (header.schemaversion !== "1") throw new Error("schemaVersion must be 1")
  if (!header.title) throw new Error("title is required")
  var mode = header.mode === "full-output" ? "fullOutput" : header.mode
  if (["fullOutput", "compact", "silent", "inline"].indexOf(mode) < 0) throw new Error("mode must be fullOutput, compact, silent or inline")
  if (mode === "inline" && !header.refreshtime) mode = "compact"
  var directory = path.slice(0, path.lastIndexOf("/"))
  var args = []
  if (mode !== "inline") {
    for (var i = 1; i <= 3; i++) {
      if (!header["argument" + i]) continue
      var arg
      try { arg = JSON.parse(header["argument" + i]) } catch (error) { throw new Error("argument" + i + " must contain valid JSON") }
      if (!arg || ["text", "password", "dropdown"].indexOf(arg.type) < 0) throw new Error("argument" + i + " has an unsupported type")
      if (arg.type === "dropdown" && (!Array.isArray(arg.data) || !arg.data.length || arg.data.some(function(entry) { return !entry || typeof entry.title !== "string" || typeof entry.value !== "string" }))) throw new Error("Dropdown arguments need title/value choices")
      args.push({name: "argument" + i, position: i - 1, type: arg.type, placeholder: String(arg.placeholder || "Argument " + i), optional: arg.optional === true, required: arg.optional !== true, secure: arg.secure === true || arg.type === "password", percentEncoded: arg.percentEncoded === true, data: arg.data || []})
    }
  }
  return {id: "script:" + path, path: path, title: header.title, mode: mode, packageName: header.packagename || directory.split("/").pop().replace(/[-_]/g, " ").replace(/\b\w/g, function(c) { return c.toUpperCase() }), description: header.description || "", author: header.author || "", authorURL: header.authorurl || "", icon: header.icon || "", iconDark: header.icondark || "", cwd: resolvePath(directory, header.currentdirectorypath), needsConfirmation: mode !== "inline" && header.needsconfirmation === "true", refreshTime: mode === "inline" ? refreshInterval(header.refreshtime) : 0, arguments: args}
}
function argumentsFor(script, values) {
  if (script.mode === "inline") return []
  values = values || {}
  var out = []
  script.arguments.forEach(function(arg) {
    var value = Array.isArray(values) ? values[arg.position] : values[arg.name]
    value = value === undefined || value === null ? "" : String(value)
    if (!arg.optional && !value) throw new Error(arg.placeholder + " is required")
    if (value && arg.type === "dropdown" && !arg.data.some(function(entry) { return entry.value === value })) throw new Error("Choose a valid " + arg.placeholder)
    if (value.indexOf("\0") >= 0) throw new Error("Arguments cannot contain NUL")
    while (out.length <= arg.position) out.push("")
    out[arg.position] = arg.percentEncoded ? encodeURIComponent(value) : value
  })
  return out
}
function candidate(script, subtitle) {
  return {id: script.id, type: "command", kind: "script", title: script.title, subtitle: subtitle === undefined ? script.description || script.packageName : subtitle, keywords: [script.packageName, script.description, script.author], typeLabel: "Script Command", glyph: "›_", rootSearch: {when: "always"}, arguments: script.arguments, script: script}
}
function outputState() { return {segments: [], size: 0, truncated: false, firstLine: null, lastLine: "", pendingLine: "", ansi: "", color: "", bold: false} }
function appendOutput(state, input, stderr) {
  // Strip every terminal control except SGR; rendered segments are always PlainText.
  var text = state.ansi + String(input)
  state.ansi = ""
  var plain = "", visible = "", i = 0
  function flush() {
    if (!plain) return
    var color = state.color || (stderr ? COLORS[1] : "")
    var previous = state.segments[state.segments.length - 1]
    if (previous && previous.color === color && previous.bold === state.bold) previous.text += plain
    else state.segments.push({text: plain, color: color, bold: state.bold})
    state.size += plain.length
    visible += plain
    plain = ""
  }
  while (i < text.length) {
    if (text.charCodeAt(i) !== 27) {
      var ch = text.charAt(i++)
      if (ch === "\n" || ch === "\t" || ch >= " " && ch !== "\x7f") plain += ch
      continue
    }
    flush()
    var rest = text.slice(i)
    var csi = /^\x1b\[([0-9;?]*)([ -\/]*)([@-~])/.exec(rest)
    if (csi) {
      if (csi[3] === "m") {
        var codes = (csi[1] || "0").split(";").map(Number)
        for (var n = 0; n < codes.length; n++) {
          var code = codes[n]
          if (code === 0) { state.color = ""; state.bold = false }
          else if (code === 1) state.bold = true
          else if (code === 22) state.bold = false
          else if (code === 39) state.color = ""
          else if (code >= 30 && code <= 37) state.color = COLORS[code - 30]
          else if (code >= 90 && code <= 97) state.color = COLORS[code - 90 + 8]
          else if ((code === 38 || code === 48) && codes[n + 1] === 2 && n + 4 < codes.length) {
            if (code === 38) state.color = "#" + codes.slice(n + 2, n + 5).map(function(v) { return ("0" + Math.max(0, Math.min(255, v)).toString(16)).slice(-2) }).join("")
            n += 4
          } else if ((code === 38 || code === 48) && codes[n + 1] === 5 && n + 2 < codes.length) {
            var index = Math.max(0, Math.min(255, codes[n + 2]))
            if (code === 38) {
              if (index < 16) state.color = COLORS[index]
              else {
                var rgb = index < 232 ? [Math.floor((index - 16) / 36), Math.floor((index - 16) / 6) % 6, (index - 16) % 6].map(function(v) { return v ? 55 + v * 40 : 0 }) : [8 + (index - 232) * 10, 8 + (index - 232) * 10, 8 + (index - 232) * 10]
                state.color = "#" + rgb.map(function(v) { return ("0" + v.toString(16)).slice(-2) }).join("")
              }
            }
            n += 2
          }
        }
      }
      i += csi[0].length
    } else if (rest.charAt(1) === "]") {
      var end = /\x07|\x1b\\/.exec(rest)
      if (!end) { state.ansi = rest.slice(0, 2048); break }
      i += end.index + end[0].length
    } else if (rest.length < 2 || rest.charAt(1) === "[" && rest.length < 128) { state.ansi = rest; break }
    else i += 2
  }
  flush()
  var lines = (state.pendingLine + visible).split("\n")
  state.pendingLine = lines.pop().slice(-4096)
  lines.forEach(function(line) { if (state.firstLine === null) state.firstLine = line.slice(0, 4096); if (line.trim()) state.lastLine = line.slice(-4096) })
  while (state.size > OUTPUT_LIMIT || state.segments.length > 2048) {
    var first = state.segments[0]
    var count = Math.min(first.text.length, Math.max(state.size - OUTPUT_LIMIT, state.segments.length > 2048 ? first.text.length : 0))
    first.text = first.text.slice(count); state.size -= count; state.truncated = true
    if (!first.text) state.segments.shift()
  }
  return state
}
function finishOutput(state) {
  if (state.firstLine === null) state.firstLine = state.pendingLine
  if (state.pendingLine.trim()) state.lastLine = state.pendingLine
  return state
}
function template(data) {
  var title = String(data.title || "").trim()
  if (!title || /[\r\n\0]/.test(title)) throw new Error("Enter a single-line script title")
  var mode = String(data.mode || "fullOutput")
  if (["fullOutput", "compact", "silent", "inline"].indexOf(mode) < 0) throw new Error("Choose a script mode")
  var language = data.language || "bash"
  if (["bash", "python"].indexOf(language) < 0) throw new Error("Choose Bash or Python")
  var header = "# @raycast.schemaVersion 1\n# @raycast.title " + title + "\n# @raycast.mode " + mode + "\n" + (mode === "inline" ? "# @raycast.refreshTime 1m\n" : "")
  return language === "python" ? "#!/usr/bin/env python3\n" + header + "\nfrom datetime import datetime\n\nprint(datetime.now().strftime(\"%A, %d %B %Y — %H:%M\"))\n" : "#!/usr/bin/env bash\n" + header + "\nset -euo pipefail\ndate '+%A, %d %B %Y — %H:%M'\n"
}
if (typeof module !== "undefined") module.exports = {MAX_FILE_SIZE: MAX_FILE_SIZE, OUTPUT_LIMIT: OUTPUT_LIMIT, decodeRecord: decodeRecord, resolvePath: resolvePath, eligible: eligible, refreshInterval: refreshInterval, parse: parse, argumentsFor: argumentsFor, candidate: candidate, outputState: outputState, appendOutput: appendOutput, finishOutput: finishOutput, template: template}
