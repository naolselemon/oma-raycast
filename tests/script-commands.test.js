const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawn, spawnSync } = require('node:child_process')
const Scripts = require('../plugin/core/ScriptCommands.js')
const helper = path.resolve(__dirname, '../plugin/scripts/script-commands.bash')
const header = (mode = 'compact', extra = '') => '#!/usr/bin/env bash\n# @raycast.schemaVersion 1\n# @raycast.title Example\n# @raycast.mode ' + mode + '\n' + extra
function temporary(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'oma script tests '))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  return directory
}
function writeScript(directory, name, body, mode = 0o700) {
  const file = path.join(directory, name)
  fs.writeFileSync(file, body, { mode })
  return file
}
function records(text) {
  return text.trim().split('\n').filter(Boolean).map(line => {
    const [tag, ...parts] = line.split(':')
    return {tag, values: parts.map(value => Buffer.from(value, 'base64').toString('utf8'))}
  })
}

test('metadata accepts every comment form and case-insensitive keys', () => {
  const script = Scripts.parse('/home/user/my scripts/run.sh', 'REM @raycast.SCHEMAVERSION 1\n:: @raycast.title A Script\n// @raycast.mode full-output\n# @raycast.currentDirectoryPath ../work dir\n# @raycast.needsConfirmation true')
  assert.equal(script.title, 'A Script')
  assert.equal(script.mode, 'fullOutput')
  assert.equal(script.packageName, 'My Scripts')
  assert.equal(script.cwd, '/home/user/work dir')
  assert.equal(script.needsConfirmation, true)
  assert.equal(Scripts.parse('/x/plain.sh', '#!/bin/bash\necho hi'), null)
  assert.throws(() => Scripts.parse('/x/run', '# @raycast.schemaVersion 2'), /schemaVersion/)
  assert.throws(() => Scripts.parse('/x/run', header('unknown')), /mode/)
})

test('inline ignores argument and confirmation metadata and enforces the ten-second floor', () => {
  const script = Scripts.parse('/x/run', header('inline', '# @raycast.refreshTime 1s\n# @raycast.argument1 broken JSON\n# @raycast.needsConfirmation true'))
  assert.deepEqual(script.arguments, [])
  assert.deepEqual(Scripts.argumentsFor(script, {argument1: 'ignored'}), [])
  assert.equal(script.needsConfirmation, false)
  assert.equal(script.refreshTime, 10000)
  assert.equal(Scripts.parse('/x/run', header('inline')).mode, 'compact')
  assert.equal(Scripts.refreshInterval('2h'), 7200000)
  assert.throws(() => Scripts.refreshInterval('hour'), /refreshTime/)
})

test('required, password, optional, dropdown and encoded arguments retain positions and literal data', () => {
  const script = Scripts.parse('/x/run', header('fullOutput', '# @raycast.argument1 {"type":"password","placeholder":"Token"}\n# @raycast.argument2 {"type":"dropdown","optional":true,"data":[{"title":"A","value":"a b"}]}\n# @raycast.argument3 {"type":"text","percentEncoded":true}'))
  assert.equal(script.arguments[0].secure, true)
  assert.throws(() => Scripts.argumentsFor(script, {}), /Token is required/)
  assert.throws(() => Scripts.argumentsFor(script, {argument1:'x', argument2:'invalid'}), /Choose a valid/)
  assert.deepEqual(Scripts.argumentsFor(script, {argument1:'$(touch nope) " \'', argument3:'café &/'}), ['$(touch nope) " \'', '', 'caf%C3%A9%20%26%2F'])
  assert.deepEqual(Scripts.argumentsFor(script, ['secret', 'a b', 'hello']), ['secret', 'a b', 'hello'])
  assert.throws(() => Scripts.argumentsFor(script, {argument1: '\0'}), /NUL/)
})

test('ANSI output stays plain text, preserves colors across chunks and strips control links', () => {
  const output = Scripts.outputState()
  Scripts.appendOutput(output, '\x1b[3', false)
  Scripts.appendOutput(output, '1m<img src=x>\x1b[0m\n\x1b]8;;https://bad.invalid\x07literal\x1b]8;;\x1b\\\n', false)
  Scripts.appendOutput(output, '\x1b[38;2;1;2;3mcolor\x1b[0m\nlast\n\n', true)
  Scripts.finishOutput(output)
  assert.equal(output.firstLine, '<img src=x>')
  assert.equal(output.lastLine, 'last')
  assert.equal(output.segments[0].color, '#e06c75')
  assert.ok(output.segments.some(segment => segment.color === '#010203'))
  const text = output.segments.map(segment => segment.text).join('')
  assert.equal(text, '<img src=x>\nliteral\ncolor\nlast\n\n')
  assert.ok(!text.includes('\x1b'))
})

test('unbounded lines and color changes cannot grow retained output indefinitely', () => {
  const output = Scripts.outputState()
  for (let i = 0; i < 5000; i++) Scripts.appendOutput(output, '\x1b[' + (30 + i % 8) + 'm' + 'x'.repeat(80), false)
  assert.ok(output.size <= Scripts.OUTPUT_LIMIT)
  assert.ok(output.segments.length <= 2048)
  assert.ok(output.pendingLine.length <= 4096)
  assert.equal(output.truncated, true)
  Scripts.finishOutput(output)
  assert.ok(output.firstLine.length <= 4096)
})

test('discovery is nonrecursive and excludes templates, oversized files and nonexecutables', t => {
  const directory = temporary(t)
  const valid = writeScript(directory, 'valid name.sh', header() + '\nprintf hi\n')
  writeScript(directory, 'sample.template.sh', header())
  writeScript(directory, 'not-executable.sh', header(), 0o600)
  writeScript(directory, 'empty.sh', '')
  const oversized = writeScript(directory, 'large.sh', header())
  fs.truncateSync(oversized, Scripts.MAX_FILE_SIZE + 1)
  fs.mkdirSync(path.join(directory, 'nested'))
  writeScript(path.join(directory, 'nested'), 'hidden.sh', header())
  const scanned = spawnSync('bash', [helper, 'scan', directory], {encoding:'utf8'})
  assert.equal(scanned.status, 0, scanned.stderr)
  const scripts = records(scanned.stdout).filter(row => row.tag === 'S')
  assert.equal(scripts.length, 1)
  assert.equal(scripts[0].values[0], valid)
  assert.equal(Scripts.parse(...scripts[0].values).title, 'Example')
})

test('real process runs every mode with literal argv and working directories containing spaces', t => {
  const directory = temporary(t)
  const cwd = path.join(directory, 'working directory')
  fs.mkdirSync(cwd)
  for (const mode of ['fullOutput', 'compact', 'silent', 'inline']) {
    const file = writeScript(directory, mode + '.sh', header(mode, mode === 'inline' ? '# @raycast.refreshTime 10s\n' : '') + 'printf "first\\n"\nprintf "%s\\n" "$PWD" "$1"\nprintf "stderr\\n" >&2\nprintf "last\\n\\n"\n')
    const literal = 'space " quote $(touch NEVER) ; & café'
    const result = spawnSync('bash', [helper, 'run', cwd, file, literal], {encoding:'utf8', timeout:5000})
    assert.equal(result.status, 0, result.stderr)
    const output = Scripts.outputState()
    const stdout = records(result.stdout).filter(row => row.tag === 'O').map(row => row.values[0]).join('')
    for (const row of records(result.stdout)) Scripts.appendOutput(output, row.values[0], row.tag === 'E')
    Scripts.finishOutput(output)
    assert.ok(stdout.includes(cwd))
    assert.ok(stdout.includes(literal))
    assert.equal(stdout.split('\n')[0], 'first')
    // stdout/stderr are concurrent streams: the final combined line follows arrival order.
    assert.ok(['last', 'stderr'].includes(output.lastLine))
    assert.equal(fs.existsSync(path.join(cwd, 'NEVER')), false)
  }
})

test('helper streams short lines before completion and reports nonzero status', async t => {
  const directory = temporary(t)
  const file = writeScript(directory, 'stream.sh', header('fullOutput') + 'printf "started\\n"\nsleep 0.2\nprintf "failed\\n" >&2\nexit 7\n')
  const child = spawn('bash', [helper, 'run', directory, file])
  t.after(() => child.kill())
  let exited = false, streamed = false, output = ''
  child.stdout.on('data', chunk => { assert.equal(exited, false); streamed = true; output += chunk })
  const code = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', code => { exited = true; resolve(code) }) })
  assert.equal(code, 7)
  assert.equal(streamed, true)
  assert.ok(records(output).some(row => row.tag === 'E' && row.values[0].includes('failed')))
})

test('cancel terminates the script process group including children', async t => {
  const directory = temporary(t)
  const file = writeScript(directory, 'cancel.sh', header() + 'sleep 60 &\nprintf "%s %s\\n" "$$" "$!"\nwait\n')
  const child = spawn('bash', [helper, 'run', directory, file])
  t.after(() => child.kill())
  const closed = new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve) })
  const pids = await new Promise((resolve, reject) => {
    let output = ''
    const timer = setTimeout(() => reject(new Error('Script did not stream its pids')), 3000)
    child.stdout.on('data', chunk => {
      output += chunk
      if (!output.includes('\n')) return
      const row = records(output)[0]
      if (row && row.tag === 'O') { clearTimeout(timer); resolve(row.values[0].trim().split(' ').map(Number)) }
    })
  })
  child.kill('SIGTERM')
  assert.equal(await closed, 130)
  for (const pid of pids) {
    // A killed child can briefly remain a zombie until its adopter reaps it.
    let stat = ''
    try { stat = fs.readFileSync('/proc/' + pid + '/stat', 'utf8') } catch (error) { assert.equal(error.code, 'ENOENT'); continue }
    assert.equal(stat.slice(stat.lastIndexOf(')') + 2).charAt(0), 'Z')
  }
})

test('creation generates executable real templates and never overwrites an existing file', t => {
  const directory = temporary(t)
  for (const language of ['bash', 'python']) {
    const filename = 'created.' + (language === 'bash' ? 'sh' : 'py')
    const body = Scripts.template({title:'Date', mode:'inline', language})
    const result = spawnSync('bash', [helper, 'create', directory, filename, body], {encoding:'utf8'})
    assert.equal(result.status, 0, result.stderr)
    const file = path.join(directory, filename)
    assert.ok(fs.statSync(file).mode & 0o100)
    assert.equal(Scripts.parse(file, fs.readFileSync(file, 'utf8')).refreshTime, 60000)
    const duplicate = spawnSync('bash', [helper, 'create', directory, filename, 'replacement'])
    assert.notEqual(duplicate.status, 0)
    assert.equal(fs.readFileSync(file, 'utf8'), body)
  }
  assert.throws(() => Scripts.template({title:'bad\n# metadata'}), /single-line/)
})

test('transport decodes UTF-8 paths and output without Qt-specific base64 behavior', () => {
  for (const text of ['café', 'Ābc', '日本語 / spaced path', '<b>plain</b>', 'line\nnext']) {
    assert.equal(Scripts.decodeRecord(Buffer.from(text).toString('base64')), text)
  }
})

test('login-shell environment is returned as literal NUL-separated values', t => {
  const directory = temporary(t)
  const shell = writeScript(directory, 'login shell', '#!/bin/bash\n[[ $1 == -lc && $2 == "env -0" ]] || exit 3\nprintf \'PATH=/usr/bin:/bin\\0LITERAL=a b=c;$(not expanded)\\0\'\n')
  const result = spawnSync('bash', [helper, 'environment', shell], {encoding:'utf8'})
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(records(result.stdout).map(row => row.values[0]), ['PATH=/usr/bin:/bin', 'LITERAL=a b=c;$(not expanded)'])
})
