const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const Actions = require('../plugin/core/SystemActions.js')

test('system candidates supplement rather than duplicate guarded power entries', () => {
  const rows = Actions.candidates()
  assert.equal(new Set(rows.map(row => row.id)).size, rows.length)
  for (const row of rows) {
    assert.equal(row.kind, 'system-action')
    assert.equal(row.type, 'command')
    assert.equal(row.rootSearch.when, 'always')
    assert.ok(row.title && row.subtitle && row.glyph && row.keywords.length)
    assert.equal(Actions.POWER_IDS.includes(row.id), false)
    assert.equal(Actions.handles(row.id), true)
  }
  assert.deepEqual(rows.find(row => row.id === 'system:set-volume').arguments,
    [{ name: 'volume', placeholder: 'Volume (0–100)', type: 'text', required: true }])
})

test('power plans retain stable Omarchy IDs and destructive confirmation metadata', () => {
  const expected = {
    lock: ['omarchy-system-lock'], suspend: ['systemctl', 'suspend'], hibernate: ['systemctl', 'hibernate'],
    logout: ['omarchy-system', 'logout'], reboot: ['omarchy-system', 'reboot'], shutdown: ['omarchy-system', 'shutdown'],
    screensaver: ['omarchy-launch-screensaver', 'force']
  }
  for (const [name, argv] of Object.entries(expected)) {
    assert.deepEqual(Actions.plan('omarchy:system.' + name).argv, argv)
    assert.equal(!!Actions.confirmationFor('omarchy:system.' + name), ['logout', 'reboot', 'shutdown'].includes(name))
  }
  assert.deepEqual(Actions.confirmationFor('omarchy:system.shutdown'), {
    title: 'Shut Down', message: 'Are you sure you want to shut down?', primary: 'Shut Down', destructive: true
  })
  assert.equal(Actions.confirmationFor('toString'), null)
  assert.equal(Actions.handles('__proto__'), false)
  assert.throws(() => Actions.plan('system:shutdown'), /Unknown system action/)
})

test('volume values accept percentages and reject missing, out-of-range, and shell input', () => {
  for (const [input, expected] of [[0, 0], ['0', 0], [' 25% ', 25], ['12.5 %', 12.5], ['.5', 0.5], [100, 100]])
    assert.equal(Actions.volumeValue(input), expected)
  for (const input of [undefined, null, true, {}, [], '', ' ', -1, 101, Infinity, NaN, '1e2', '0x32', '-1', '100.1', '50; reboot', '$(id)', '50%%'])
    assert.throws(() => Actions.volumeValue(input), /volume|Volume/)
  assert.throws(() => Actions.plan('system:set-volume', {}), /volume/)
})

test('volume plans use fixed wpctl argv and cap relative changes at 100 percent', () => {
  for (const value of [0, 25, 50, 75, 100])
    assert.deepEqual(Actions.plan('system:volume-' + value).argv, ['wpctl', 'set-volume', '@DEFAULT_AUDIO_SINK@', value + '%'])
  assert.deepEqual(Actions.plan('system:set-volume', { arguments: { volume: '42.5%' } }).argv,
    ['wpctl', 'set-volume', '@DEFAULT_AUDIO_SINK@', '42.5%'])
  assert.deepEqual(Actions.plan('system:volume-up').argv, ['wpctl', 'set-volume', '--limit', '1', '@DEFAULT_AUDIO_SINK@', '5%+'])
  assert.deepEqual(Actions.plan('system:volume-down').argv, ['wpctl', 'set-volume', '--limit', '1', '@DEFAULT_AUDIO_SINK@', '5%-'])
  assert.deepEqual(Actions.plan('system:toggle-mute').argv, ['wpctl', 'set-mute', '@DEFAULT_AUDIO_SINK@', 'toggle'])
  assert.deepEqual(Actions.plan('system:toggle-microphone-mute').argv, ['wpctl', 'set-mute', '@DEFAULT_AUDIO_SOURCE@', 'toggle'])
})

function player(properties) {
  return { dbusName: 'org.mpris.MediaPlayer2.example', identity: 'Example', canControl: true,
    canPlay: true, canPause: true, canGoNext: true, canGoPrevious: true, isPlaying: false, ...properties }
}

test('media chooses a playing player and captures D-Bus method replies through gdbus', () => {
  const paused = player()
  const playing = player({ dbusName: 'org.mpris.MediaPlayer2.active', isPlaying: true })
  for (const [id, method] of [['play-pause', 'PlayPause'], ['next-track', 'Next'], ['previous-track', 'Previous']]) {
    assert.deepEqual(Actions.plan('system:' + id, {}, [paused, playing]).argv,
      ['gdbus', 'call', '--session', '--timeout', '10', '--dest', playing.dbusName,
        '--object-path', '/org/mpris/MediaPlayer2', '--method', 'org.mpris.MediaPlayer2.Player.' + method])
  }
})

test('missing or unsupported active players fail rather than silently succeeding', () => {
  assert.throws(() => Actions.plan('system:play-pause', {}, []), /No media player/)
  for (const [id, changes] of [
    ['play-pause', { canControl: false }], ['play-pause', { canPlay: false }],
    ['play-pause', { isPlaying: true, canPause: false }], ['next-track', { canGoNext: false }],
    ['previous-track', { canGoPrevious: false }]
  ]) assert.throws(() => Actions.plan('system:' + id, {}, [player(changes)]), /does not support/)
})


test('completion reflects hardware, process and routing failures, not just process launch', () => {
  const candidate = { title: 'Toggle Mute' }
  assert.deepEqual(Actions.completionMessage(candidate, {}, 1, 0, 'No default audio sink\n', ''),
    { style: 'failure', title: 'Toggle Mute failed: No default audio sink' })
  assert.equal(Actions.completionMessage(candidate, {}, 0, 1, '', '').style, 'failure')
  assert.equal(Actions.completionMessage(candidate, { panel: true }, 0, 0, '', 'false\n').style, 'failure')
  assert.equal(Actions.completionMessage(candidate, {}, 0, 0, '', '').style, 'success')
  assert.equal(Actions.completionMessage(candidate, { power: true }, 0, 0, '', '').title, 'Requested: Toggle Mute')
  assert.equal(Actions.completionMessage(candidate, { message: 'Volume set to 50%' }, 0, 0, '', '').title, 'Volume set to 50%')
})

test('executable wrapper reports missing tools and preserves literal argv', () => {
  const missing = spawnSync('bash', ['-c', Actions.EXEC_SCRIPT, 'test', 'oma-cast-test-command-that-does-not-exist'], { encoding: 'utf8' })
  assert.equal(missing.status, 127)
  assert.match(missing.stderr, /Required command is not installed/)
  const literal = '$(false); * ; spaces'
  const result = spawnSync('bash', ['-c', Actions.EXEC_SCRIPT, 'test', 'printf', '%s', literal], { encoding: 'utf8' })
  assert.equal(result.status, 0)
  assert.equal(result.stdout, literal)
})

function themeFixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'oma-cast-system-actions-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const home = path.join(root, 'home'), omarchy = path.join(root, 'omarchy'), bin = path.join(root, 'bin')
  const current = path.join(home, '.local/state/omarchy/current')
  fs.mkdirSync(path.join(current, 'theme'), { recursive: true })
  fs.mkdirSync(bin)
  fs.writeFileSync(path.join(current, 'theme/colors.toml'), 'dark\n')
  fs.writeFileSync(path.join(current, 'theme.name'), 'original-dark\n')
  fs.writeFileSync(path.join(bin, 'omarchy-theme-color'), '#!/bin/bash\nfile="$HOME/.local/state/omarchy/current/theme/colors.toml"\n[[ $1 != --file ]] || file=$2\ncat "$file"\n', { mode: 0o755 })
  fs.writeFileSync(path.join(bin, 'omarchy-theme-set'), '#!/bin/bash\nset -e\nfile="$HOME/.config/omarchy/themes/$1/colors.toml"\n[[ -f $file ]] || file="$OMARCHY_PATH/themes/$1/colors.toml"\ncp "$file" "$HOME/.local/state/omarchy/current/theme/colors.toml"\nprintf "%s\\n" "$1" > "$HOME/.local/state/omarchy/current/theme.name"\n', { mode: 0o755 })
  const theme = (name, mode, user = false) => {
    const directory = user ? path.join(home, '.config/omarchy/themes', name) : path.join(omarchy, 'themes', name)
    fs.mkdirSync(directory, { recursive: true })
    fs.writeFileSync(path.join(directory, 'colors.toml'), mode + '\n')
  }
  theme('original-dark', 'dark')
  return { theme, run: (light = '', dark = '') => spawnSync('bash', ['-c', Actions.APPEARANCE_SCRIPT, 'test', light, dark], {
    encoding: 'utf8', env: { ...process.env, HOME: home, OMARCHY_PATH: omarchy, PATH: bin + ':' + process.env.PATH }
  }) }
}

test('appearance switches real mode, remembers a preferred installed theme, and returns to dark', t => {
  const fixture = themeFixture(t)
  fixture.theme('a-light', 'light')
  fixture.theme('preferred-light', 'light')
  const first = fixture.run('preferred-light')
  assert.equal(first.status, 0, first.stderr)
  assert.match(first.stdout, /OMA_THEME_CURRENT\tdark\toriginal-dark/)
  assert.match(first.stdout, /OMA_THEME_APPLIED\tlight\tpreferred-light/)
  const second = fixture.run('preferred-light', 'original-dark')
  assert.equal(second.status, 0, second.stderr)
  assert.match(second.stdout, /OMA_THEME_APPLIED\tdark\toriginal-dark/)
})

test('appearance falls back to installed opposite mode and respects user overrides', t => {
  const fixture = themeFixture(t)
  fixture.theme('a-overridden', 'light')
  fixture.theme('a-overridden', 'dark', true)
  fixture.theme('b-light', 'light')
  const result = fixture.run('missing-theme')
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /OMA_THEME_APPLIED\tlight\tb-light/)
})

test('appearance without an opposite-mode theme reports failure', t => {
  const fixture = themeFixture(t)
  const result = fixture.run()
  assert.equal(result.status, 1)
  assert.match(result.stderr, /No installed light Omarchy theme/)
  assert.doesNotMatch(result.stdout, /OMA_THEME_APPLIED/)
})
