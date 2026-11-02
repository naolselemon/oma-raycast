import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import "../core/Placeholders.js" as Placeholders

ApplicationWindow {
  id: window
  required property var backend
  title: "oma-cast · Quicklinks"
  width: 780
  height: 700
  minimumWidth: 600
  minimumHeight: 500
  visible: false
  transientParent: null
  color: Commons.Color.menu.background
  font.family: Style.font.menuFamily
  palette.window: Commons.Color.menu.background
  palette.base: Commons.Color.menu.background
  palette.text: Commons.Color.menu.text
  palette.windowText: Commons.Color.menu.text
  palette.button: Commons.Color.menu.selectedBackground
  palette.buttonText: Commons.Color.menu.text
  palette.highlight: Commons.Color.menu.selectedBackground
  palette.highlightedText: Commons.Color.menu.selectedText
  property string mode: "manage"
  property string itemId: ""
  property var items: []
  property var applications: [{ id: "", name: "Default browser / file handler", icon: "" }]
  property string error: ""
  property string notice: ""
  property bool busy: false
  property bool dirty: false
  property bool loadingForm: false
  property var pendingOpen: null
  property bool closeAfterDiscard: false
  readonly property bool editing: mode === "create" || mode === "edit"

  function call(method, data, success) {
    error = ""; notice = ""; busy = true
    backend.call(method, data).then(function(result) { window.busy = false; if (success) success(result) }).catch(function(e) { window.busy = false; window.error = String(e) })
  }
  function refresh() { call("quicklinks.list", { query: filter.text }, function(rows) { window.items = rows }) }
  function open(payload) {
    payload = payload || { mode: "manage" }
    if (dirty) { pendingOpen = payload; discard.open(); return }
    loadingForm = true; mode = payload.mode || "manage"; itemId = payload.id || ""; error = ""; notice = ""
    nameField.text = ""; linkField.text = payload.url || ""; tagsField.text = ""; iconField.text = ""; openWith.currentIndex = 0
    overwrite.checked = false; filePath.text = ""; dirty = false; loadingForm = false
    visible = true; raise(); requestActivate()
    backend.call("quicklinks.applications", null).then(function(apps) {
      window.applications = [{ id: "", name: "Default browser / file handler", icon: "" }].concat(apps)
      if (window.itemId && (window.mode === "edit" || window.mode === "delete")) window.loadItem()
    }).catch(function(e) { window.error = String(e) })
    if (mode === "manage") refresh()
    if (mode === "create") nameField.forceActiveFocus()
    else if (mode === "import" || mode === "export") filePath.forceActiveFocus()
  }
  function loadItem() {
    call("quicklinks.getQuicklink", { id: itemId }, function(row) {
      window.loadingForm = true
      nameField.text = row.name; linkField.text = row.link; tagsField.text = row.tags.join(", "); iconField.text = row.icon || ""
      var index = window.applications.findIndex(function(app) { return app.id === row.openWith })
      if (index < 0 && row.openWith) { window.applications = window.applications.concat([{ id: row.openWith, name: row.openWith, icon: "" }]); index = window.applications.length - 1 }
      openWith.currentIndex = Math.max(0, index); window.loadingForm = false; window.dirty = false
    })
  }
  function markDirty() { if (!loadingForm && editing) dirty = true }
  function save() {
    var data = { name: nameField.text, link: linkField.text, tags: tagsField.text.split(",").filter(function(s) { return s.trim() }), icon: iconField.text, openWith: applications[openWith.currentIndex] ? applications[openWith.currentIndex].id : "" }
    if (mode === "edit") data.id = itemId
    call(mode === "edit" ? "quicklinks.update" : "quicklinks.save", data, function() { window.dirty = false; window.open({ mode: "manage" }); window.notice = "Quicklink saved" })
  }
  function insertPlaceholder(text) { linkField.insert(linkField.cursorPosition, text); linkField.forceActiveFocus() }
  onClosing: function(event) { if (dirty) { event.accepted = false; closeAfterDiscard = true; discard.open() } }
  Shortcut { sequence: "Escape"; onActivated: window.close() }
  Shortcut { sequence: "Ctrl+S"; enabled: window.editing && !window.busy; onActivated: window.save() }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 20
    spacing: 12
    RowLayout {
      Layout.fillWidth: true
      Label { text: window.editing ? (window.mode === "edit" ? "Edit Quicklink" : "Create Quicklink") : window.mode === "delete" ? "Delete Quicklink?" : window.mode === "import" ? "Import Quicklinks" : window.mode === "export" ? "Export Quicklinks" : "Quicklinks"; textFormat: Text.PlainText; font.pixelSize: 22; Layout.fillWidth: true }
      Button { text: "Manage"; enabled: !window.busy; onClicked: window.open({ mode: "manage" }) }
      Button { text: "New"; enabled: !window.busy; onClicked: window.open({ mode: "create" }) }
    }
    Label { visible: window.error !== ""; text: window.error; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: Commons.Color.menu.text }
    Label { visible: window.notice !== ""; text: window.notice; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true }
    BusyIndicator { visible: window.busy; running: visible; Layout.preferredHeight: 28 }

    ColumnLayout {
      visible: window.mode === "manage"
      Layout.fillWidth: true
      Layout.fillHeight: true
      TextField { id: filter; placeholderText: "Search quicklinks by name, URL or tag"; Layout.fillWidth: true; onTextEdited: window.refresh() }
      ListView {
        Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 8
        model: window.items
        ScrollBar.vertical: ScrollBar {}
        delegate: Rectangle {
          required property var modelData
          width: ListView.view.width; height: rowContent.implicitHeight + 16
          color: Commons.Color.menu.selectedBackground
          ColumnLayout {
            id: rowContent
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
            RowLayout {
              Layout.fillWidth: true
              Label { text: modelData.name; textFormat: Text.PlainText; font.bold: true; Layout.fillWidth: true; elide: Text.ElideRight }
              Label { text: String(modelData.openCount || 0) + " opens"; textFormat: Text.PlainText }
              Button { text: "Edit"; onClicked: window.open({ mode: "edit", id: modelData.id }) }
              Button { text: "Delete"; onClicked: window.open({ mode: "delete", id: modelData.id }) }
            }
            Label { text: modelData.link; textFormat: Text.PlainText; wrapMode: Text.WrapAnywhere; Layout.fillWidth: true; visible: { var r = window.backend.callSync("settings.getQuicklinkPreferences", null); return !r.ok || r.data.showPreviews } }
            Label { text: (modelData.tags || []).join(" · "); textFormat: Text.PlainText; visible: text !== ""; Layout.fillWidth: true }
          }
        }
      }
      Label { visible: window.items.length === 0 && !window.busy; text: "No quicklinks. Create one or import a local JSON file."; textFormat: Text.PlainText }
      RowLayout {
        Button { text: "Import…"; onClicked: window.open({ mode: "import" }) }
        Button { text: "Export All…"; onClicked: window.open({ mode: "export" }) }
      }
    }

    ScrollView {
      visible: window.editing
      Layout.fillWidth: true; Layout.fillHeight: true
      contentWidth: availableWidth
      ColumnLayout {
        width: parent.width
        spacing: 10
        Label { text: "Name"; textFormat: Text.PlainText }
        TextField { id: nameField; placeholderText: "Search DuckDuckGo"; Layout.fillWidth: true; onTextChanged: window.markDirty() }
        Label { text: "Link template"; textFormat: Text.PlainText }
        TextField { id: linkField; placeholderText: "https://duckduckgo.com/?q={query}"; Layout.fillWidth: true; onTextChanged: window.markDirty() }
        Label { text: "Arguments (maximum 3) appear as launcher pills. Values are URL-encoded; | raw opts out."; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true }
        RowLayout {
          Button { text: "Add Argument"; onClicked: window.insertPlaceholder('{argument name="query"}') }
          Button { text: "Add Dropdown"; onClicked: window.insertPlaceholder('{argument name="category" default="all" options="All: all, News: news"}') }
          Button { text: "Clipboard"; onClicked: window.insertPlaceholder('{clipboard}') }
        }
        Label { text: 'Other placeholders: {selection}, {uuid}, {date format="yyyy-MM-dd" offset="+1d"}, {time}, {day}, {calculator expression="2+2"}. Modifiers: trim, uppercase, lowercase, percent-encode, json-stringify, raw. Clipboard history and nested snippets are unavailable.'; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true }
        Label {
          Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
          text: {
            try { var parsed = Placeholders.parse(linkField.text); return parsed.arguments.length ? "Argument fields: " + parsed.arguments.map(function(arg) { return arg.name + (arg.type === "dropdown" ? " (dropdown: " + arg.data.map(function(c) { return c.title }).join(", ") + ")" : "") + (arg.default !== undefined ? " — default: " + arg.default : " — required") }).join("; ") : "No argument fields" }
            catch (e) { return "Template error: " + e }
          }
        }
        Label { text: "Open With"; textFormat: Text.PlainText }
        ComboBox {
          id: openWith; Layout.fillWidth: true; model: window.applications; textRole: "name"
          onActivated: window.markDirty()
          contentItem: Text { text: openWith.displayText; textFormat: Text.PlainText; color: Commons.Color.menu.text; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
          delegate: ItemDelegate {
            required property var modelData
            width: openWith.width
            contentItem: Text { text: modelData.name; textFormat: Text.PlainText; color: Commons.Color.menu.text; elide: Text.ElideRight }
          }
        }
        Label { text: "Icon (local image path or application theme icon)"; textFormat: Text.PlainText }
        RowLayout {
          TextField { id: iconField; placeholderText: "firefox or /home/you/Pictures/icon.png"; Layout.fillWidth: true; onTextChanged: window.markDirty() }
          Button { text: "Use App Icon"; onClicked: iconField.text = window.applications[openWith.currentIndex].icon || "" }
          Button { text: "Fetch Favicon…"; enabled: !window.busy; onClicked: faviconConfirm.open() }
        }
        Label { text: "Icons are local. Fetch Favicon optionally contacts this website once after confirmation. No periodic favicon refresh or remote link previews."; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true }
        Label { text: "Tags (comma separated)"; textFormat: Text.PlainText }
        TextField { id: tagsField; Layout.fillWidth: true; placeholderText: "work, search"; onTextChanged: window.markDirty() }
        RowLayout {
          Button { text: "Save (Ctrl+S)"; enabled: !window.busy; onClicked: window.save() }
          Button { text: "Cancel"; enabled: !window.busy; onClicked: window.open({ mode: "manage" }) }
        }
      }
    }

    ColumnLayout {
      visible: window.mode === "import" || window.mode === "export"
      Layout.fillWidth: true; Layout.fillHeight: true
      Label { text: window.mode === "import" ? 'Import a local JSON array: [{"name":"Example","link":"https://example.org","openWith":"firefox"}]. Imports add new quicklinks; existing entries are never replaced.' : "Export compatible JSON (name, link and Open With). Icons, tags and usage counts remain in the local database, not this interchange file."; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true }
      TextField { id: filePath; placeholderText: "/home/you/quicklinks.json"; Layout.fillWidth: true }
      CheckBox { id: overwrite; visible: window.mode === "export"; text: "I confirm replacing the selected file if it already exists" }
      Button {
        text: window.mode === "import" ? "Import File" : "Export File"
        enabled: !window.busy && filePath.text.length > 0
        onClicked: window.call(window.mode === "import" ? "quicklinks.import" : "quicklinks.export", { path: filePath.text, id: window.itemId, confirmed: overwrite.checked }, function(result) { window.notice = window.mode === "import" ? "Imported " + result.length + " quicklinks" : "Exported to " + result.path })
      }
      Item { Layout.fillHeight: true }
    }
    ColumnLayout {
      visible: window.mode === "delete"; Layout.fillWidth: true; Layout.fillHeight: true
      Label { text: "Permanently delete “" + nameField.text + "”? This cannot be undone."; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true }
      RowLayout {
        Button { text: "Cancel"; onClicked: window.open({ mode: "manage" }) }
        Button { text: "Delete Permanently"; enabled: !window.busy; onClicked: window.call("quicklinks.delete", { id: window.itemId, confirmed: true }, function() { window.open({ mode: "manage" }) }) }
      }
      Item { Layout.fillHeight: true }
    }
  }
  Dialog {
    id: faviconConfirm
    anchors.centerIn: parent
    width: Math.min(window.width - 40, 520)
    title: "Contact website for favicon?"
    modal: true
    standardButtons: Dialog.Ok | Dialog.Cancel
    contentItem: Label {
      text: "Download /favicon.ico from the website in this link:\n\n" + linkField.text + "\n\nThis sends one request directly to that website (not a third-party icon provider). Redirects are rejected. The icon is cached locally; it is never refreshed automatically."
      textFormat: Text.PlainText
      wrapMode: Text.WrapAnywhere
    }
    onAccepted: window.call("quicklinks.fetchFavicon", { link: linkField.text, confirmed: true }, function(result) { iconField.text = result.icon; window.notice = "Favicon downloaded from " + result.url })
  }
  Dialog {
    id: discard
    anchors.centerIn: parent
    title: "Discard unsaved changes?"
    modal: true
    standardButtons: Dialog.Discard | Dialog.Cancel
    onDiscarded: {
      window.dirty = false
      if (window.closeAfterDiscard) { window.closeAfterDiscard = false; window.close() }
      else { var payload = window.pendingOpen; window.pendingOpen = null; window.open(payload) }
    }
    onRejected: { window.closeAfterDiscard = false; window.pendingOpen = null }
  }
}
