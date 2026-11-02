// [D] Missing Phase 2 commands supplement, rather than duplicate, Omarchy's
// guarded power menu. Existing IDs retain their settings and confirmations.
var POWER_COMMANDS = {
  "omarchy:system.lock": ["omarchy-system-lock"],
  "omarchy:system.suspend": ["systemctl", "suspend"],
  "omarchy:system.hibernate": ["systemctl", "hibernate"],
  "omarchy:system.logout": ["omarchy-system", "logout"],
  "omarchy:system.reboot": ["omarchy-system", "reboot"],
  "omarchy:system.shutdown": ["omarchy-system", "shutdown"],
  "omarchy:system.screensaver": ["omarchy-launch-screensaver", "force"]
}
var POWER_IDS = Object.keys(POWER_COMMANDS)
var DEFINITIONS = [
  ["toggle-mute", "Toggle Mute", "sound speaker audio unmute", "volume"],
  ["volume-up", "Turn Volume Up", "sound speaker audio increase louder", "volume"],
  ["volume-down", "Turn Volume Down", "sound speaker audio decrease quieter", "volume"],
  ["volume-0", "Set Volume to 0%", "sound speaker audio silent", "volume"],
  ["volume-25", "Set Volume to 25%", "sound speaker audio", "volume"],
  ["volume-50", "Set Volume to 50%", "sound speaker audio", "volume"],
  ["volume-75", "Set Volume to 75%", "sound speaker audio", "volume"],
  ["volume-100", "Set Volume to 100%", "sound speaker audio maximum", "volume"],
  ["set-volume", "Set Volume…", "sound speaker audio custom percentage", "volume"],
  ["toggle-microphone-mute", "Toggle Microphone Mute", "mic input audio unmute", "volume"],
  ["play-pause", "Play/Pause", "media music playback pause resume", "media"],
  ["next-track", "Next Track", "media music playback skip", "media"],
  ["previous-track", "Previous Track", "media music playback back", "media"],
  ["toggle-appearance", "Toggle System Appearance", "theme dark light mode", "appearance"],
  ["sleep-displays", "Sleep Displays", "screen monitor power off dpms", "power"],
  ["audio-panel", "Volume Mixer", "sound audio output input device microphone speakers headphones", "volume"]
]

function candidates() {
  return DEFINITIONS.map(function(definition) {
    var candidate = {
      id: "system:" + definition[0], type: "command", kind: "system-action",
      title: definition[1], subtitle: "System", keywords: definition[2].split(" "),
      typeLabel: "System", glyph: "\uf013", rootSearch: { when: "always" }
    }
    if (definition[0] === "set-volume") candidate.arguments = [
      { name: "volume", placeholder: "Volume (0–100)", type: "text", required: true }
    ]
    if (definition[0] === "audio-panel") candidate.subtitle = "Output/input devices and per-app volume"
    return candidate
  })
}

function handles(id) {
  if (Object.prototype.hasOwnProperty.call(POWER_COMMANDS, id)) return true
  return DEFINITIONS.some(function(definition) { return id === "system:" + definition[0] })
}

function confirmationFor(id) {
  var names = {
    "omarchy:system.logout": ["Log Out", "log out"],
    "omarchy:system.reboot": ["Restart", "restart"],
    "omarchy:system.shutdown": ["Shut Down", "shut down"]
  }
  var name = Object.prototype.hasOwnProperty.call(names, id) ? names[id] : null
  return name ? { title: name[0], message: "Are you sure you want to " + name[1] + "?", primary: name[0], destructive: true } : null
}

function volumeValue(value) {
  if (typeof value !== "number" && typeof value !== "string") throw new Error("Enter a volume from 0 to 100")
  var text = String(value).trim()
  if (!/^(?:\d+(?:\.\d+)?|\.\d+)\s*%?$/.test(text)) throw new Error("Enter a volume from 0 to 100")
  var number = Number(text.replace(/\s*%$/, ""))
  if (!isFinite(number) || number < 0 || number > 100) throw new Error("Volume must be between 0 and 100")
  return number
}

function selectPlayer(players, method) {
  var selected = null
  for (var i = 0; i < players.length; i++) {
    var player = players[i]
    if (!player || !player.dbusName) continue
    if (!selected || (player.isPlaying && !selected.isPlaying)) selected = player
  }
  if (!selected) throw new Error("No media player is running")
  var supported = selected.canControl && (method === "Next" ? selected.canGoNext
    : method === "Previous" ? selected.canGoPrevious
    : selected.isPlaying ? selected.canPause : selected.canPlay)
  if (!supported) throw new Error((selected.identity || "The active media player") + " does not support this playback action")
  return selected
}

function plan(id, data, players) {
  if (!handles(id)) throw new Error("Unknown system action " + id)
  if (Object.prototype.hasOwnProperty.call(POWER_COMMANDS, id)) return { argv: POWER_COMMANDS[id].slice(), power: true }
  var sink = "@DEFAULT_AUDIO_SINK@"
  if (id === "system:toggle-mute") return { argv: ["wpctl", "set-mute", sink, "toggle"] }
  if (id === "system:toggle-microphone-mute") return { argv: ["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"] }
  if (id === "system:volume-up" || id === "system:volume-down")
    return { argv: ["wpctl", "set-volume", "--limit", "1", sink, id === "system:volume-up" ? "5%+" : "5%-"] }
  if (id === "system:set-volume" || /^system:volume-\d+$/.test(id)) {
    var value = volumeValue(id === "system:set-volume" ? data && data.arguments && data.arguments.volume : id.slice("system:volume-".length))
    return { argv: ["wpctl", "set-volume", sink, String(value) + "%"], message: "Volume set to " + value + "%" }
  }
  if (id === "system:play-pause" || id === "system:next-track" || id === "system:previous-track") {
    var method = id === "system:play-pause" ? "PlayPause" : id === "system:next-track" ? "Next" : "Previous"
    var player = selectPlayer(players || [], method)
    return { argv: ["gdbus", "call", "--session", "--timeout", "10", "--dest", player.dbusName,
      "--object-path", "/org/mpris/MediaPlayer2", "--method", "org.mpris.MediaPlayer2.Player." + method] }
  }
  if (id === "system:sleep-displays") return { argv: ["hyprctl", "dispatch", 'hl.dsp.dpms({ action = "disable" })'], power: true }
  if (id === "system:audio-panel") return { argv: ["omarchy-shell", "shell", "summon", "omarchy.audio"], panel: true }
  return { appearance: true }
}

// A fixed script checks executable availability before exec, so Process gets an
// exit status and useful stderr even when the requested tool is not installed.
var EXEC_SCRIPT = 'if ! command -v "$1" >/dev/null 2>&1; then printf "Required command is not installed: %s\\n" "$1" >&2; exit 127; fi; exec "$@"'

// [D] Omarchy mode belongs to a theme, not a separate gsettings preference.
// Prefer the last theme used for each mode during this shell session; otherwise
// choose the first installed opposite-mode theme, respecting user overrides.
var APPEARANCE_SCRIPT = [
  'set -e',
  'export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"',
  'for tool in omarchy-theme-color omarchy-theme-set; do command -v "$tool" >/dev/null || { printf "Required command is not installed: %s\\n" "$tool" >&2; exit 127; }; done',
  'current="$HOME/.local/state/omarchy/current/theme"',
  '[[ -r "$current/colors.toml" ]] || { echo "The active Omarchy theme has no colors.toml" >&2; exit 1; }',
  'mode=$(omarchy-theme-color --file "$current/colors.toml" mode)',
  'case "$mode" in dark) target=light; preferred=$1 ;; light) target=dark; preferred=$2 ;; *) echo "The active Omarchy theme has no valid light/dark mode" >&2; exit 1 ;; esac',
  'name=$(cat "$HOME/.local/state/omarchy/current/theme.name")',
  'printf "OMA_THEME_CURRENT\\t%s\\t%s\\n" "$mode" "$name"',
  'chosen=""',
  'check_theme() {',
  '  local name="$1" path',
  '  [[ -n "$name" && "$name" != */* && "$name" != . && "$name" != .. ]] || return 1',
  '  path="$HOME/.config/omarchy/themes/$name"',
  '  [[ -d "$path" ]] || path="$OMARCHY_PATH/themes/$name"',
  '  [[ -r "$path/colors.toml" ]] || return 1',
  '  [[ $(omarchy-theme-color --file "$path/colors.toml" mode) == "$target" ]] || return 1',
  '  chosen="$name"',
  '}',
  'if ! check_theme "$preferred"; then',
  '  for path in "$HOME"/.config/omarchy/themes/* "$OMARCHY_PATH"/themes/*; do',
  '    [[ -d "$path" ]] || continue',
  '    if check_theme "${path##*/}"; then break; fi',
  '  done',
  'fi',
  '[[ -n "$chosen" ]] || { printf "No installed %s Omarchy theme was found\\n" "$target" >&2; exit 1; }',
  'omarchy-theme-set "$chosen"',
  '[[ $(omarchy-theme-color mode) == "$target" ]] || { echo "Omarchy did not switch to the requested appearance" >&2; exit 1; }',
  'printf "OMA_THEME_APPLIED\\t%s\\t%s\\n" "$target" "$chosen"'
].join("\n")

function completionMessage(candidate, actionPlan, exitCode, exitStatus, stderr, stdout) {
  if (exitCode !== 0 || exitStatus !== 0) return { style: "failure", title: candidate.title + " failed: " +
    (String(stderr || "").trim() || String(stdout || "").replace(/^OMA_THEME_[^\n]*\n?/gm, "").trim()
      || "command exited with status " + exitCode).slice(0, 600) }
  // omarchy-shell reports routing failure as text on some shell versions.
  if (actionPlan.panel && /^(?:false|error\b|unknown\b|not found\b)/i.test(String(stdout || "").trim()))
    return { style: "failure", title: "The Omarchy audio panel is unavailable: " + String(stdout).trim().slice(0, 300) }
  return { style: "success", title: actionPlan.message || (actionPlan.power ? "Requested: " : "Completed: ") + candidate.title }
}

if (typeof module !== "undefined") module.exports = {
  POWER_IDS: POWER_IDS, candidates: candidates, handles: handles, confirmationFor: confirmationFor,
  volumeValue: volumeValue, selectPlayer: selectPlayer, plan: plan,
  EXEC_SCRIPT: EXEC_SCRIPT, APPEARANCE_SCRIPT: APPEARANCE_SCRIPT, completionMessage: completionMessage
}
