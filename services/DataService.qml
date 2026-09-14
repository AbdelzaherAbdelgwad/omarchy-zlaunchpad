import QtQuick
import Quickshell
import Quickshell.Io

// Owns persistence (directories, per-directory commands, shared presets),
// directory validation, and Git metadata refresh. Presentation lives in
// Panel.qml.
Item {
  id: root
  visible: false

  property var settings: ({})
  property var entries: []
  property var presets: []
  property var prefs: ({ keybind: "", autoRefresh: true, autoRefreshSec: 15 })
  property int selectedIndex: -1
  property string state: "loading"
  property string lastError: ""
  property string notice: ""
  property bool refreshing: false
  property string pendingPath: ""
  property var refreshQueue: []
  property int refreshIndex: -1

  // Directory search (fzf-style): fd runs with a fuzzy regex built from the
  // query; `find` covers machines without fd.
  property var suggestions: []
  property string suggestQuery: ""
  property bool suggestBusy: false
  property string suggestPending: ""
  property int suggestLimit: 40

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || home + "/.local/share"
  readonly property string dataDir: dataHome + "/omarchy-launchpad"
  readonly property string statePath: dataDir + "/state.json"
  // Omarchy's Hyprland config is Lua, and it loads every *.lua file in the
  // toggles directory (default/hypr/toggles.lua -> require_all.files). Writing
  // there binds a key without touching any user config file.
  readonly property string hyprDir: home + "/.local/state/omarchy/toggles/hypr"
  readonly property string keybindPath: hyprDir + "/zlaunchpad.lua"
  readonly property string keybindCommand: "omarchy-shell io.github.abdelzaherabdelgwad.zlaunchpad toggle"
  readonly property var selectedEntry:
    selectedIndex >= 0 && selectedIndex < entries.length ? entries[selectedIndex] : null
  readonly property string statusLabel: refreshing ? "Refreshing directories"
    : entries.length === 0 ? "No directories pinned"
    : entries.length === 1 ? "1 directory" : entries.length + " directories"

  function clone(value) { return JSON.parse(JSON.stringify(value)) }

  function gitCommand(path, arguments_) {
    return [
      "git",
      "-c", "core.hooksPath=/dev/null",
      "-c", "core.fsmonitor=false",
      "-C", path
    ].concat(arguments_)
  }

  function expandHome(path) {
    var value = String(path || "").trim()
    if (value === "~") return home
    if (value.indexOf("~/") === 0) return home + value.slice(1)
    return value
  }

  // --- normalization -------------------------------------------------------

  function normalizedCommand(candidate) {
    if (!candidate || typeof candidate !== "object") return null
    var command = String(candidate.command || "").trim()
    var label = String(candidate.label || "").trim()
    if (command === "" && label === "") return null
    return {
      label: (label !== "" ? label : command).slice(0, 40),
      command: command.slice(0, 400),
      keepOpen: candidate.keepOpen === true
    }
  }

  function normalizedPrefs(candidate) {
    var source = candidate && typeof candidate === "object" ? candidate : {}
    var seconds = parseInt(source.autoRefreshSec, 10)
    if (isNaN(seconds)) seconds = 15
    return {
      keybind: String(source.keybind || "").slice(0, 60),
      autoRefresh: source.autoRefresh !== false,
      autoRefreshSec: Math.max(5, Math.min(300, seconds))
    }
  }

  function normalizedEntry(candidate) {
    if (!candidate || typeof candidate !== "object") return null
    var path = String(candidate.path || "").trim()
    if (path === "" || path.indexOf("\n") >= 0) return null
    var commands = []
    if (Array.isArray(candidate.commands)) {
      for (var i = 0; i < candidate.commands.length; i++) {
        var command = normalizedCommand(candidate.commands[i])
        if (command) commands.push(command)
      }
    }
    return {
      path: path,
      name: String(candidate.name || path.split("/").pop() || path),
      isGit: candidate.isGit === true,
      branch: String(candidate.branch || ""),
      dirty: candidate.dirty === true,
      commitSubject: String(candidate.commitSubject || ""),
      defaultCommand: normalizedCommand(candidate.defaultCommand)
        || { label: "Terminal", command: "", keepOpen: false },
      commands: commands,
      checkedAt: String(candidate.checkedAt || ""),
      addedAt: String(candidate.addedAt || new Date().toISOString())
    }
  }

  // --- persistence ---------------------------------------------------------

  function load(raw) {
    var loadedEntries = []
    var loadedPresets = []
    var loadedPrefs = normalizedPrefs(null)
    var source = String(raw || "").trim()
    try {
      var parsed = source === "" ? { version: 1, entries: [], presets: [] } : JSON.parse(source)
      if (parsed && parsed.version === 1) {
        if (Array.isArray(parsed.entries)) {
          for (var i = 0; i < parsed.entries.length; i++) {
            var entry = normalizedEntry(parsed.entries[i])
            if (entry) loadedEntries.push(entry)
          }
        }
        if (Array.isArray(parsed.presets)) {
          for (var j = 0; j < parsed.presets.length; j++) {
            var preset = normalizedCommand(parsed.presets[j])
            if (preset) loadedPresets.push(preset)
          }
        }
        loadedPrefs = normalizedPrefs(parsed.prefs)
      }
    } catch (error) {
      lastError = "Could not read saved Launchpad data. The file was left untouched."
      entries = []
      presets = []
      selectedIndex = -1
      state = "error"
      return
    }
    entries = loadedEntries
    presets = loadedPresets
    prefs = loadedPrefs
    selectedIndex = loadedEntries.length > 0 ? 0 : -1
    state = loadedEntries.length > 0 ? "ready" : "empty"
    if (loadedEntries.length > 0) refreshAll()
  }

  function persist() {
    stateFile.setText(JSON.stringify({
      version: 1,
      entries: entries,
      presets: presets,
      prefs: prefs
    }, null, 2) + "\n")
  }

  function indexOfPath(path) {
    for (var i = 0; i < entries.length; i++) if (entries[i].path === path) return i
    return -1
  }

  function select(index) {
    if (index < 0 || index >= entries.length) return
    selectedIndex = index
    notice = ""
  }

  // --- directory search ----------------------------------------------------

  // "wgc" becomes "w.*g.*c" so any subsequence of the full path matches, the
  // way a fuzzy finder behaves. Each character is regex-escaped first.
  function fuzzyPattern(query) {
    var value = String(query || "").trim()
    var parts = []
    for (var i = 0; i < value.length; i++) {
      var character = value.charAt(i)
      if (character === " ") continue
      parts.push(character.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    }
    return parts.join(".*")
  }

  // The last typed segment is matched against directory NAMES, the earlier
  // segments against the path leading to them. That is what keeps "code/api"
  // from matching every deep path whose letters happen to spell it.
  function queryTail(value) {
    var parts = String(value || "").split("/")
    return parts[parts.length - 1]
  }

  function queryHead(value) {
    var parts = String(value || "").split("/")
    parts.pop()
    var head = []
    for (var i = 0; i < parts.length; i++) if (parts[i] !== "") head.push(parts[i])
    return head
  }

  function clearSuggestions() {
    suggestions = []
    suggestQuery = ""
    suggestPending = ""
  }

  function suggest(query) {
    var value = expandHome(query)
    if (value.length < 2) {
      clearSuggestions()
      return
    }
    if (suggestBusy) {
      suggestPending = query
      return
    }
    suggestQuery = query
    suggestBusy = true
    findProcess.output = ""
    // Name-only match (no --full-path), so fd returns a small candidate set;
    // the leading segments are applied as a filter in applySuggestions.
    // Always rooted at $HOME: searching "/" drags in /proc and /sys, and a
    // typed "/Work/..." is almost always "~/Work/...".
    findProcess.command = [
      "fd", "--type", "directory", "--absolute-path", "--hidden", "--follow",
      "--max-depth", "7", "--max-results", "400",
      "--exclude", ".git", "--exclude", "node_modules", "--exclude", ".cache",
      "--exclude", ".venv", "--exclude", "target", "--exclude", ".local/share/Trash",
      fuzzyPattern(queryTail(value)), home
    ]
    findProcess.running = true
  }

  function applySuggestions(text) {
    var value = expandHome(suggestQuery)
    var tail = queryTail(value).toLowerCase()
    var head = queryHead(value)
    var headPattern = head.length === 0 ? null
      : new RegExp(head.map(function(part) { return fuzzyPattern(part) }).join("[^\\0]*"), "i")

    var rows = String(text || "").split("\n")
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i].trim()
      if (row === "") continue
      if (row.length > 1 && row.charAt(row.length - 1) === "/") row = row.slice(0, -1)
      // Virtual filesystems carry copies of every real path; never offer them.
      if (row.indexOf("/proc/") === 0 || row.indexOf("/sys/") === 0
        || row.indexOf("/dev/") === 0 || row.indexOf("/run/") === 0) continue
      var parent = row.slice(0, row.lastIndexOf("/"))
      if (headPattern && !headPattern.test(parent)) continue
      out.push(row)
    }

    // Rank like a fuzzy finder: a directory whose name literally contains the
    // typed text wins, then an exact name, then shallower and shorter paths.
    out.sort(function(a, b) {
      var nameA = a.slice(a.lastIndexOf("/") + 1).toLowerCase()
      var nameB = b.slice(b.lastIndexOf("/") + 1).toLowerCase()
      var exact = (nameB === tail ? 1 : 0) - (nameA === tail ? 1 : 0)
      if (exact !== 0) return exact
      var contains = (nameB.indexOf(tail) >= 0 ? 1 : 0) - (nameA.indexOf(tail) >= 0 ? 1 : 0)
      if (contains !== 0) return contains
      var depth = a.split("/").length - b.split("/").length
      if (depth !== 0) return depth
      return a.length - b.length
    })
    suggestions = out.slice(0, suggestLimit)
  }

  function finishSuggest() {
    suggestBusy = false
    if (suggestPending !== "" && suggestPending !== suggestQuery) {
      var next = suggestPending
      suggestPending = ""
      suggest(next)
    } else {
      suggestPending = ""
    }
  }

  // --- directories ---------------------------------------------------------

  function add(path) {
    var candidate = expandHome(path)
    if (candidate === "" || candidate.indexOf("\n") >= 0) {
      notice = "Enter a directory."
      return
    }
    if (realpathProcess.running || statProcess.running) return
    pendingPath = candidate
    notice = "Checking directory…"
    realpathProcess.output = ""
    realpathProcess.command = ["realpath", "-e", "--", candidate]
    realpathProcess.running = true
  }

  function acceptDirectory(path) {
    var canonical = String(path || "").trim()
    if (canonical === "") {
      notice = "That directory could not be read."
      return
    }
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].path === canonical) {
        selectedIndex = i
        notice = "Directory is already pinned."
        return
      }
    }
    var next = clone(entries)
    next.push(normalizedEntry({
      path: canonical,
      name: canonical.split("/").pop() || canonical,
      addedAt: new Date().toISOString()
    }))
    entries = next
    selectedIndex = next.length - 1
    state = "ready"
    notice = "Directory pinned locally."
    persist()
    refreshOne(selectedIndex)
  }

  function removeAt(index) {
    if (index < 0 || index >= entries.length) return
    var next = clone(entries)
    next.splice(index, 1)
    entries = next
    selectedIndex = next.length === 0 ? -1 : Math.min(index, next.length - 1)
    state = next.length === 0 ? "empty" : "ready"
    notice = "Directory removed. Files were not changed."
    persist()
  }

  function removeByPath(path) {
    var canonical = expandHome(path)
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].path === canonical) {
        removeAt(i)
        return
      }
    }
    notice = "No pinned directory matches that path."
  }

  // Compact summary for IPC callers and scripts.
  function describe() {
    var rows = []
    for (var i = 0; i < entries.length; i++) {
      rows.push({
        path: entries[i].path,
        name: entries[i].name,
        isGit: entries[i].isGit,
        branch: entries[i].branch,
        dirty: entries[i].dirty,
        defaultCommand: entries[i].defaultCommand.command,
        commands: entries[i].commands.length
      })
    }
    return JSON.stringify({ entries: rows, presets: presets }, null, 2)
  }

  function rename(index, name) {
    if (index < 0 || index >= entries.length) return
    var next = clone(entries)
    var trimmed = String(name || "").trim().slice(0, 40)
    next[index].name = trimmed !== "" ? trimmed : next[index].path.split("/").pop()
    entries = next
    persist()
  }

  // --- preferences ---------------------------------------------------------

  function setPref(key, value) {
    var next = clone(prefs)
    next[key] = value
    prefs = normalizedPrefs(next)
    persist()
  }

  // "SUPER SHIFT, D" is what the recorder produces and what the panel shows;
  // Hyprland's Lua config wants "SUPER + SHIFT + D".
  function luaChord(value) {
    var parts = String(value || "").split(",")
    if (parts.length < 2) return ""
    var mods = parts[0].trim().split(/\s+/)
    var key = parts[1].trim()
    if (key === "") return ""
    return mods.concat([key]).join(" + ")
  }

  // The binding lives in a Lua file Hyprland already loads, so a reload applies
  // it. `hyprctl keyword` is refused on this setup ("keyword can't work with
  // non-legacy parsers"), which makes reload the supported path.
  function setKeybind(next) {
    var candidate = String(next || "").trim()
    var chord = luaChord(candidate)
    if (candidate !== "" && chord === "") {
      notice = "That combination could not be parsed."
      return
    }
    setPref("keybind", chord === "" ? "" : candidate)
    keybindFile.setText(chord === ""
      ? "-- Launchpad: no keybind set\n"
      : "-- Managed by the Launchpad plugin (io.github.abdelzaherabdelgwad.zlaunchpad).\n"
        + "o.bind(\"" + chord + "\", \"zLaunchpad\", \"" + keybindCommand + "\")\n")
    reloadProcess.command = ["hyprctl", "reload"]
    reloadProcess.running = true
    notice = chord === "" ? "Keybind cleared." : "Keybind set to " + candidate + "."
  }

  // --- ordering ------------------------------------------------------------

  function move(index, delta) {
    var target = index + delta
    if (index < 0 || index >= entries.length) return
    if (target < 0 || target >= entries.length) return
    var next = clone(entries)
    var moved = next.splice(index, 1)[0]
    next.splice(target, 0, moved)
    entries = next
    selectedIndex = target
    persist()
  }

  // --- commands ------------------------------------------------------------

  function setDefaultCommand(index, label, command, keepOpen) {
    if (index < 0 || index >= entries.length) return
    var next = clone(entries)
    next[index].defaultCommand = normalizedCommand({
      label: label, command: command, keepOpen: keepOpen
    }) || { label: "Terminal", command: "", keepOpen: false }
    entries = next
    persist()
    notice = "Default command saved."
  }

  function addCommand(index, label, command, keepOpen) {
    if (index < 0 || index >= entries.length) return
    var candidate = normalizedCommand({ label: label, command: command, keepOpen: keepOpen })
    if (!candidate) {
      notice = "Enter a command."
      return
    }
    var next = clone(entries)
    next[index].commands = next[index].commands.concat([candidate])
    entries = next
    persist()
    notice = "Command added."
  }

  function removeCommand(index, commandIndex) {
    if (index < 0 || index >= entries.length) return
    var next = clone(entries)
    if (commandIndex < 0 || commandIndex >= next[index].commands.length) return
    next[index].commands.splice(commandIndex, 1)
    entries = next
    persist()
  }

  function promoteCommand(index, commandIndex) {
    if (index < 0 || index >= entries.length) return
    var entry = entries[index]
    if (commandIndex < 0 || commandIndex >= entry.commands.length) return
    var command = entry.commands[commandIndex]
    setDefaultCommand(index, command.label, command.command, command.keepOpen)
  }

  // --- shared presets ------------------------------------------------------

  function addPreset(label, command, keepOpen) {
    var preset = normalizedCommand({ label: label, command: command, keepOpen: keepOpen })
    if (!preset) {
      notice = "Enter a preset command."
      return
    }
    presets = clone(presets).concat([preset])
    persist()
    notice = "Preset added."
  }

  function removePreset(presetIndex) {
    if (presetIndex < 0 || presetIndex >= presets.length) return
    var next = clone(presets)
    next.splice(presetIndex, 1)
    presets = next
    persist()
  }

  function copyPresetTo(index, presetIndex) {
    if (presetIndex < 0 || presetIndex >= presets.length) return
    var preset = presets[presetIndex]
    addCommand(index, preset.label, preset.command, preset.keepOpen)
  }

  // --- git refresh ---------------------------------------------------------

  function refreshOne(index) {
    if (index < 0 || index >= entries.length) return
    if (refreshing) {
      refreshQueue = refreshQueue.concat([index])
      return
    }
    refreshQueue = [index]
    beginNextRefresh()
  }

  function refreshAll() {
    if (refreshing || entries.length === 0) return
    var queue = []
    for (var i = 0; i < entries.length; i++) queue.push(i)
    refreshQueue = queue
    beginNextRefresh()
  }

  function beginNextRefresh() {
    if (refreshQueue.length === 0) {
      refreshing = false
      refreshIndex = -1
      persist()
      return
    }
    refreshing = true
    refreshIndex = refreshQueue[0]
    refreshQueue = refreshQueue.slice(1)
    statusProcess.output = ""
    statusProcess.command = gitCommand(entries[refreshIndex].path,
      ["status", "--porcelain=v2", "--branch"])
    statusProcess.running = true
  }

  function applyStatus(text) {
    var lines = String(text || "").split("\n")
    var branch = ""
    var dirty = false
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf("# branch.head ") === 0) branch = lines[i].slice(14).trim()
      else if (lines[i] !== "" && lines[i].charAt(0) !== "#") dirty = true
    }
    var resolved = branch === "(detached)" ? "detached HEAD" : branch
    var current = entries[refreshIndex]
    if (current.isGit === true && current.branch === resolved && current.dirty === dirty) return
    var next = clone(entries)
    next[refreshIndex].isGit = true
    next[refreshIndex].branch = resolved
    next[refreshIndex].dirty = dirty
    next[refreshIndex].checkedAt = new Date().toISOString()
    entries = next
  }

  function applyLog(text) {
    var fields = String(text || "").trim().split("\u001f")
    var subject = fields.length >= 2 ? fields[1] : ""
    if (entries[refreshIndex].commitSubject !== subject) {
      var next = clone(entries)
      next[refreshIndex].commitSubject = subject
      next[refreshIndex].checkedAt = new Date().toISOString()
      entries = next
    }
    beginNextRefresh()
  }

  function markPlainDirectory() {
    var current = entries[refreshIndex]
    if (current.isGit === false && current.branch === "" && current.commitSubject === "") {
      beginNextRefresh()
      return
    }
    var next = clone(entries)
    next[refreshIndex].isGit = false
    next[refreshIndex].branch = ""
    next[refreshIndex].dirty = false
    next[refreshIndex].commitSubject = ""
    next[refreshIndex].checkedAt = new Date().toISOString()
    entries = next
    beginNextRefresh()
  }

  // --- processes -----------------------------------------------------------

  Process {
    id: ensureDirProcess
    command: ["mkdir", "-p", root.dataDir, root.hyprDir]
    onExited: stateFile.reload()
  }

  FileView {
    id: keybindFile
    path: root.keybindPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  Process { id: reloadProcess }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.load(text())
    onLoadFailed: root.load("")
    onFileChanged: reload()
  }

  Process {
    id: findProcess
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: findProcess.output = text
    }
    onExited: function(exitCode) {
      if (exitCode === 0 || String(output || "").trim() !== "") {
        root.applySuggestions(output)
        root.finishSuggest()
        return
      }
      // No fd on this machine (or it errored): fall back to find + in-process
      // filtering so search still works.
      fallbackProcess.output = ""
      fallbackProcess.command = [
        "find", root.home,
        "-maxdepth", "7", "-type", "d",
        "-not", "-path", "*/.git/*",
        "-not", "-path", "*/node_modules/*",
        "-not", "-path", "*/.cache/*"
      ]
      fallbackProcess.running = true
    }
  }

  Process {
    id: fallbackProcess
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: fallbackProcess.output = text
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && String(output || "").trim() === "") {
        root.suggestions = []
        root.finishSuggest()
        return
      }
      var tail = new RegExp(root.fuzzyPattern(root.queryTail(root.expandHome(root.suggestQuery))), "i")
      var rows = String(output || "").split("\n")
      var kept = []
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i].trim()
        if (row === "") continue
        if (tail.test(row.slice(row.lastIndexOf("/") + 1))) kept.push(row)
      }
      root.applySuggestions(kept.join("\n"))
      root.finishSuggest()
    }
  }

  Process {
    id: realpathProcess
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: realpathProcess.output = text
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.notice = "That directory does not exist."
        return
      }
      root.pendingPath = String(output || "").trim()
      statProcess.output = ""
      statProcess.command = ["stat", "-L", "-c", "%F", "--", root.pendingPath]
      statProcess.running = true
    }
  }

  Process {
    id: statProcess
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: statProcess.output = text
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 || String(output || "").trim() !== "directory") {
        root.notice = "That path is not a directory."
        return
      }
      root.acceptDirectory(root.pendingPath)
    }
  }

  Process {
    id: statusProcess
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: statusProcess.output = text
    }
    onExited: function(exitCode) {
      if (root.refreshIndex < 0 || root.refreshIndex >= root.entries.length) {
        root.refreshing = false
        root.refreshQueue = []
        return
      }
      if (exitCode !== 0) {
        root.markPlainDirectory()
        return
      }
      root.applyStatus(output)
      logProcess.output = ""
      logProcess.command = root.gitCommand(root.entries[root.refreshIndex].path,
        ["log", "-1", "--format=%H%x1f%s%x1f%cI"])
      logProcess.running = true
    }
  }

  Process {
    id: logProcess
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: logProcess.output = text
    }
    onExited: function(exitCode) {
      if (root.refreshIndex < 0 || root.refreshIndex >= root.entries.length) {
        root.refreshing = false
        root.refreshQueue = []
        return
      }
      root.applyLog(exitCode === 0 ? output : "")
    }
  }

  Component.onCompleted: ensureDirProcess.running = true
}
