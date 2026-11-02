import QtQuick
import Quickshell
import qs.services
import "Plugin" as Plugin
import "Plugin/core/Paths.js" as Paths

// Development host: shares installed Omarchy UI/app services, never its launcher data.
ShellRoot {
  id: preview
  property AppLibrary applications: AppLibrary {}
  property QtObject host: QtObject {
    property var appLibrary: preview.applications
    function summon(id, payload) {
      if (id === "typecraft.oma-cast") return false
      Quickshell.execDetached(["omarchy-shell", "shell", "summon", id, payload])
      return true
    }
    function hide(id) { return false }
  }
  Plugin.Launcher {
    shell: preview.host
    ipcTarget: "oma-cast-preview"
    ipcConfigPath: Quickshell.env("OMA_CAST_PREVIEW_HOME") + "/shell"
    pathOverrides: Paths.resolve(function(name) {
      var base = Quickshell.env("OMA_CAST_PREVIEW_HOME")
      var isolated = { XDG_CONFIG_HOME: base + "/config", XDG_DATA_HOME: base + "/data",
        XDG_CACHE_HOME: base + "/cache", XDG_STATE_HOME: base + "/state", XDG_RUNTIME_DIR: base + "/runtime" }
      return isolated[name] || Quickshell.env(name)
    })
  }
}
