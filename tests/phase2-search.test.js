const test = require("node:test")
const assert = require("node:assert/strict")
const RS = require("../plugin/core/RootSearch.js")
const Quicklinks = require("../plugin/core/Quicklinks.js")
const Placeholders = require("../plugin/core/Placeholders.js")
const deps = {
  Ranker: require("../plugin/core/Ranker.js"),
  Frecency: require("../plugin/core/Frecency.js"),
  OmarchyMenu: require("../plugin/core/OmarchyMenu.js")
}
const context = extra => Object.assign({ commands: {}, frecency: {}, nowMs: 1700000000000, sensitivity: "medium" }, extra)
const link = (id, template) => Quicklinks.candidate({ id, name: "Lookup " + id, link: template, tags: [] }, Placeholders, true)
const candidates = [
  link("docs", "https://example.org/search?q={query}"),
  link("home", "https://example.org/"),
  link("pair", "https://example.org/{one}/{two}"),
  { id: "script:daily", type: "command", kind: "script", title: "Daily report", rootSearch: { when: "always" }, keywords: [] }
]

function ids(sections) { return sections.flatMap(section => section.rows.map(row => row.candidate.id)) }

test("ordered fallbacks preserve user choices and omit removed or disabled quicklinks", () => {
  const c = context({ fallbackIds: ["fallback:bing", "fallback:command:quicklink:docs", "fallback:google", "fallback:bing", "fallback:missing"] })
  assert.deepEqual(RS.enabledFallbacks(candidates, c).map(row => row.id), ["fallback:bing", "fallback:command:quicklink:docs", "fallback:google"])
  c.commands["quicklink:docs"] = { enabled: false }
  assert.deepEqual(RS.enabledFallbacks(candidates, c).map(row => row.id), ["fallback:bing", "fallback:google"])
  assert.deepEqual(RS.enabledFallbacks([], c).map(row => row.id), ["fallback:bing", "fallback:google"])
})

test("only a single-argument quicklink can consume the root fallback query", () => {
  const fallback = RS.fallbackCommands(candidates).filter(row => row.targetId)
  assert.deepEqual(fallback.map(row => [row.targetId, row.argument]), [["quicklink:docs", "query"]])
  const args = { [fallback[0].argument]: "space & slash/中文" }
  const expanded = Placeholders.resolve("https://example.org/search?q={query}", args)
  assert.equal(expanded, "https://example.org/search?q=space%20%26%20slash%2F%E4%B8%AD%E6%96%87")
})

test("all fallbacks may be disabled without disabling ordinary results", () => {
  const c = context({ fallbackIds: [] })
  assert.deepEqual(RS.rootSections(candidates, "zzzz-unmatched", c, deps), [])
  assert.ok(ids(RS.rootSections(candidates, "Daily", c, deps)).includes("script:daily"))
})

test("provider views isolate kinds while respecting aliases and disabled state", () => {
  const c = context({ commands: { "quicklink:docs": { alias: "manual" }, "quicklink:home": { enabled: false } } })
  assert.deepEqual(ids(RS.providerSections(candidates, "quicklink", "manual", c, deps)), ["quicklink:docs"])
  assert.deepEqual(ids(RS.providerSections(candidates, "script", "", c, deps)), ["script:daily"])
  assert.ok(!ids(RS.providerSections(candidates, "quicklink", "", c, deps)).includes("quicklink:home"))
  assert.ok(!ids(RS.providerSections(candidates, "quicklink", "Daily", c, deps)).includes("script:daily"))
})

test("HTTP URL queries offer explicit open/create actions without accepting executable schemes", () => {
  const sections = RS.rootSections([], "https://example.org/search?q=a%26b", context(), deps)
  assert.deepEqual(sections[0].rows.map(row => row.candidate.id), ["url:open", "url:create-quicklink"])
  assert.equal(sections[0].rows[0].candidate.url, "https://example.org/search?q=a%26b")
  assert.equal(RS.queryUrl("www.example.org/docs"), "https://www.example.org/docs")
  for (const input of ["javascript:alert(1)", "data:text/html,test", "file:///tmp/script", "https://", "https://a.example/ has spaces"])
    assert.deepEqual(RS.urlRows(input), [])
  assert.ok(!ids(RS.rootSections([], "https://example.org/", context({ filter: "applications" }), deps)).includes("url:open"))
})
