const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const Hotkeys = require('../plugin/core/Hotkeys.js')

const chord = (key = 'K', modifiers = ['Ctrl', 'Alt']) => ({ modifiers, key })

test('normalization canonicalizes modifier aliases, ordering and special keys', () => {
  assert.deepEqual(Hotkeys.normalize({ modifiers: ['super', 'CONTROL', 'shift', 'alt', 'Ctrl'], key: 'enter' }),
    { modifiers: ['Ctrl', 'Alt', 'Shift', 'Super'], key: 'Return' })
  assert.equal(Hotkeys.format(chord('k')), 'Ctrl + Alt + K')
  assert.equal(Hotkeys.mask(chord()), 12)
  assert.equal(Hotkeys.identity(chord('k')), Hotkeys.identity(chord('K')))
  assert.equal(Hotkeys.normalize(null), null)
  assert.equal(Hotkeys.format(null), '')
  assert.deepEqual(Hotkeys.normalize(chord('F35', [])), chord('F35', []))
  assert.equal(Hotkeys.normalize(chord('prior')).key, 'PageUp')
  assert.equal(Hotkeys.normalize(chord(';')).key, 'semicolon')
})

test('validation rejects plain typing, modifiers alone and injected syntax', () => {
  for (const value of [chord('A', []), chord('F36'), chord('Ctrl'), chord('x; hl.unbind("all")'),
    chord('K', ['Hyper']), chord('constructor'), chord('K', ['constructor']), {}, 'Ctrl+K'])
    assert.throws(() => Hotkeys.normalize(value))
  assert.throws(() => Hotkeys.command('preview;bad', 'builtin:one'))
  assert.throws(() => Hotkeys.command('oma-cast', 'bad\ncommand'))
  assert.throws(() => Hotkeys.command('oma-cast-preview', 'one', '/tmp/bad\0path'), /config path/)
})

test('Qt recorder ignores modifiers and repeat, maps function and special keys', () => {
  assert.equal(Hotkeys.fromKeyEvent({ key: 0x01000020, modifiers: 0x02000000 }), null)
  assert.equal(Hotkeys.fromKeyEvent({ key: 75, modifiers: 0x04000000, isAutoRepeat: true }), null)
  assert.deepEqual(Hotkeys.fromKeyEvent({ key: 75, modifiers: 0x0c000000 }), chord())
  assert.deepEqual(Hotkeys.fromKeyEvent({ key: 0x01000030, modifiers: 0 }), chord('F1', []))
  assert.deepEqual(Hotkeys.fromKeyEvent({ key: 0x01000014, modifiers: 0x10000000 }), chord('Right', ['Super']))
  assert.throws(() => Hotkeys.fromKeyEvent({ key: 65, modifiers: 0 }))
})

test('conflicts include user shortcuts, release variants, submaps and physical keys', () => {
  const binds = [
    { key: 'k', modmask: 12, description: 'User action' },
    { key: 'K', modmask: 12, description: 'Release action', release: true, submap: 'resize' },
    { key: 'K', modmask: 8, description: 'Different modifiers' },
    { key: 'J', modmask: 12, description: 'Different key' },
    { key: '', keycode: 45, modmask: 12, description: 'Physical shortcut' },
    { key: '', keycode: 0, modmask: 12, description: 'Chord shortcut' },
    { key: 'K', modmask: 0, ignore_mods: true, description: 'Any modifiers' },
    { key: 'K', modmask: 12, description: 'Owned dormant handle' }
  ]
  assert.deepEqual(Hotkeys.conflicts(chord(), binds, ['Owned dormant handle']).map(c => c.description),
    ['User action', 'Release action', 'Physical shortcut', 'Chord shortcut', 'Any modifiers'])
  assert.equal(Hotkeys.conflicts(chord('PageUp'), [{ key: 'PRIOR', modmask: 12 }]).length, 1)
  assert.throws(() => Hotkeys.conflicts(chord(), {}), /invalid binding list/)
  assert.deepEqual(Hotkeys.conflicts(null, []), [])
})


// Exercise the real QML service functions with deterministic asynchronous I/O.
// No compositor commands, configuration writes or QML runtime are used here.
function harness(initial = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../plugin/services/HotkeysService.qml'), 'utf8')
  const functions = source.match(/^  function \w+\([^]*?^  \}/gm).join('\n')
  const commands = structuredClone(initial)
  const calls = []
  let binds = []
  const context = {
    Promise, Error, JSON, Object, Array, String, Number, Date, Math,
    ready: true, initialized: true, disposed: false, acquired: true, generation: 0, sequence: 0,
    owner: 'session', ipcTarget: 'oma-cast-preview', sessionTarget: 'oma-cast-preview',
    ipcConfigPath: '/tmp/preview/shell.qml',
    active: {}, failures: {}, lastError: '', queue: Promise.resolve(),
    reconcileTimer: { restart() {} },
    Hotkeys: {
      ...Hotkeys,
      acquireLua: (target, owner) => ({ op: 'acquire', target, owner }),
      stageLua: (target, owner, token, id, value, configPath) => ({ op: 'stage', target, owner, token, id, value, configPath }),
      activateLua: (target, owner, enable, disable) => ({ op: 'activate', target, owner, enable, disable })
    },
    backend: {
      candidatesById: { one: { title: 'One' }, two: { title: 'Two' } },
      callSync(method) {
        if (method === 'settings.getAllCommandSettings') return { ok: true, data: commands }
        if (method === 'system.healthDatabase') return { ok: true, data: { readOnly: false } }
        throw new Error(method)
      },
      updateCommand(id, mutator) { calls.push({ op: 'persist', id }); commands[id] = mutator({ ...commands[id] }) },
      emit() {}
    }
  }
  context.service = context
  vm.createContext(context)
  vm.runInContext(functions, context)
  context.evaluate = async operation => {
    calls.push(operation)
    if (operation.op === 'stage') binds.push({ key: operation.value.key, modmask: Hotkeys.mask(operation.value),
      description: Hotkeys.prefix(operation.target) + operation.token })
  }
  context.run = async argv => { calls.push({ op: 'read', argv }); return JSON.stringify(binds) }
  return { context, commands, calls, setBinds(value) { binds = value } }
}

test('assignment checks twice, activates before persistence, and removal deactivates', async () => {
  const { context, commands, calls } = harness()
  await context.setCommand({ commandId: 'one', hotkey: chord() })
  assert.equal(Hotkeys.format(commands.one.hotkey), 'Ctrl + Alt + K')
  const token = context.active.one.token
  await context.setCommand({ commandId: 'one', hotkey: null })
  assert.equal(commands.one.hotkey, undefined)
  assert.equal(context.active.one, undefined)
  assert.equal(calls.at(-2).disable, token)
  assert.equal(calls.at(-2).enable, '')
})

test('compositor conflict and command conflict preserve the old shortcut', async () => {
  const h = harness({ one: { hotkey: chord('J') }, two: { hotkey: chord('L') } })
  h.context.active.one = { token: 'old', hotkey: chord('J') }
  h.setBinds([{ key: 'K', modmask: 12, description: 'User action' }])
  await assert.rejects(h.context.setCommand({ commandId: 'one', hotkey: chord() }), /User action/)
  await assert.rejects(h.context.setCommand({ commandId: 'one', hotkey: chord('L') }), /assigned to Two/)
  assert.equal(h.context.active.one.token, 'old')
  assert.equal(h.commands.one.hotkey.key, 'J')
  assert.equal(h.calls.some(c => c.op === 'activate' || c.op === 'persist'), false)
})

test('late compositor conflicts reject a disabled stage without disturbing old binding', async () => {
  const h = harness({ one: { hotkey: chord('J') } })
  h.context.active.one = { token: 'old', hotkey: chord('J') }
  const run = h.context.run
  let reads = 0
  h.context.run = async argv => {
    const text = await run(argv)
    if (++reads === 2) return JSON.stringify([...JSON.parse(text), { key: 'K', modmask: 12, description: 'New user shortcut' }])
    return text
  }
  await assert.rejects(h.context.setCommand({ commandId: 'one', hotkey: chord() }), /New user shortcut/)
  assert.equal(h.calls.some(c => c.op === 'activate' || c.op === 'persist'), false)
  assert.equal(h.context.active.one.token, 'old')
})

test('read-only persistence failure rolls back the applied binding', async () => {
  const h = harness({ one: { hotkey: chord('J') } })
  h.context.active.one = { token: 'old', hotkey: chord('J') }
  h.context.backend.updateCommand = () => { throw new Error('settings became read-only') }
  await assert.rejects(h.context.setCommand({ commandId: 'one', hotkey: chord() }), /read-only/)
  assert.equal(h.calls.at(-1).op, 'activate')
  assert.equal(h.calls.at(-1).enable, 'old')
  assert.equal(h.calls.at(-1).disable, 'session:1')
  assert.equal(h.commands.one.hotkey.key, 'J')
})

test('disabled or deleted commands deactivate; reload restores persisted enabled bindings', async () => {
  const h = harness({ one: { hotkey: chord(), enabled: false }, two: { hotkey: chord('L') } })
  h.context.active.one = { token: 'old', hotkey: chord() }
  await h.context.reconcile()
  assert.equal(h.context.active.one, undefined)
  assert.equal(h.context.active.two.hotkey.key, 'L')
  delete h.context.backend.candidatesById.two
  await h.context.reconcile()
  assert.equal(h.context.active.two, undefined)
  h.context.backend.candidatesById.two = { title: 'Two' }
  h.context.reloadBindings()
  await h.context.reconcile()
  assert.equal(h.context.active.two.hotkey.key, 'L')
  assert.equal(h.commands.one.enabled, false)
  assert.equal(h.calls.some(c => c.op === 'persist'), false)
})

test('simultaneous assignments serialize and newest request wins', async () => {
  const h = harness()
  await Promise.all([
    h.context.setCommand({ commandId: 'one', hotkey: chord('J') }),
    h.context.setCommand({ commandId: 'one', hotkey: chord('K') })
  ])
  assert.equal(h.commands.one.hotkey.key, 'K')
  assert.equal(h.context.active.one.hotkey.key, 'K')
  const mutations = h.calls.filter(c => c.op === 'activate')
  assert.equal(mutations[1].disable, mutations[0].enable)
})

test('settings changes during staging cannot persist stale assignment', async () => {
  const h = harness()
  const run = h.context.run
  let reads = 0
  h.context.run = async argv => {
    const text = await run(argv)
    if (++reads === 2) h.commands.one = { enabled: false }
    return text
  }
  await assert.rejects(h.context.setCommand({ commandId: 'one', hotkey: chord() }), /changed while assigning/)
  assert.equal(h.commands.one.hotkey, undefined)
  assert.equal(h.calls.some(c => c.op === 'persist'), false)
})

test('combined settings edit persists none on conflict and enables saved shortcut together', async () => {
  const h = harness({ one: { alias: 'old', enabled: false, hotkey: chord() } })
  h.setBinds([{ key: 'K', modmask: 12, description: 'User shortcut' }])
  await assert.rejects(h.context.setCommand({ commandId: 'one', alias: 'new', enabled: true }), /User shortcut/)
  assert.equal(h.commands.one.alias, 'old')
  assert.equal(h.commands.one.enabled, false)
  h.setBinds([])
  await h.context.setCommand({ commandId: 'one', alias: 'new', enabled: true })
  assert.equal(h.commands.one.alias, 'new')
  assert.equal(h.commands.one.enabled, undefined)
  assert.equal(h.context.active.one.hotkey.key, 'K')
  await h.context.setCommand({ commandId: 'one', alias: '', enabled: false })
  assert.equal(h.commands.one.alias, undefined)
  assert.equal(h.commands.one.enabled, false)
  assert.equal(h.commands.one.hotkey.key, 'K')
  assert.equal(h.context.active.one, undefined)
})

test('assignment invalidated by compositor reload cannot persist', async () => {
  const h = harness()
  const evaluate = h.context.evaluate
  h.context.evaluate = async operation => {
    await evaluate(operation)
    if (operation.op === 'activate') h.context.reloadBindings()
  }
  await assert.rejects(h.context.setCommand({ commandId: 'one', hotkey: chord() }), /changed while assigning/)
  assert.equal(h.commands.one, undefined)
  assert.equal(h.calls.some(c => c.op === 'persist'), false)
})
