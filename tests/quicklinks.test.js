const test = require('node:test')
const assert = require('node:assert/strict')
const Q = require('../plugin/core/Quicklinks.js')
const P = require('../plugin/core/Placeholders.js')
const M = require('../plugin/core/Migrate.js')
const base = () => ({ name: 'DuckDuckGo', link: 'https://duckduckgo.com/?q={query}', tags: ['search', 'search'] })

test('saved quicklinks survive versioned serialization with searchable argument candidates', () => {
  const migrated = M.migrate({}, Q.migrations, 100)
  const row = Q.save(migrated.doc, base(), P, () => 'one', 100, false)
  const restored = JSON.parse(M.serialize(migrated.doc))
  assert.equal(restored.schemaVersion, 1)
  assert.equal(Q.find(restored, 'one').name, 'DuckDuckGo')
  const candidate = Q.candidate(row, P, true)
  assert.equal(candidate.id, 'quicklink:one')
  assert.equal(candidate.arguments[0].name, 'query')
  assert.deepEqual(candidate.keywords, ['search'])
  assert.equal(candidate.fallbackStatus, 'available')
  assert.equal(Q.candidate(row, P, false).subtitle, 'Quicklink')
  Q.save(restored, { ...base(), id: 'one', name: 'Updated', icon: 'firefox', openWith: 'firefox.desktop' }, P, () => 'unused', 200, true)
  assert.equal(Q.find(restored, 'one').createdAt, 100)
  assert.equal(Q.find(restored, 'one').updatedAt, 200)
  assert.equal(Q.candidate(Q.find(restored, 'one'), P, true).iconName, 'firefox')
})

test('duplicate IDs cannot overwrite persisted rows or partially import a batch', () => {
  const doc = { items: [] }
  Q.save(doc, base(), P, () => 'one', 1, false)
  assert.throws(() => Q.save(doc, { ...base(), id: 'one' }, P, () => 'two', 2, false), /Duplicate/)
  assert.throws(() => Q.rows({ items: [{ id: 'x' }, { id: 'x' }] }), /duplicate/)
  assert.throws(() => Q.importJson(doc, JSON.stringify([base(), base()]), P, () => 'two', 2), /Duplicate/)
  assert.equal(doc.items.length, 1)
  assert.throws(() => Q.importJson(doc, JSON.stringify([base(), { name: 'Bad', link: 'javascript:alert(1)' }]), P, () => 'three', 2), /support/)
  assert.equal(doc.items.length, 1)
})

test('read-only and unloaded stores reject changes before invoking mutators', () => {
  let invoked = false
  const store = { loaded: true, readOnly: true, lastError: 'newer schema', update: () => { invoked = true } }
  assert.throws(() => Q.mutate(store, () => {}), /newer schema/)
  assert.equal(invoked, false)
  store.readOnly = false; store.loaded = false
  assert.throws(() => Q.mutate(store, () => {}), /newer schema/)
  assert.equal(invoked, false)
  store.loaded = true; store.update = () => false
  assert.throws(() => Q.mutate(store, () => {}), /read-only/)
})

test('compatible imports append fresh IDs and export only interchange fields', () => {
  const doc = { items: [] }
  const rows = Q.importJson(doc, '[{"name":"Example","link":"https://example.org","openWith":"firefox"}]', P, () => 'new', 50)
  assert.equal(rows[0].id, 'new')
  assert.deepEqual(JSON.parse(Q.exportJson(doc)), [{ name: 'Example', link: 'https://example.org', openWith: 'firefox' }])
  assert.throws(() => Q.importJson(doc, '{}', P, () => 'newer', 50), /array/)
})

test('URL special characters remain literal argv and unsafe launch targets are rejected', () => {
  const row = Q.validate(base(), P)
  const expanded = P.resolve(row.link, { query: 'a & b;$(false)"/雪' })
  assert.deepEqual(Q.launchArgv(row, expanded, '/home/test'), ['xdg-open', expanded])
  assert.deepEqual(Q.launchArgv({ openWith: 'firefox' }, expanded), ['gtk-launch', 'firefox', expanded])
  assert.deepEqual(Q.launchArgv({}, '~/a file', '/home/test'), ['xdg-open', '/home/test/a file'])
  assert.throws(() => Q.validate({ ...base(), openWith: '--bad' }, P), /desktop application ID/)
  assert.throws(() => Q.validate({ ...base(), openWith: 'bash -c bad' }, P), /desktop application ID/)
  assert.throws(() => Q.validate({ ...base(), icon: 'https://example.org/icon.png' }, P), /local icon/)
  assert.throws(() => Q.launchArgv({}, 'javascript:alert(1)'), /support/)
  assert.throws(() => Q.launchArgv({}, 'https://example.org/\n--option'), /control/)
})

test('favicon downloads are explicit same-origin bounded argv without redirect following', () => {
  const request = Q.faviconRequest('https://example.org/search?q={query}', '/cache/a directory', 'unique-id')
  assert.equal(request.url, 'https://example.org/favicon.ico')
  assert.equal(request.path, '/cache/a directory/quicklink-favicon-unique-id.ico')
  assert.equal(request.argv[0], 'curl')
  assert.equal(request.argv[1], '--disable')
  assert.equal(request.argv.includes('--location'), false)
  assert.equal(request.argv[request.argv.indexOf('--max-redirs') + 1], '0')
  assert.equal(request.argv[request.argv.indexOf('--max-time') + 1], '10')
  assert.equal(request.argv[request.argv.indexOf('--max-filesize') + 1], '1048576')
  assert.equal(request.argv[request.argv.indexOf('--output') + 1], request.path)
  for (const link of ['https://raycast.com', 'https://api.raycast.com/path', 'https://RAYCAST.COM./', 'https://raycast.com../']) {
    assert.throws(() => Q.faviconRequest(link, '/cache', 'id'), /not permitted/)
  }
  for (const link of ['https://{host}/', 'https://example.org{suffix}/', 'https://user:password@example.org', 'https://example.org;bad/', 'https://example.org:99999/']) {
    assert.throws(() => Q.faviconRequest(link, '/cache', 'id'), Error)
  }
  assert.throws(() => Q.faviconRequest('file:///etc/passwd', '/cache', 'id'), /HTTP/)
  assert.throws(() => Q.faviconRequest('https://example.org', '/cache', '../unsafe'), /destination/)
  assert.deepEqual(Q.launchArgv({}, 'obsidian://open?vault=work'), ['xdg-open', 'obsidian://open?vault=work'])
})
