// Shared quicklink placeholder grammar (SPEC §8.3). I/O is supplied by the caller.
var known = ['clipboard', 'selection', 'uuid', 'argument', 'date', 'time', 'datetime', 'day', 'calculator', 'snippet', 'cursor', 'ai', 'browser-tab']
var modifiers = ['uppercase', 'lowercase', 'trim', 'percent-encode', 'json-stringify', 'raw']
function quoteEnd(c) { return c === '“' ? '”' : c === '‘' ? '’' : ('\"\'`”’'.indexOf(c) >= 0 ? c : '') }
function splitOutside(text, delimiter) {
  var parts = [], start = 0, quote = '', escaped = false
  for (var i = 0; i < text.length; i++) {
    var c = text[i]
    if (escaped) { escaped = false; continue }
    if (c === '\\') { escaped = true; continue }
    if (quote) { if (c === quote) quote = ''; continue }
    if (quoteEnd(c)) { quote = quoteEnd(c); continue }
    if (c === delimiter) { parts.push(text.slice(start, i)); start = i + 1 }
  }
  if (quote) throw new Error('Unclosed placeholder quote')
  parts.push(text.slice(start)); return parts
}
function unescapeValue(value) { return value.replace(/\\(.)/g, '$1') }
function choices(text) {
  return splitOutside(text, ',').map(function(part) {
    var pair = splitOutside(part, ':'), title = unescapeValue(pair.shift().trim())
    var value = pair.length ? unescapeValue(pair.join(':').trim()) : title
    if (!title || !value) throw new Error('Dropdown options need a title and value')
    return { title: title, value: value }
  })
}
function parseBody(body) {
  var parts = splitOutside(body, '|'), source = parts.shift().trim()
  var mods = parts.map(function(p) { var m = p.trim(); if (modifiers.indexOf(m) < 0) throw new Error('Unknown modifier: ' + m); return m })
  var match = /^([A-Za-z][A-Za-z.-]*)/.exec(source)
  if (!match) throw new Error('Invalid placeholder: ' + source)
  var keyword = match[1], rest = source.slice(keyword.length).trim(), options = {}
  if (known.indexOf(keyword) < 0 && keyword.indexOf('browser-tab.') !== 0) {
    if (source.indexOf('=') >= 0 || /[{}]/.test(source)) throw new Error('Unknown placeholder: ' + source)
    var colon = source.indexOf(':')
    options.name = (colon < 0 ? source : source.slice(0, colon)).trim()
    if (colon >= 0) options.default = unescapeValue(source.slice(colon + 1))
    keyword = 'argument'; rest = ''
  }
  while (rest) {
    var key = /^([A-Za-z]+)\s*=\s*/.exec(rest), name = key ? key[1] : ''
    if (key) rest = rest.slice(key[0].length)
    else if (['date', 'time', 'datetime', 'day'].indexOf(keyword) >= 0) name = quoteEnd(rest[0]) ? 'format' : 'offset'
    else throw new Error('Invalid options for ' + keyword)
    var value = '', quote = quoteEnd(rest[0]), end = 0
    if (quote) {
      end = 1
      for (; end < rest.length; end++) {
        var c = rest[end]
        if (c === '\\' && end + 1 < rest.length) {
          // Preserve list separators until the options-list parser sees them.
          var next = rest[++end]; value += name === 'options' && (next === ',' || next === ':') ? '\\' + next : next
        } else if (c === quote) break
        else value += c
      }
      if (end === rest.length) throw new Error('Unclosed placeholder quote')
      end++
    } else { var bare = /^\S+/.exec(rest); if (!bare) throw new Error('Missing option value'); value = bare[0]; end = value.length }
    if (Object.prototype.hasOwnProperty.call(options, name)) {
      if (!key && name === 'offset') options.offset += ' ' + value
      else throw new Error('Repeated option: ' + name)
    } else options[name] = value
    rest = rest.slice(end).trim()
  }
  var allowed = keyword === 'argument' ? ['name', 'default', 'options'] : keyword === 'clipboard' ? ['offset'] : ['date', 'time', 'datetime', 'day'].indexOf(keyword) >= 0 ? ['format', 'locale', 'offset'] : keyword === 'calculator' ? ['expression'] : []
  if (keyword === 'snippet') throw new Error('Nested snippets are unavailable until Phase 4')
  if (keyword === 'cursor' || keyword === 'ai' || keyword.indexOf('browser-tab') === 0) throw new Error(keyword + ' is not supported in quicklinks')
  Object.keys(options).forEach(function(k) { if (allowed.indexOf(k) < 0) throw new Error('Unknown ' + keyword + ' option: ' + k) })
  if (keyword === 'clipboard' && options.offset !== undefined && options.offset !== '0') throw new Error('Clipboard history is unavailable; use the current clipboard without offset')
  if (options.format && options.locale) throw new Error('format and locale are mutually exclusive')
  if (keyword === 'calculator' && !options.expression) throw new Error('Calculator requires expression')
  if (options.offset && keyword !== 'clipboard') applyOffset(new Date(0), options.offset)
  return { keyword: keyword, options: options, modifiers: mods }
}
function parse(template, depth) {
  depth = depth || 0
  if (depth > 8) throw new Error('Placeholder nesting is too deep')
  var text = String(template), tokens = [], literal = '', args = []
  for (var i = 0; i < text.length; i++) {
    if (text[i] !== '{') { literal += text[i]; continue }
    var quote = '', escaped = false, end = i + 1, aborted = false
    for (; end < text.length; end++) {
      var c = text[end]
      if (c === '\n' || c === '\r') { aborted = true; break }
      if (escaped) { escaped = false; continue }
      if (c === '\\') { escaped = true; continue }
      if (quote) { if (c === quote) quote = ''; continue }
      if (quoteEnd(c)) { quote = quoteEnd(c); continue }
      if (c === '{') throw new Error('Nested placeholders must be inside a quoted option')
      if (c === '}') break
    }
    if (aborted || end === text.length) { literal += text[i]; continue }
    if (literal) { tokens.push({ text: literal }); literal = '' }
    var token = parseBody(text.slice(i + 1, end)); i = end
    if (token.keyword === 'argument') {
      var name = token.options.name || 'argument' + (args.length + 1), index = -1
      for (var a = 0; a < args.length; a++) if (args[a].name === name) index = a
      var optionList = token.options.options ? choices(token.options.options) : []
      var definition = { name: name, placeholder: name, type: optionList.length ? 'dropdown' : 'text', required: token.options.default === undefined, default: token.options.default, data: optionList }
      if (index < 0) { index = args.length; args.push(definition) }
      else {
        var previous = args[index]
        if (definition.default !== undefined && previous.default !== undefined && definition.default !== previous.default) throw new Error('Conflicting defaults for argument ' + name)
        if (definition.data.length && previous.data.length && JSON.stringify(definition.data) !== JSON.stringify(previous.data)) throw new Error('Conflicting options for argument ' + name)
        if (definition.default !== undefined) { previous.default = definition.default; previous.required = false }
        if (definition.data.length) { previous.data = definition.data; previous.type = 'dropdown' }
      }
      if (args.length > 3) throw new Error('Quicklinks support at most three distinct arguments')
      token.argumentIndex = index
    }
    if (token.keyword === 'calculator') {
      var nested = parse(token.options.expression, depth + 1)
      nested.arguments.forEach(function(definition) {
        if (!args.some(function(arg) { return arg.name === definition.name })) args.push(definition)
      })
      if (args.length > 3) throw new Error('Quicklinks support at most three distinct arguments')
    }
    tokens.push(token)
  }
  if (literal) tokens.push({ text: literal })
  return { tokens: tokens, arguments: args }
}
function applyOffset(date, expression) {
  var result = new Date(date.getTime()), rest = String(expression || '').trim()
  while (rest) {
    var m = /^([+-]\d+)([mhHdDMyY])(?:\s+|$)/.exec(rest)
    if (!m) throw new Error('Invalid date offset: ' + rest)
    var n = Number(m[1]), unit = m[2]
    if (unit === 'm') result.setMinutes(result.getMinutes() + n)
    else if (unit === 'h' || unit === 'H') result.setHours(result.getHours() + n)
    else if (unit === 'd' || unit === 'D') result.setDate(result.getDate() + n)
    else {
      // Calendar arithmetic clamps month-end rather than spilling into another month.
      var day = result.getDate(); result.setDate(1)
      if (unit === 'M') result.setMonth(result.getMonth() + n)
      else result.setFullYear(result.getFullYear() + n)
      var last = new Date(result.getFullYear(), result.getMonth() + 1, 0).getDate()
      result.setDate(Math.min(day, last))
    }
    rest = rest.slice(m[0].length)
  }
  return result
}
function resolve(parsed, values, env, encode, depth) {
  env = env || {}; values = values || {}; depth = depth || 0
  if (depth > 8) throw new Error('Placeholder nesting is too deep')
  if (typeof parsed === 'string') parsed = parse(parsed)
  var supplied = values
  values = Object.assign({}, Array.isArray(supplied) ? {} : supplied)
  parsed.arguments.forEach(function(definition, index) {
    var value = Array.isArray(supplied) ? supplied[index] : supplied[definition.name]
    if (value === undefined || value === null || value === '') value = definition.default
    if (value !== undefined) values[definition.name] = value
  })
  return parsed.tokens.map(function(token) {
    if (token.text !== undefined) return token.text
    var o = token.options, k = token.keyword, value, alreadyEncoded = false
    if (k === 'argument') {
      var def = parsed.arguments[token.argumentIndex]
      value = values[def.name]
      if (value === undefined || value === null || value === '') value = def.default
      if (value === undefined) throw new Error('Missing argument: ' + def.name)
      if (def.data.length && !def.data.some(function(item) { return item.value === String(value) })) throw new Error('Invalid option for ' + def.name)
    } else if (k === 'clipboard' || k === 'selection' || k === 'uuid') {
      if (env[k] === undefined) throw new Error(k + ' is unavailable')
      value = typeof env[k] === 'function' ? env[k]() : env[k]
    } else if (k === 'calculator') {
      if (!env.calculate) throw new Error('Calculator is unavailable')
      value = env.calculate(resolve(o.expression, values, env, false, depth + 1))
    } else {
      if (!env.formatDate) throw new Error('Date formatter is unavailable')
      value = env.formatDate(applyOffset(new Date(env.nowMs === undefined ? Date.now() : env.nowMs), o.offset), k, o.format, o.locale)
    }
    if (value === undefined || value === null) throw new Error('No value for ' + k)
    value = String(value)
    token.modifiers.forEach(function(mod) {
      if (mod === 'uppercase') value = value.toUpperCase()
      else if (mod === 'lowercase') value = value.toLowerCase()
      else if (mod === 'trim') value = value.trim()
      else if (mod === 'percent-encode') { value = encodeURIComponent(value); alreadyEncoded = true }
      else if (mod === 'json-stringify') value = JSON.stringify(value)
    })
    return encode !== false && token.modifiers.indexOf('raw') < 0 && !alreadyEncoded ? encodeURIComponent(value) : value
  }).join('')
}
function needs(parsed, keyword) {
  return parsed.tokens.some(function(t) { return t.keyword === keyword || (t.keyword === 'calculator' && needs(parse(t.options.expression), keyword)) })
}
if (typeof module !== 'undefined') module.exports = { parse: parse, resolve: resolve, applyOffset: applyOffset, needs: needs, choices: choices }
