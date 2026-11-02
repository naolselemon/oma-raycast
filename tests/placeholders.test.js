const test = require('node:test')
const assert = require('node:assert/strict')
const P = require('../plugin/core/Placeholders.js')

test('quicklink arguments are encoded exactly once and never interpreted as shell', () => {
  const value = 'a & b/$(touch /tmp/no);"雪"'
  assert.equal(P.resolve('https://example.org/?q={query}', { query: value }), 'https://example.org/?q=' + encodeURIComponent(value))
  assert.equal(P.resolve('{query | percent-encode}', { query: value }), encodeURIComponent(value))
  assert.equal(P.resolve('{query | raw}', { query: value }), value)
  assert.equal(P.resolve('{query | trim | uppercase}', { query: ' a b ' }), 'A%20B')
  assert.equal(P.resolve('{query | json-stringify}', { query: '"' }), encodeURIComponent(JSON.stringify('"')))
})

test('named, legacy, default and dropdown arguments share their declared positions', () => {
  const parsed = P.parse('{query}/{query}/{Search Term:default}/{argument name="category" default="all" options="All: all, News: news"}')
  assert.equal(parsed.arguments.length, 3)
  assert.equal(P.resolve(parsed, { query: 'hello world' }), 'hello%20world/hello%20world/default/all')
  assert.equal(parsed.arguments[2].type, 'dropdown')
  assert.throws(() => P.resolve(parsed, { query: 'x', category: 'invalid' }), /Invalid option/)
  assert.throws(() => P.parse('{a}{b}{c}{d}'), /at most three/)
  assert.throws(() => P.resolve('{required}', {}), /Missing argument/)
  assert.equal(P.resolve('{argument name="x" default="3"}/{x}', {}), '3/3')
})

test('quotes, escaped list separators and nested calculator inputs parse without splitting', () => {
  assert.equal(P.resolve('{argument name=“query” default=‘a|b’}', {}), 'a%7Cb')
  assert.equal(P.resolve('{argument name=`q` default="a\\\"b"}', {}), 'a%22b')
  const parsed = P.parse('{argument name="x" default="a,b" options="Comma: a\\,b, Colon: c\\:d"}')
  assert.deepEqual(parsed.arguments[0].data, [{ title: 'Comma', value: 'a,b' }, { title: 'Colon', value: 'c:d' }])
  assert.equal(P.resolve(parsed, {}), 'a%2Cb')
  assert.equal(P.resolve('{calculator expression="{clipboard} + 2"}', {}, { clipboard: '3', calculate: expression => { assert.equal(expression, '3 + 2'); return '5' } }), '5')
  assert.equal(P.needs(P.parse('{calculator expression="{selection}"}'), 'selection'), true)
  const nested = P.parse('{calculator expression="{amount} + 2"}')
  assert.equal(nested.arguments[0].name, 'amount')
  assert.equal(P.resolve(nested, { amount: '4' }, { calculate: expression => { assert.equal(expression, '4 + 2'); return '6' } }), '6')
  assert.throws(() => P.parse('{calculator expression={clipboard}}'), /Nested/)
  assert.equal(P.resolve('literal {query\nvalue}', {}), 'literal {query\nvalue}')
})

test('date offsets use calendar arithmetic and injected formatting', () => {
  const now = new Date(2024, 0, 31, 10, 20, 30)
  let observed
  const env = { nowMs: now.getTime(), formatDate: (date, kind, format, locale) => { observed = { date, kind, format, locale }; return 'formatted date' } }
  assert.equal(P.resolve('{date "yyyy-MM-dd" +1M -2h}', {}, env), 'formatted%20date')
  assert.equal(observed.date.getMonth(), 1)
  assert.equal(observed.date.getDate(), 29)
  assert.equal(observed.date.getHours(), 8)
  assert.equal(observed.format, 'yyyy-MM-dd')
  P.resolve('{datetime locale="fr-FR" offset="+1d +30m"}', {}, env)
  assert.equal(observed.locale, 'fr-FR')
  assert.equal(observed.kind, 'datetime')
  assert.equal(observed.date.getMinutes(), 50)
  assert.throws(() => P.parse('{date format="yyyy" locale="en"}'), /mutually exclusive/)
  assert.throws(() => P.parse('{date offset="+1w"}'), /Invalid date offset/)
})

test('unavailable features and typo options fail explicitly', () => {
  for (const template of ['{clipboard offset=1}', '{snippet name="signature"}', '{cursor}', '{browser-tab.url}', '{ai prompt="hello"}', '{date typo="x"}', '{query | unknown}']) {
    assert.throws(() => P.parse(template), Error, template)
  }
  assert.equal(P.resolve('{clipboard offset=0}', {}, { clipboard: 'current' }), 'current')
  assert.throws(() => P.resolve('{selection}', {}), /unavailable/)
  assert.equal(P.resolve('{uuid}', {}, { uuid: () => 'test-uuid' }), 'test-uuid')
})
