var migrations = [{ version: 1, name: 'quicklinks', up: function(doc) { doc.items = []; return doc } }]
function validateLink(link) {
  if (typeof link !== 'string' || !link.trim() || /[\u0000-\u001f\u007f]/.test(link)) throw new Error('Enter a URL or an absolute file path without control characters')
  if (!/^(?:[A-Za-z][A-Za-z0-9+.-]*:|\/|~\/)/.test(link.trim()) || /^(?:javascript|vbscript|data):/i.test(link.trim())) throw new Error('Quicklinks support website/app URLs and absolute paths, not executable URL schemes')
  return link.trim()
}
function validate(input, placeholders) {
  if (!input || typeof input.name !== 'string' || !input.name.trim()) throw new Error('Quicklink name is required')
  var link = validateLink(input.link), parsed = placeholders.parse(link)
  var openWith = input.openWith || ''
  if (typeof openWith !== 'string' || (openWith && !/^[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(openWith))) throw new Error('Open With must be a desktop application ID, not a command')
  var icon = input.icon || ''
  if (typeof icon !== 'string' || /[\u0000-\u001f]/.test(icon) || (icon && !/^(?:\/|file:\/\/|[A-Za-z0-9_][A-Za-z0-9_.-]*$)/.test(icon))) throw new Error('Choose a local icon file or an app theme icon name; remote icons are not fetched')
  if (input.tags !== undefined && (!Array.isArray(input.tags) || input.tags.some(function(t) { return typeof t !== 'string' }))) throw new Error('Tags must be an array of text values')
  var tags = (input.tags || []).map(function(t) { return t.trim() }).filter(function(t, i, all) { return t && all.indexOf(t) === i })
  return { name: input.name.trim(), link: link, openWith: openWith, icon: icon, tags: tags, arguments: parsed.arguments }
}
function rows(doc) {
  if (!doc || !Array.isArray(doc.items)) throw new Error('Invalid quicklinks document')
  var seen = Object.create(null)
  doc.items.forEach(function(row) {
    if (!row || typeof row.id !== 'string' || !row.id || seen[row.id]) throw new Error('Invalid or duplicate quicklink ID')
    seen[row.id] = true
  })
  return doc.items
}
function find(doc, id) {
  var item = rows(doc).filter(function(row) { return row.id === id })[0]
  if (!item) throw new Error('Quicklink not found: ' + id)
  return item
}
function save(doc, input, placeholders, makeId, now, updating) {
  var items = rows(doc), clean = validate(input, placeholders), old = updating ? find(doc, input.id) : null
  var id = old ? old.id : (input.id || makeId())
  if (typeof id !== 'string' || !id || (!old && items.some(function(row) { return row.id === id }))) throw new Error('Duplicate or invalid quicklink ID')
  var row = Object.assign({}, clean, { id: id, openCount: old ? old.openCount : 0, createdAt: old ? old.createdAt : now, updatedAt: now })
  delete row.arguments
  if (old) items[items.indexOf(old)] = row
  else items.push(row)
  return row
}
function mutate(store, operation) {
  if (!store.loaded || store.readOnly) throw new Error(store.lastError || 'Quicklinks storage is unavailable or read-only')
  var value
  if (!store.update(function(doc) { value = operation(doc) })) throw new Error('Quicklinks storage is read-only')
  return value
}
function importJson(doc, text, placeholders, makeId, now) {
  var input = JSON.parse(text)
  if (!Array.isArray(input)) throw new Error('Import expects an array of {name, link, openWith?}')
  // Validate the complete batch before mutating it; importing never replaces existing rows.
  input.forEach(function(row) { validate(row, placeholders) })
  var working = { items: rows(doc).slice() }, added = []
  input.forEach(function(row) { added.push(save(working, { name: row.name, link: row.link, openWith: row.openWith }, placeholders, makeId, now, false)) })
  doc.items = working.items
  return added
}
function exportJson(doc, id) {
  return JSON.stringify((id ? [find(doc, id)] : rows(doc)).map(function(row) {
    var out = { name: row.name, link: row.link }; if (row.openWith) out.openWith = row.openWith; return out
  }), null, 2) + '\n'
}
function candidate(row, placeholders, showPreviews) {
  var clean = validate(row, placeholders)
  return { id: 'quicklink:' + row.id, quicklinkId: row.id, type: 'quicklink', kind: 'quicklink', title: row.name,
    subtitle: showPreviews === false ? 'Quicklink' : row.link, keywords: row.tags || [], typeLabel: 'Quicklink', glyph: row.icon ? '' : '↗', iconName: row.icon || '',
    rootSearch: { when: 'always' }, arguments: clean.arguments, fallbackStatus: clean.arguments.length === 1 ? 'available' : undefined }
}
function launchArgv(row, expanded, home) {
  var link = validateLink(expanded)
  if (link.indexOf('~/') === 0) { if (!home) throw new Error('Home directory unavailable'); link = home + link.slice(1) }
  return row.openWith ? ['gtk-launch', row.openWith, link] : ['xdg-open', link]
}
function faviconRequest(link, cache, id) {
  var match = /^(https?):\/\/([^/?#]+)(?:[/?#]|$)/i.exec(String(link).trim())
  if (!match) throw new Error('Favicons require an HTTP or HTTPS website URL')
  var authority = match[2]
  if (!/^[A-Za-z0-9.-]+(?::[0-9]{1,5})?$/.test(authority)) throw new Error('Favicon host must be literal: no placeholders, credentials or encoded hostnames')
  var host = authority.split(':')[0].toLowerCase().replace(/\.+$/, '')
  if (!host || host === 'raycast.com' || /\.raycast\.com$/.test(host)) throw new Error('Requests to raycast.com are not permitted')
  if (authority.indexOf(':') >= 0 && (+authority.split(':')[1] < 1 || +authority.split(':')[1] > 65535)) throw new Error('Invalid website port')
  if (!/^[A-Za-z0-9-]+$/.test(id) || typeof cache !== 'string' || cache[0] !== '/') throw new Error('Invalid favicon cache destination')
  var url = match[1].toLowerCase() + '://' + authority + '/favicon.ico'
  var path = cache + '/quicklink-favicon-' + id + '.ico'
  // No redirect following: even a same-origin request must not redirect to a forbidden host.
  return { url: url, path: path, argv: ['curl', '--disable', '--fail', '--silent', '--show-error', '--connect-timeout', '3', '--max-time', '10', '--max-filesize', '1048576', '--max-redirs', '0', '--proto', '=http,https', '--output', path, '--write-out', '%{http_code}', '--url', url] }
}
if (typeof module !== 'undefined') module.exports = { migrations: migrations, validate: validate, rows: rows, find: find, save: save, mutate: mutate, importJson: importJson, exportJson: exportJson, candidate: candidate, launchArgv: launchArgv, faviconRequest: faviconRequest }
