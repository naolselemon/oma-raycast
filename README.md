<div align="center">

# oma-cast

**A Raycast-esque launcher for [Omarchy](https://omarchy.org).**
It learns what you use, searches your apps and every Omarchy action, and looks like it shipped with your theme.

<img src="docs/screenshots/hero.png" alt="oma-cast showing suggestions for apps and Omarchy commands" width="760">

</div>

---

## Why

Omarchy's built-in menu is great at what it does. oma-cast adds what Raycast users miss on Linux:

* **Learns your habits.** Results are ranked with a port of Raycast's root-search algorithm, plus frecency and learned search terms. The things you actually use float to the top, and if you type `ff` and pick Firefox, `ff` keeps meaning Firefox.
* **One search for everyday work.** Apps, ~400 Omarchy menu actions, quicklinks, Script Commands, calculator results, configurable web fallbacks, and an explicit hand-off to your default coding agent.
* **Your shortcuts.** Give commands aliases and global hotkeys, pin favorites, and disable or re-enable commands in Settings.
* **Keyboard-first.** A Ctrl+K action panel, Ctrl+1–9 quick picks, search history on ↑, section jumping, and emacs-style navigation.
* **Native to Omarchy.** It runs inside `omarchy-shell`, with QML interfaces and no Electron or Node runtime. It follows your Omarchy theme live.

## Screenshots

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/search.png" alt="Searching 'screen' shows Omarchy actions with breadcrumbs"></td>
    <td width="50%"><img src="docs/screenshots/actions.png" alt="The Ctrl+K action panel"></td>
  </tr>
  <tr>
    <td align="center"><b>Every Omarchy action, with breadcrumbs</b></td>
    <td align="center"><b>Ctrl+K: actions for any result</b></td>
  </tr>
</table>

<p align="center">
  <img src="docs/screenshots/fallbacks.png" alt="Web-search fallbacks under the results" width="49%">
</p>
<p align="center"><b>No match? Send the query to Google or DuckDuckGo</b></p>

### Follows your Omarchy theme

There's no theme config. oma-cast binds to Omarchy's own colours, so it changes the moment you switch themes.

<img src="docs/screenshots/themes.png" alt="oma-cast in Tokyo Night, Gruvbox, Rose Pine, Flexoki Light, Everforest and Osaka Jade">

## Install

Requires Omarchy 4 (Hyprland 0.56+, `omarchy-shell`) and `socat`, which Omarchy already ships.

```sh
git clone https://github.com/typecraft-dev/oma-cast.git
cd oma-cast
bin/oma-cast install          # build search if cargo is installed, then link and enable the plugin
oma-cast setup hyprland       # bind Alt+Space
oma-cast doctor               # check everything is wired up
```

With Rust (`cargo`) installed, installation builds the small **flea-search** helper locally. It matches titles,
alternate names, subtitles and keywords outside the shell's UI thread and tolerates transposed or missing letters.
Aliases, favorites, learned terms and frecency stay in oma-cast's existing ranker. Without Rust, installation keeps
the built-in matcher; install Rust and run `oma-cast build-search`, then `oma-cast reload`, to enable acceleration.
Run `tests/native-transport.sh` on Omarchy to check the real native transport, process failures and timeout fallback.
No binary download or background system service is required. If the helper fails or times out, search falls back
to the built-in matcher until the plugin reloads. The synchronous `rootSearch.search` IPC stays compatible.

Press **Alt+Space**. Super+Space stays the Omarchy menu. You can change the launcher binding in `~/.config/hypr/oma-cast.lua`.

To remove it: `oma-cast uninstall`.

## Ask your default agent

Type a question, select **Ask default agent** under the web-search fallbacks,
and press Enter. **Ctrl+Alt+Enter** sends the current root-search text directly.
This opens a new session with your question in Omarchy's configured default
agent and terminal (Foot, Ghostty, Kitty or Alacritty).

The action checks your setup first. Missing agent/terminal setup leaves the
launcher open with your question and an error. Closing the launcher during the
check cancels the pending hand-off. Normal app search and Enter selection keep
working as before; typing alone never submits a question.

Requires an Omarchy version with `omarchy-agent-prompt` and
`omarchy-agent --prompt` (verified against `quattro` revision `3ac4365`). Select
your defaults in Omarchy Settings. Agent authentication, accounts, approval
behaviour, session working directory and terminal selection remain owned by
Omarchy and the agent CLI. oma-cast does not store the question in search history,
read credentials, or make model API calls. Successful preflight checks establish
launch prerequisites, not successful sign-in or a running terminal; those still
need live desktop validation.

## Settings and everyday commands

Open **Settings** from search, press **Ctrl+,**, or run `oma-cast settings`.
The Commands / Extensions page includes disabled commands: select one, edit its
alias, enabled state or hotkey, then **Save**. Shortcut conflicts reject the whole
edit without replacing your existing desktop binding. Hotkeys use Hyprland 0.56's
Lua API and are restored after compositor reloads; no Hyprland config files are rewritten.

**Quicklinks:** search for **Create Quicklink** and save a URL such as
`https://duckduckgo.com/?q={query}`. Its argument appears as a pill in search.
Use Tab to move between arguments; dropdowns support arrow keys. Templates also
support defaults, the current clipboard/selection, dates, UUIDs, calculator
expressions and modifiers. Search Quicklinks opens the dedicated list; its actions
offer editing, deletion and local JSON import/export. Favicon fetching is optional,
confirmed, and contacts only the supplied website's `/favicon.ico`, without redirects.
Launcher Settings lets you enable and order Google, DuckDuckGo, Bing, provider
searches and single-argument quicklinks as fallbacks. HTTP(S) queries also offer
Open URL and Create Quicklink.

**Script Commands:** add trusted executable scripts to
`~/.config/oma-cast/script-commands`, or add directories in Settings.
**Create Script Command** writes an executable Bash or Python date-and-time
template; edit it to make your own command. Raycast metadata supports arguments,
confirmation, working directories, and `fullOutput`, `compact`, `silent` and
`inline` modes. Full output supports ANSI colors, cancellation, copying and rerun.
Directories refresh every 15 seconds, or immediately with **Reload Script Commands**.
Inline scripts run automatically, with a minimum 10-second refresh interval.
Scripts run as you, with your login-shell environment: review them before adding
their directory. macOS-specific utilities such as `pbcopy` need Linux adaptations;
this is not a macOS compatibility runtime.

**System actions:** volume presets and adjustment, microphone/output mute,
MPRIS play/pause/next/previous, the Omarchy audio panel, display sleep, and a
light/dark appearance toggle join the existing power commands. Appearance uses an
installed Omarchy theme of the opposite mode, preferring the last one used during
this session. Power commands retain their confirmation dialogs in search;
explicit `oma-cast run` calls bypass power confirmation.

## Keyboard

| Key | Does |
|---|---|
| `↵` / `Ctrl+↵` / `Ctrl+Shift+↵` | Run the first, second or third action |
| `Shift+↵` | Open a new window of an app (`↵` switches to the one already open) |
| `Ctrl+K` | Open the action panel |
| `Ctrl+,` / `Ctrl+Shift+,` | Open Settings / configure the selected command |
| `Ctrl+E` / `Ctrl+D` on a quicklink | Edit / delete the selected quicklink |
| `Super+V` / `Ctrl+V` / `Ctrl+Shift+V` / `Shift+Insert` | Paste text into the query (also accepts clipboard-history selections) |
| `Ctrl+Alt+↵` | Ask the default agent using the current root-search text |
| `Ctrl+1`…`9` | Pick a result |
| `↑` on an empty search | Search history |
| `Ctrl+↑` / `Ctrl+↓` | Jump between sections |
| `Ctrl+N` / `Ctrl+P` | Next / previous |
| `Ctrl+Shift+F` | Add to favorites (`Ctrl+Alt+↑↓` to reorder) |
| `Ctrl+Shift+C` | Copy |
| `Alt+Shift+D` | Disable a command |
| `Esc` / `Shift+Esc` | Back / back to root |
| `Ctrl +` / `Ctrl −` / `Ctrl 0` | Zoom |

## CLI

```sh
oma-cast toggle | show | hide
oma-cast run <commandId>         # e.g. app:com.mitchellh.ghostty, omarchy:appearance.theme
oma-cast settings [page]        # general, launcher, keyboard, commands, quicklinks, scripts, about
oma-cast call <method> [json]    # call any backend method
oma-cast doctor
```

## Roadmap

Phases 0–2 are implemented: launcher/search, calculator and history, Settings,
hotkeys, quicklinks, Script Commands and core system actions. Later phases:

- [ ] Clipboard history and snippets
- [ ] Indexed file search
- [ ] Running Raycast extensions built from the open-source [`raycast/extensions`](https://github.com/raycast/extensions) repo
- [ ] Window management
- [ ] Importing your `.rayconfig` from macOS

The full plan is in [`SPEC.md`](SPEC.md).

## Development

```sh
node --test tests/*.test.js # unit tests, no npm install needed
tests/smoke.sh            # live checks against the running shell
oma-cast dev          # reload on every save
```

Quickshell caches QML for the life of the process, so run `oma-cast reload` after editing anything under `plugin/`. See [`CLAUDE.md`](CLAUDE.md) for the layout and conventions.

### Test a branch without replacing the installed launcher

From the feature worktree, keep this running in one terminal:

```sh
bin/oma-cast preview
```

Use another terminal in the same worktree:

```sh
bin/oma-cast preview show
bin/oma-cast preview settings
bin/oma-cast preview search '2+2'
bin/oma-cast preview stop
```

The preview uses IPC/layer namespace `oma-cast-preview`, its own Quickshell process,
and separate configuration/data under `~/.cache/oma-cast-preview`. Set
`OMA_CAST_PREVIEW_HOME` on both terminals to choose another profile. It does not
install the branch or replace the existing Alt+Space binding. Stop and restart the
preview after QML/JS changes. **Data isolation is not a sandbox:** launching apps,
running scripts, changing audio/theme settings and power actions affect the real
desktop. Do not run destructive actions merely to test them.

For the optional live QML regression checks:

```sh
OMA_CAST_QML_RUNNER=/usr/bin/qs node --test tests/*.test.js
```

## Notes

oma-cast is an independent, clean-room project. It isn't affiliated with or endorsed by Raycast, and it contains no Raycast code or assets. It never contacts Raycast's servers and has no telemetry. Its agent action explicitly hands your question to Omarchy's existing coding-agent launcher; it provides no embedded AI runtime.
