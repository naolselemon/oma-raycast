// [D] Hyprland 0.56 Lua bindings, not config-file rewrites. The compositor
// has no compare-and-swap bind API: callers serialize mutations, stage disabled,
// re-read binds, then atomically enable the new handle and disable the old one.
// Never call Keybind.remove()/hl.unbind: 0.56 removes every matching user bind.
var MODIFIERS = ["Ctrl", "Alt", "Shift", "Super"]
var MOD_MASKS = { Ctrl: 4, Alt: 8, Shift: 1, Super: 64 }
var KEY_NAMES = {
  space: "Space", enter: "Return", return: "Return", tab: "Tab", backtab: "Tab",
  escape: "Escape", esc: "Escape", backspace: "BackSpace", delete: "Delete", del: "Delete",
  insert: "Insert", home: "Home", end: "End", pageup: "PageUp", prior: "PageUp",
  pagedown: "PageDown", next: "PageDown", left: "Left", right: "Right", up: "Up", down: "Down",
  print: "Print", pause: "Pause", menu: "Menu",
  minus: "minus", equal: "equal", plus: "plus", comma: "comma", period: "period",
  slash: "slash", backslash: "backslash", semicolon: "semicolon", apostrophe: "apostrophe",
  bracketleft: "bracketleft", bracketright: "bracketright", grave: "grave",
  " ": "Space", "-": "minus", "=": "equal", "+": "plus", ",": "comma", ".": "period",
  "/": "slash", "\\": "backslash", ";": "semicolon", "'": "apostrophe", "[": "bracketleft",
  "]": "bracketright", "`": "grave"
}

function normalizeKey(key) {
  if (typeof key !== "string") throw new Error("Choose a keyboard key")
  if (typeof KEY_NAMES[key.toLowerCase()] === "string") return KEY_NAMES[key.toLowerCase()]
  if (/^[a-z0-9]$/i.test(key) || /^F([1-9]|[12][0-9]|3[0-5])$/i.test(key)) return key.toUpperCase()
  throw new Error("Unsupported hotkey key: " + key)
}

function normalize(value) {
  if (value === null || value === undefined || value === "") return null
  if (typeof value !== "object" || !Array.isArray(value.modifiers)) throw new Error("Hotkey must contain modifiers and a key")
  var selected = {}
  var aliases = { ctrl: "Ctrl", control: "Ctrl", alt: "Alt", shift: "Shift", super: "Super", meta: "Super" }
  value.modifiers.forEach(function(modifier) {
    var name = aliases[String(modifier).toLowerCase()]
    if (typeof name !== "string") throw new Error("Unsupported hotkey modifier: " + modifier)
    selected[name] = true
  })
  var key = normalizeKey(value.key)
  var modifiers = MODIFIERS.filter(function(name) { return selected[name] })
  if (!modifiers.length && !/^F\d+$/.test(key)) throw new Error("Use a modifier with this key")
  return { modifiers: modifiers, key: key }
}

function format(value) {
  var hotkey = normalize(value)
  return hotkey ? hotkey.modifiers.concat([hotkey.key]).join(" + ") : ""
}

function mask(value) {
  var hotkey = normalize(value)
  return hotkey ? hotkey.modifiers.reduce(function(result, name) { return result | MOD_MASKS[name] }, 0) : 0
}

function identity(value) { return value ? mask(value) + ":" + normalize(value).key.toLowerCase() : "" }

function fromKeyEvent(event) {
  var key = Number(event.key)
  if (key >= 0x01000020 && key <= 0x01000026) return null
  if (event.isAutoRepeat) return null
  var names = {
    16777216: "Escape", 16777217: "Tab", 16777218: "Tab", 16777219: "BackSpace",
    16777220: "Return", 16777221: "Return", 16777222: "Insert", 16777223: "Delete",
    16777224: "Pause", 16777225: "Print", 16777232: "Home", 16777233: "End",
    16777234: "Left", 16777235: "Up", 16777236: "Right", 16777237: "Down",
    16777238: "PageUp", 16777239: "PageDown", 16777301: "Menu"
  }
  var name = names[key] || (key >= 0x01000030 && key <= 0x01000052 ? "F" + (key - 0x01000030 + 1) : key >= 32 && key <= 126 ? String.fromCharCode(key) : "")
  var modifiers = []
  var bits = Number(event.modifiers)
  if (bits & 0x04000000) modifiers.push("Ctrl")
  if (bits & 0x08000000) modifiers.push("Alt")
  if (bits & 0x02000000) modifiers.push("Shift")
  if (bits & 0x10000000) modifiers.push("Super")
  return normalize({ modifiers: modifiers, key: name })
}

function prefix(target) {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/.test(target)) throw new Error("Invalid hotkey IPC target")
  return "oma-cast-command[" + target + "]:"
}

function conflicts(value, binds, ignoredDescriptions) {
  var hotkey = normalize(value)
  if (!hotkey) return []
  if (!Array.isArray(binds)) throw new Error("Hyprland returned an invalid binding list")
  var key = hotkey.key.toLowerCase()
  var modifiers = mask(hotkey)
  return binds.filter(function(bind) {
    if (ignoredDescriptions && ignoredDescriptions.indexOf(bind.description) >= 0) return false
    if (Number(bind.modmask) !== modifiers && !bind.ignore_mods) return false
    // Physical/chord binds cannot be resolved without the keyboard's XKB map.
    // Fail closed rather than claiming a potentially occupied key is free.
    if (Number(bind.keycode) > 0 || !bind.key || bind.catch_all) return true
    var name
    try { name = normalizeKey(String(bind.key)).toLowerCase() } catch (_) { name = String(bind.key).toLowerCase() }
    return name === key
  }).map(function(bind) {
    return { description: bind.description || bind.dispatcher || "Hyprland shortcut", key: bind.key,
      modmask: bind.modmask, submap: bind.submap || "", keycode: bind.keycode || 0 }
  })
}

function shellQuote(text) { return "'" + String(text).replace(/'/g, "'\\''") + "'" }
function luaString(text) {
  // Lua does not understand JSON's \u escapes. Decimal byte escapes are used
  // for ASCII controls; normal UTF-8 is passed literally by QProcess.
  return '"' + String(text).replace(/[\\"\x00-\x1f\x7f]/g, function(ch) {
    if (ch === "\\" || ch === '"') return "\\" + ch
    return "\\" + ("00" + ch.charCodeAt(0)).slice(-3)
  }) + '"'
}

function command(target, commandId, configPath) {
  prefix(target)
  if (typeof commandId !== "string" || !commandId || /[\x00-\x1f\x7f]/.test(commandId)) throw new Error("Invalid command id")
  if (configPath !== undefined && (typeof configPath !== "string" || /[\x00-\x1f\x7f]/.test(configPath))) throw new Error("Invalid hotkey IPC config path")
  var argv = configPath ? ["qs", "ipc", "-n", "-p", configPath, "call", "--", target, "run", commandId]
    : ["omarchy-shell", target, "run", commandId]
  return argv.map(shellQuote).join(" ")
}

function luaRoot(target) { prefix(target); return "_G[" + luaString("oma_cast_hotkeys:" + target) + "]" }

function acquireLua(target, owner) {
  var root = luaRoot(target)
  return "local s=" + root + "; if not s then s={handles={}}; " + root + "=s end; "
    + "for _,h in pairs(s.handles) do h:set_enabled(false) end; s.owner=" + luaString(owner)
}

function stageLua(target, owner, token, commandId, value, configPath) {
  var hotkey = normalize(value)
  if (!hotkey) throw new Error("Cannot register an empty hotkey")
  var symbol = hotkey.key === "PageUp" ? "Prior" : hotkey.key === "PageDown" ? "Next" : hotkey.key
  var keys = hotkey.modifiers.map(function(name) { return name.toUpperCase() }).concat([symbol]).join(" + ")
  var description = prefix(target) + token
  return "local s=" + luaRoot(target) + "; assert(s and s.owner==" + luaString(owner) + ", 'Hotkey session replaced'); "
    + "local h=hl.bind(" + luaString(keys) + ",hl.dsp.exec_cmd(" + luaString(command(target, commandId, configPath))
    + "),{description=" + luaString(description) + "}); assert(h and h.set_enabled, 'Could not register hotkey'); "
    + "h:set_enabled(false); s.handles[" + luaString(token) + "]=h"
}

function activateLua(target, owner, enableToken, disableToken) {
  return "local s=" + luaRoot(target) + "; assert(s and s.owner==" + luaString(owner) + ", 'Hotkey session replaced'); "
    + (enableToken ? "local h=s.handles[" + luaString(enableToken) + "]; assert(h and h:is_enabled()~=nil, 'Hotkey expired'); h:set_enabled(true); " : "")
    + (disableToken ? "local h=s.handles[" + luaString(disableToken) + "]; if h then h:set_enabled(false) end" : "")
}

function releaseLua(target, owner) {
  return "local s=" + luaRoot(target) + "; if s and s.owner==" + luaString(owner)
    + " then for _,h in pairs(s.handles) do h:set_enabled(false) end; s.owner=nil end"
}

if (typeof module !== "undefined") module.exports = {
  normalize: normalize, normalizeKey: normalizeKey, format: format, mask: mask, identity: identity,
  fromKeyEvent: fromKeyEvent, conflicts: conflicts, prefix: prefix, command: command, luaString: luaString,
  acquireLua: acquireLua, stageLua: stageLua, activateLua: activateLua, releaseLua: releaseLua
}
