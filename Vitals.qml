import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Vitals shows live CPU, memory, disk, temperature, GPU, and network usage in the bar.
// Each capped metric is an icon that fills with usage. Click opens the
// settings panel, in tabs: which metrics are shown and in what order,
// display options including bar position, which GPUs are shown, and the
// colors those readings switch to.
//
// The CPU, memory, disk, temperature, and network sampling is adapted from
// Kenny De Mits' omarchy-bar-resources (MIT).
Panel {
  id: root
  moduleName: "crome.vitals"
  ipcTarget: "crome.vitals"
  manageIpc: false

  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var settingDefaults: ({
    showPercent: true,
    memoryAsAmount: false,
    accentFill: true,
    thresholdsEnabled: true,
    usageWarn: 70,
    usageCrit: 90,
    tempWarn: 70,
    tempCrit: 85,
    colorNormal: "",
    colorWarn: "#e6b84a",
    colorCrit: "",
    colorValue: "",
    trackCpu: true,
    trackMem: true,
    trackDisk: true,
    trackTemp: true,
    trackGpu: true,
    trackGpuTemp: true,
    trackNet: false
  })

  readonly property var displayOptionRows: [
    { key: "showPercent", label: "Show percentage", description: "Show the exact % next to the CPU, disk, and GPU icons. Memory uses this unless Memory as amount is on." },
    { key: "memoryAsAmount", label: "Memory as amount", description: "Show used memory as a size, such as 17GB, instead of a percentage. The icon still fills by percent." },
    { key: "accentFill", label: "Use accent color", description: "When the normal color is automatic, fill icons with your theme accent instead of the bar text color." },
    { key: "thresholdsEnabled", label: "Color thresholds", description: "Color each icon from the warning and critical levels. Numbers follow the icon unless Value color is set." }
  ]

  readonly property bool showPercent: setting("showPercent", settingDefaults.showPercent)
  readonly property bool memoryAsAmount: setting("memoryAsAmount", settingDefaults.memoryAsAmount) === true
  readonly property bool accentFill: setting("accentFill", settingDefaults.accentFill)
  readonly property bool thresholdsEnabled: setting("thresholdsEnabled", settingDefaults.thresholdsEnabled) !== false
  readonly property var usageThresholds: Model.normalizeThresholds(setting("usageWarn", settingDefaults.usageWarn), setting("usageCrit", settingDefaults.usageCrit), 0, 100)
  readonly property var tempThresholds: Model.normalizeThresholds(setting("tempWarn", settingDefaults.tempWarn), setting("tempCrit", settingDefaults.tempCrit), 0, 120)
  readonly property int usageWarn: usageThresholds.warn
  readonly property int usageCrit: usageThresholds.crit
  readonly property int tempWarn: tempThresholds.warn
  readonly property int tempCrit: tempThresholds.crit

  readonly property bool trackCpu: setting("trackCpu", settingDefaults.trackCpu)
  readonly property bool trackMem: setting("trackMem", settingDefaults.trackMem)
  readonly property bool trackDisk: setting("trackDisk", settingDefaults.trackDisk)
  readonly property bool trackTemp: setting("trackTemp", settingDefaults.trackTemp)
  readonly property bool trackGpu: setting("trackGpu", settingDefaults.trackGpu)
  readonly property bool trackGpuTemp: setting("trackGpuTemp", settingDefaults.trackGpuTemp)
  readonly property bool trackNet: setting("trackNet", settingDefaults.trackNet)

  readonly property var defaultOrder: ["cpu", "mem", "disk", "temp", "gpu", "gputemp", "net"]
  readonly property var order: {
    var raw = setting("order", root.defaultOrder)
    if (!Array.isArray(raw)) return root.defaultOrder
    var seen = ({})
    var result = []
    for (var i = 0; i < raw.length; i++) {
      var key = String(raw[i])
      if (root.defaultOrder.indexOf(key) !== -1 && !seen[key]) {
        result.push(key)
        seen[key] = true
      }
    }
    for (var j = 0; j < root.defaultOrder.length; j++) if (!seen[root.defaultOrder[j]]) result.push(root.defaultOrder[j])
    return result
  }

  // Ids the user turned off. A GPU missing from this list is shown, including
  // one discovered after the setting was saved.
  readonly property var disabledGpuIds: {
    var raw = setting("disabledGpus", [])
    if (!Array.isArray(raw)) return []
    var ids = []
    for (var i = 0; i < raw.length; i++) ids.push(String(raw[i]))
    return ids
  }

  // Mobile packages throttle around 100C. This band is only how full the
  // thermometer looks; the color comes from the temperature thresholds.
  readonly property real tempFloor: 30
  readonly property real tempCeiling: 95

  // The tab strip is cursor row 0. Rows after it belong to the open tab.
  readonly property var settingsTabOrder: ["metrics", "display", "gpus", "thresholds"]
  readonly property var colorCursorKeys: ["colorNormal", "colorWarn", "colorCrit", "colorValue"]
  readonly property var colorCursorRoles: ["normal", "warn", "critical"]
  property string settingsTab: "metrics"

  property int selectedIndex: 0
  property bool cursorActive: false
  property bool editorActive: false
  property bool sampleRebuildPending: false

  property var prevCpuSample: null
  property var prevNetSample: null
  property real prevNetSampleTime: 0
  property string tempSensorPath: ""
  property bool tempSensorResolved: false

  property var gpuCatalog: []
  property bool gpuDiscoveryDone: false
  property var gpuReadings: ({})

  property int cpuPct: -1
  property int memPct: -1
  property real memTotalBytes: 0
  property real memUsedBytes: 0
  property int diskPct: -1
  property real diskTotalBytes: 0
  property real diskUsedBytes: 0
  property var tempC: null
  property real netDownBps: 0
  property real netUpBps: 0
  property bool netReady: false

  readonly property int enabledGpuCount: {
    var count = 0
    for (var i = 0; i < root.gpuCatalog.length; i++) if (root.isGpuEnabled(root.gpuCatalog[i].gpuId)) count++
    return count
  }

  // Stable repeater model. An inline array in the panel would be a new
  // value whenever that binding re-ran, rebuilding the color rows.
  readonly property var colorChoices: [
    { key: "colorNormal", label: "Normal", colorRole: "normal", description: "" },
    { key: "colorWarn", label: "Warning", colorRole: "warn", description: "" },
    { key: "colorCrit", label: "Critical", colorRole: "critical", description: "" },
    { key: "colorValue", label: "Value color", colorRole: "value", description: "Automatic uses each icon's color. Pick a color to use it for the numbers instead." }
  ]

  readonly property bool anyTracked: {
    for (var i = 0; i < root.order.length; i++) if (root.metricRowVisible(root.order[i])) return true
    return false
  }

  function refresh() {
    if (sampleProc.running || root.sampleRebuildPending) return
    sampleProc.running = true
  }

  function applySampleCommand() {
    sampleProc.command = ["bash", "-c", Model.sampleScript(root.tempSensorPath, root.gpuCatalog, root.disabledGpuIds, root.opened)]
  }

  // The sampler is one long-lived process slot. A settings change that
  // happens mid-sample waits until that process exits, then runs the script
  // that matches the new GPU selection.
  function rebuildSampleCommand() {
    if (sampleProc.running) {
      root.sampleRebuildPending = true
      return
    }
    root.applySampleCommand()
  }

  function finishSample(text) {
    root.applySample(text)
    root.restartSampleIfPending()
  }

  function restartSampleIfPending() {
    if (!root.sampleRebuildPending) return
    root.sampleRebuildPending = false
    root.applySampleCommand()
    Qt.callLater(function() {
      if (!sampleProc.running) sampleProc.running = true
    })
  }

  function applySample(text) {
    var now = Date.now()
    var sections = Model.splitSections(text)

    var cpu = Model.parseCpuLine(sections.STAT || "")
    if (cpu) {
      var pct = Model.cpuPercent(root.prevCpuSample, cpu)
      if (pct !== null) root.cpuPct = Math.max(0, Math.min(100, pct))
      root.prevCpuSample = cpu
    }

    var mem = Model.parseMem(sections.MEM || "")
    if (mem) {
      root.memPct = mem.usedPct
      root.memTotalBytes = mem.totalKb * 1024
      root.memUsedBytes = (mem.totalKb - mem.availKb) * 1024
    }

    var net = Model.parseNetDev(sections.NET || "")
    if (root.prevNetSample && root.prevNetSampleTime > 0) {
      var rate = Model.netRate(root.prevNetSample, net, (now - root.prevNetSampleTime) / 1000)
      if (rate) {
        root.netDownBps = rate.rxBps
        root.netUpBps = rate.txBps
        root.netReady = true
      }
    }
    root.prevNetSample = net
    root.prevNetSampleTime = now

    root.tempC = Model.parseTemp(sections.TEMP || "")

    var disk = Model.parseDisk(sections.DISK || "")
    if (disk) {
      root.diskPct = disk.usedPct
      root.diskTotalBytes = disk.totalBytes
      root.diskUsedBytes = disk.usedBytes
    }

    var parsedGpus = Model.parseNvidiaCsv(sections.NV || []).concat(Model.parseSysfsGpuSample(sections.SYSGPU || ""))
    var readings = ({})
    for (var i = 0; i < parsedGpus.length; i++) readings[parsedGpus[i].id] = parsedGpus[i]
    root.gpuReadings = readings
  }

  function persistSettings(patch) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    for (var patchKey in patch) entry[patchKey] = patch[patchKey]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function persistSetting(key, value) {
    var patch = ({})
    patch[key] = value
    root.persistSettings(patch)
  }

  function toggleSetting(key) {
    root.persistSetting(key, !root.setting(key, root.settingDefaults[key]))
  }

  // The bar layout is the source of truth. Moving asks the shell to place
  // the widget in that section, after the section's usual anchor.
  function barSection() {
    var layout = root.bar && root.bar.layoutConfig ? root.bar.layoutConfig : null
    if (!layout) return ""
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layout[sections[s]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        var id = entry && typeof entry === "object" ? entry.id : entry
        if (String(id || "") === root.moduleName) return sections[s]
      }
    }
    return ""
  }

  function moveToSection(section) {
    if (section !== "left" && section !== "center" && section !== "right") return
    if (root.barSection() === section) return
    if (!root.bar || typeof root.bar.run !== "function") return
    root.bar.run("omarchy bar move " + root.moduleName + " " + section)
  }

  function cycleSection(delta) {
    var sections = ["left", "center", "right"]
    var at = sections.indexOf(root.barSection())
    if (at < 0) at = delta >= 0 ? -1 : 0
    var step = delta >= 0 ? 1 : -1
    root.moveToSection(sections[(at + step + sections.length) % sections.length])
  }

  function trackKeyFor(metricKey) {
    if (metricKey === "gputemp") return "trackGpuTemp"
    return "track" + metricKey.charAt(0).toUpperCase() + metricKey.slice(1)
  }

  function moveMetric(key, delta) {
    var current = root.order.slice()
    var index = current.indexOf(key)
    if (index < 0) return
    var next = index + delta
    if (next < 0 || next >= current.length) return
    var swapped = current[next]
    current[next] = current[index]
    current[index] = swapped
    root.persistSetting("order", current)
  }

  function isGpuEnabled(id) {
    return Model.gpuEnabled(id, root.disabledGpuIds)
  }

  function toggleGpu(id) {
    var disabled = []
    for (var i = 0; i < root.disabledGpuIds.length; i++) disabled.push(root.disabledGpuIds[i])
    var index = disabled.indexOf(id)
    if (index === -1) disabled.push(id)
    else disabled.splice(index, 1)
    root.persistSetting("disabledGpus", disabled)
    root.rebuildSampleCommand()
    root.refresh()
  }

  function gpuReading(id) {
    if (!root.gpuReadings) return null
    var reading = root.gpuReadings[id]
    return reading === undefined ? null : reading
  }

  function setThreshold(group, which, value) {
    var max = group === "usage" ? 100 : 120
    var warn = group === "usage" ? root.usageWarn : root.tempWarn
    var crit = group === "usage" ? root.usageCrit : root.tempCrit
    if (which === "warn") warn = value
    else crit = value
    var next = Model.adjustThreshold(which, warn, crit, 0, max)
    if (group === "usage") {
      root.persistSettings({ usageWarn: next.warn, usageCrit: next.crit })
      usageWarnField.field.value = next.warn
      usageCritField.field.value = next.crit
    } else {
      root.persistSettings({ tempWarn: next.warn, tempCrit: next.crit })
      tempWarnField.field.value = next.warn
      tempCritField.field.value = next.crit
    }
  }

  function storedColor(key) {
    var fallback = key === "colorWarn" ? root.settingDefaults.colorWarn : ""
    return Model.parseColorSetting(root.setting(key, fallback))
  }

  function colorToken(key) {
    var value = root.storedColor(key)
    if (value === "foreground" || value === "accent" || value === "urgent") return value
    return ""
  }

  function chooseColorPreset(key, token) {
    root.persistSetting(key, root.colorToken(key) === token ? "" : token)
  }

  function hexFieldText(key) {
    var value = root.storedColor(key)
    return value.charAt(0) === "#" ? value : ""
  }

  function hexPlaceholder(key) {
    var value = root.storedColor(key)
    if (value === "foreground" || value === "accent" || value === "urgent") return value
    if (value.charAt(0) === "#") return ""
    if (key === "colorWarn") return "#e6b84a"
    if (key === "colorCrit") return "urgent"
    if (key === "colorValue") return "same as icon"
    return "auto"
  }

  function applyHex(key, text) {
    var trimmed = String(text || "").trim()
    if (trimmed === "") {
      root.persistSetting(key, "")
      return true
    }
    var parsed = Model.parseColorSetting(trimmed)
    if (parsed.charAt(0) !== "#") return false
    root.persistSetting(key, parsed)
    return true
  }

  function resolveColor(stored, role) {
    if (stored === "foreground") return root.foreground
    if (stored === "accent") return Commons.Color.accent
    if (stored === "urgent") return root.urgent
    if (stored.length === 7 && stored.charAt(0) === "#") return stored
    if (role === "warn") return "#e6b84a"
    if (role === "critical") return root.urgent
    return root.accentFill ? Commons.Color.accent : root.foreground
  }

  function setSettingsTab(tab) {
    if (root.settingsTabOrder.indexOf(tab) < 0 || tab === root.settingsTab) return
    root.settingsTab = tab
    root.selectedIndex = 0
    panelFlick.contentY = 0
  }

  function cycleTab(delta) {
    var at = root.settingsTabOrder.indexOf(root.settingsTab)
    if (at < 0) at = 0
    var step = delta >= 0 ? 1 : -1
    root.setSettingsTab(root.settingsTabOrder[(at + step + root.settingsTabOrder.length) % root.settingsTabOrder.length])
  }

  function totalRowCount() {
    var rows = 1
    if (root.settingsTab === "metrics") rows += root.order.length
    else if (root.settingsTab === "display") rows += root.displayOptionRows.length + 1
    else if (root.settingsTab === "gpus") rows += root.gpuCatalog.length
    else rows += 4 + root.colorCursorKeys.length
    return rows
  }

  function cursorKind(index) {
    if (index <= 0) return "tabs"
    var at = index - 1
    if (root.settingsTab === "metrics") return "metric"
    if (root.settingsTab === "display") return at < root.displayOptionRows.length ? "toggle" : "section"
    if (root.settingsTab === "gpus") return "gpu"
    return at < 4 ? "number" : "color"
  }

  function moveCursor(dx, dy) {
    if (dy !== 0) {
      var last = Math.max(0, root.totalRowCount() - 1)
      if (root.selectedIndex > last) root.selectedIndex = last
      root.selectedIndex = Math.max(0, Math.min(last, root.selectedIndex + dy))
      return
    }
    if (dx === 0) return
    var kind = root.cursorKind(root.selectedIndex)
    if (kind === "tabs") root.cycleTab(dx)
    else if (kind === "number") root.stepThreshold(root.selectedIndex, dx)
    else if (kind === "color") root.cycleColor(root.selectedIndex, dx)
    else if (kind === "section") root.cycleSection(dx)
  }

  function stepThreshold(index, delta) {
    var specs = [
      { group: "usage", which: "warn" },
      { group: "usage", which: "crit" },
      { group: "temp", which: "warn" },
      { group: "temp", which: "crit" }
    ]
    var spec = specs[index - 1]
    if (!spec) return
    var warn = spec.group === "usage" ? root.usageWarn : root.tempWarn
    var crit = spec.group === "usage" ? root.usageCrit : root.tempCrit
    var current = spec.which === "warn" ? warn : crit
    root.setThreshold(spec.group, spec.which, current + delta)
  }

  function cycleColor(index, delta) {
    var key = root.colorCursorKeys[index - 5]
    if (!key) return
    var ring = ["", "foreground", "accent", "urgent"]
    var at = ring.indexOf(root.storedColor(key))
    if (at < 0) at = 0
    var step = delta >= 0 ? 1 : -1
    root.persistSetting(key, ring[(at + step + ring.length) % ring.length])
  }

  function activateSelected() {
    var index = root.selectedIndex
    var kind = root.cursorKind(index)
    if (kind === "tabs") {
      root.cycleTab(1)
      return
    }
    if (kind === "toggle") {
      root.toggleSetting(root.displayOptionRows[index - 1].key)
      return
    }
    if (kind === "section") {
      root.cycleSection(1)
      return
    }
    if (kind === "color") {
      root.cycleColor(index, 1)
      return
    }
    if (kind === "metric") {
      var metricKey = root.order[index - 1]
      if (metricKey) root.toggleSetting(root.trackKeyFor(metricKey))
      return
    }
    if (kind === "gpu") {
      var card = root.gpuCatalog[index - 1]
      if (card) root.toggleGpu(card.gpuId)
    }
  }

  function ensureCursorVisible() {
    var target = null
    var index = root.selectedIndex
    if (index <= 0) target = tabGroup
    else if (root.settingsTab === "metrics") target = metricRepeater.itemAt(index - 1)
    else if (root.settingsTab === "display") target = index - 1 < root.displayOptionRows.length ? displayRepeater.itemAt(index - 1) : sectionWrap
    else if (root.settingsTab === "gpus") target = gpuRepeater.itemAt(index - 1)
    else if (index - 1 < 4) target = [usageWarnWrap, usageCritWrap, tempWarnWrap, tempCritWrap][index - 1]
    else target = colorRepeater.itemAt(index - 5)
    if (!target) return

    var y = 0
    var current = target
    while (current && current !== panelColumn) {
      y += current.y
      current = current.parent
    }
    var viewY = panelFlick.contentY
    var viewH = panelFlick.height
    var next = viewY
    if (y < viewY) next = y
    else if (y + target.height > viewY + viewH) next = y + target.height - viewH
    var maxY = Math.max(0, panelFlick.contentHeight - viewH)
    panelFlick.contentY = Math.max(0, Math.min(maxY, next))
  }

  function syncEditorActive() {
    var active = usageWarnField.field.activeFocus || usageCritField.field.activeFocus
      || tempWarnField.field.activeFocus || tempCritField.field.activeFocus
    for (var i = 0; i < colorRepeater.count; i++) {
      var row = colorRepeater.itemAt(i)
      if (row && row.hexFocused) active = true
    }
    root.editorActive = active
  }

  function metricLabel(key) {
    if (key === "cpu") return "CPU usage"
    if (key === "mem") return "Memory usage"
    if (key === "disk") return "Disk space"
    if (key === "temp") return "CPU temperature"
    if (key === "gpu") return "GPU usage"
    if (key === "gputemp") return "GPU temperature"
    if (key === "net") return "Network speed"
    return key
  }

  function metricTracked(key) {
    if (key === "cpu") return root.trackCpu
    if (key === "mem") return root.trackMem
    if (key === "disk") return root.trackDisk
    if (key === "temp") return root.trackTemp
    if (key === "gpu") return root.trackGpu
    if (key === "gputemp") return root.trackGpuTemp
    if (key === "net") return root.trackNet
    return false
  }

  // A hidden card is omitted. With no card at all, the GPU metrics stay
  // visible and read n/a so a missing sensor is not silent.
  function metricRowVisible(key) {
    if (!root.metricTracked(key)) return false
    if (key !== "gpu" && key !== "gputemp") return true
    if (root.gpuCatalog.length === 0) return true
    return root.enabledGpuCount > 0
  }

  function metricGlyph(key) {
    if (key === "cpu") return "\uF2DB"
    if (key === "mem") return "\uE266"
    if (key === "disk") return "\uF1C0"
    if (key === "temp") return "\uF2C7"
    if (key === "gpu") return "\uF08AE"
    if (key === "gputemp") return "\uF050F"
    if (key === "net") return "\uF06F3"
    return ""
  }

  function metricNumber(key, gpuId) {
    if (key === "cpu") return root.cpuPct >= 0 ? root.cpuPct : null
    if (key === "mem") return root.memPct >= 0 ? root.memPct : null
    if (key === "disk") return root.diskPct >= 0 ? root.diskPct : null
    if (key === "temp") return root.tempC
    var reading = gpuId ? root.gpuReading(gpuId) : null
    if (key === "gpu") return reading ? reading.utilPct : null
    if (key === "gputemp") return reading ? reading.tempC : null
    return null
  }

  function metricFraction(key, gpuId) {
    if (key === "cpu") return root.cpuPct / 100
    if (key === "mem") return root.memPct / 100
    if (key === "disk") return root.diskPct / 100
    if (key === "temp") return root.tempC !== null ? (root.tempC - root.tempFloor) / (root.tempCeiling - root.tempFloor) : 0
    if (key === "gpu") {
      var util = root.metricNumber(key, gpuId)
      return util === null ? 0 : util / 100
    }
    if (key === "gputemp") {
      var temp = root.metricNumber(key, gpuId)
      return temp === null ? 0 : (temp - root.tempFloor) / (root.tempCeiling - root.tempFloor)
    }
    return 0
  }

  function legacyUrgent(key, value) {
    if (value === null || value === undefined || isNaN(Number(value))) return false
    if (key === "temp" || key === "gputemp") return Number(value) >= 85
    if (key === "net") return false
    return Number(value) >= 90
  }

  function metricFillColor(key, gpuId) {
    var value = root.metricNumber(key, gpuId)
    if (!root.thresholdsEnabled) {
      if (root.legacyUrgent(key, value)) return root.urgent
      return root.accentFill ? Commons.Color.accent : root.foreground
    }
    var pair = (key === "temp" || key === "gputemp") ? root.tempThresholds : root.usageThresholds
    var band = Model.colorBand(value, pair.warn, pair.crit)
    if (band === "critical") return root.resolveColor(root.storedColor("colorCrit"), "critical")
    if (band === "warn") return root.resolveColor(root.storedColor("colorWarn"), "warn")
    return root.resolveColor(root.storedColor("colorNormal"), "normal")
  }

  function metricValueColor(key, gpuId) {
    var override = root.storedColor("colorValue")
    if (override !== "") return root.resolveColor(override, "value")
    if (!root.thresholdsEnabled || key === "net") return root.foreground
    return root.metricFillColor(key, gpuId)
  }

  function tempText() {
    if (root.tempC !== null) return Math.round(root.tempC) + "°C"
    return root.tempSensorResolved ? "n/a" : "…"
  }

  function metricValueText(key) {
    if (key === "cpu") return root.cpuPct >= 0 ? (root.cpuPct + "%") : "…"
    if (key === "mem") {
      if (root.memPct < 0) return "…"
      return root.memoryAsAmount ? Model.formatBytes(root.memUsedBytes) : (root.memPct + "%")
    }
    if (key === "disk") return root.diskPct >= 0 ? (root.diskPct + "%") : "…"
    if (key === "temp") return root.tempText()
    return ""
  }

  function gpuNumberText(key, gpuId) {
    var reading = root.gpuReading(gpuId)
    if (!reading) return "…"
    if (key === "gpu") return reading.utilPct === null || isNaN(reading.utilPct) ? "n/a" : Math.round(reading.utilPct) + "%"
    if (reading.tempC === null || isNaN(reading.tempC)) return "n/a"
    return Math.round(reading.tempC) + "°C"
  }

  function gpuMemText(gpuId) {
    var reading = root.gpuReading(gpuId)
    if (!reading || reading.memTotalBytes === null || !(reading.memTotalBytes > 0)) return ""
    return Model.formatBytes(reading.memUsedBytes || 0) + " / " + Model.formatBytes(reading.memTotalBytes)
  }

  function gpuBusLabel(id) {
    var raw = String(id || "").replace(/^(nv|drm):/, "")
    var parts = raw.split(":")
    if (parts.length >= 3) return parts.slice(parts.length - 2).join(":")
    return raw
  }

  function gpuGroupSummary(key) {
    if (!root.gpuDiscoveryDone && root.gpuCatalog.length === 0) return "Looking for GPUs…"
    if (root.gpuCatalog.length === 0) return "No GPU found"
    var parts = []
    for (var i = 0; i < root.gpuCatalog.length; i++) {
      var card = root.gpuCatalog[i]
      if (!root.isGpuEnabled(card.gpuId)) continue
      var label = root.enabledGpuCount > 1 ? Model.shortGpuName(card.name) + " " : ""
      var value = root.gpuNumberText(key, card.gpuId)
      if (key === "gpu") {
        var mem = root.gpuMemText(card.gpuId)
        parts.push(label + value + (mem ? " (" + mem + ")" : ""))
      } else {
        parts.push(label + value)
      }
    }
    if (parts.length === 0) return "All cards hidden"
    return "Currently " + parts.join(", ")
  }

  function metricSummary(key) {
    if (key === "cpu") return root.cpuPct >= 0 ? ("Currently " + root.cpuPct + "%") : "Reading…"
    if (key === "mem") return root.memPct >= 0
      ? ("Currently " + root.memPct + "% (" + Model.formatBytes(root.memUsedBytes) + " / " + Model.formatBytes(root.memTotalBytes) + ")")
      : "Reading…"
    if (key === "disk") return root.diskPct >= 0
      ? ("Currently " + root.diskPct + "% (" + Model.formatBytes(root.diskUsedBytes) + " / " + Model.formatBytes(root.diskTotalBytes) + ")")
      : "Reading…"
    if (key === "temp") return "Currently " + root.tempText()
    if (key === "gpu" || key === "gputemp") return root.gpuGroupSummary(key)
    if (key === "net") return root.netReady
      ? ("Currently ↓" + Model.formatRate(root.netDownBps) + "  ↑" + Model.formatRate(root.netUpBps))
      : "Reading…"
    return ""
  }

  // The bar tooltip centers every line. This list feeds our own popup so the
  // readings stay left-aligned and only the last line is centered.
  readonly property var tooltipLines: {
    var lines = []
    for (var i = 0; i < root.order.length; i++) {
      var key = root.order[i]
      if (!root.metricRowVisible(key)) continue
      lines.push({
        glyph: root.metricGlyph(key),
        text: root.metricLabel(key) + ": " + root.metricSummary(key).replace("Currently ", "")
      })
    }
    return lines
  }

  Component.onCompleted: {
    root.applySampleCommand()
    tempDiscoveryProc.running = true
    gpuDiscoveryProc.running = true
    root.refresh()
  }

  onOpenedChanged: {
    if (root.opened) {
      root.settingsTab = "metrics"
      hoverTip.shown = false
      root.cursorActive = false
      root.selectedIndex = 0
      panelFlick.contentY = 0
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      if (!gpuDiscoveryProc.running) gpuDiscoveryProc.running = true
    }
    root.rebuildSampleCommand()
    root.refresh()
  }

  onSelectedIndexChanged: if (root.cursorActive && root.opened) Qt.callLater(root.ensureCursorVisible)

  Process {
    id: tempDiscoveryProc
    command: ["bash", "-c",
      "for d in /sys/class/hwmon/hwmon*; do n=$(cat \"$d/name\" 2>/dev/null); " +
      "case \"$n\" in coretemp|k10temp|zenpower) echo \"$d/temp1_input\"; break;; esac; done"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.tempSensorPath = String(text || "").trim()
        root.tempSensorResolved = true
        root.rebuildSampleCommand()
        root.refresh()
      }
    }
  }

  Process {
    id: gpuDiscoveryProc
    command: ["bash", "-c", Model.discoveryScript()]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsedCards = Model.parseGpuCatalog(text)
        var cards = []
        for (var i = 0; i < parsedCards.length; i++) {
          var card = parsedCards[i]
          cards.push({
            gpuId: card.id,
            name: card.name,
            source: card.source,
            busyPath: card.busyPath || "",
            tempPath: card.tempPath || "",
            memUsedPath: card.memUsedPath || "",
            memTotalPath: card.memTotalPath || ""
          })
        }
        root.gpuCatalog = cards
        root.gpuDiscoveryDone = true
        root.rebuildSampleCommand()
        root.refresh()
      }
    }
  }

  Process {
    id: sampleProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishSample(text)
    }
  }

  Timer {
    interval: Number(root.setting("intervalMs", 2000))
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: "crome.vitals"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  TextMetrics { id: pctWidthMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.caption; text: "100%" }
  TextMetrics { id: memWidthMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.caption; text: "999TB" }
  TextMetrics { id: tempWidthMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.caption; text: "999°C" }
  TextMetrics { id: netWidthMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.caption; text: "999.9MB/s" }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: Math.max(12, contentRow.implicitWidth + scaledHorizontalMargin * 2)
    tooltipText: ""

    HoverHandler {
      id: tipHover
      onHoveredChanged: {
        if (hovered && !root.opened) tipDelay.restart()
        else {
          tipDelay.stop()
          hoverTip.shown = false
        }
      }
    }

    Timer {
      id: tipDelay
      interval: 400
      onTriggered: if (tipHover.hovered && !root.opened) hoverTip.shown = true
    }

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (!gpuDiscoveryProc.running) gpuDiscoveryProc.running = true
        root.refresh()
      } else root.toggle()
    }

    Row {
      id: contentRow
      anchors.centerIn: parent
      spacing: Style.space(10)

      Repeater {
        model: root.order

        Row {
          id: metricSlot
          required property string modelData
          visible: root.metricRowVisible(modelData)
          spacing: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter

          Repeater {
            model: metricSlot.modelData === "gpu" || metricSlot.modelData === "gputemp" ? root.gpuCatalog : 0

            Row {
              id: gpuSlot
              required property var modelData
              visible: root.isGpuEnabled(modelData.gpuId)
              spacing: Style.space(3)
              anchors.verticalCenter: parent.verticalCenter

              FillIcon {
                anchors.verticalCenter: parent.verticalCenter
                glyph: root.metricGlyph(metricSlot.modelData)
                fraction: root.metricFraction(metricSlot.modelData, gpuSlot.modelData.gpuId)
                pixelSize: Style.font.body
                fontFamily: root.fontFamily
                fillColor: root.metricFillColor(metricSlot.modelData, gpuSlot.modelData.gpuId)
              }
              Text {
                visible: root.enabledGpuCount > 1
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: Model.shortGpuName(gpuSlot.modelData.name)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                visible: metricSlot.modelData === "gputemp" || root.showPercent
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.gpuNumberText(metricSlot.modelData, gpuSlot.modelData.gpuId)
                width: metricSlot.modelData === "gputemp" ? tempWidthMetrics.width : pctWidthMetrics.width
                horizontalAlignment: Text.AlignLeft
                color: root.metricValueColor(metricSlot.modelData, gpuSlot.modelData.gpuId)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            visible: (metricSlot.modelData === "gpu" || metricSlot.modelData === "gputemp") && root.gpuCatalog.length === 0
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.gpuDiscoveryDone ? "n/a" : "…"
            color: root.metricValueColor(metricSlot.modelData, "")
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            visible: metricSlot.modelData !== "gpu" && metricSlot.modelData !== "gputemp" && metricSlot.modelData !== "net"
            spacing: Style.space(3)
            anchors.verticalCenter: parent.verticalCenter

            FillIcon {
              anchors.verticalCenter: parent.verticalCenter
              glyph: root.metricGlyph(metricSlot.modelData)
              fraction: root.metricFraction(metricSlot.modelData, "")
              pixelSize: Style.font.body
              fontFamily: root.fontFamily
              fillColor: root.metricFillColor(metricSlot.modelData, "")
            }
            Text {
              visible: metricSlot.modelData === "temp"
                || (metricSlot.modelData === "mem" && root.memoryAsAmount)
                || root.showPercent
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: root.metricValueText(metricSlot.modelData)
              width: metricSlot.modelData === "temp" ? tempWidthMetrics.width
                : (metricSlot.modelData === "mem" && root.memoryAsAmount) ? memWidthMetrics.width
                : pctWidthMetrics.width
              horizontalAlignment: Text.AlignLeft
              color: root.metricValueColor(metricSlot.modelData, "")
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            visible: metricSlot.modelData === "net"
            spacing: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter

            Row {
              spacing: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              Text {
                text: "↓"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                text: root.netReady ? Model.formatRate(root.netDownBps) : "…"
                width: netWidthMetrics.width
                horizontalAlignment: Text.AlignLeft
                color: root.metricValueColor("net", "")
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
            Row {
              spacing: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              Text {
                text: "↑"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                text: root.netReady ? Model.formatRate(root.netUpBps) : "…"
                width: netWidthMetrics.width
                horizontalAlignment: Text.AlignLeft
                color: root.metricValueColor("net", "")
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      Text {
        visible: !root.anyTracked
        text: "\uF2DB"
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  PopupWindow {
    id: hoverTip
    property bool shown: false
    visible: shown && !root.opened
    color: "transparent"
    implicitWidth: Math.ceil(tipBubble.implicitWidth)
    implicitHeight: Math.ceil(tipBubble.implicitHeight)

    anchor {
      window: button.QsWindow ? button.QsWindow.window : null
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.x: 0
      rect.y: 0
      rect.width: 1
      rect.height: 1

      onAnchoring: {
        if (!button.QsWindow || !button.QsWindow.window) return
        var popupWidth = hoverTip.implicitWidth
        var popupHeight = hoverTip.implicitHeight
        var localX = button.width / 2 - popupWidth / 2
        var localY = button.height + 6
        var pos = root.bar ? root.bar.position : "top"
        if (pos === "bottom") localY = -popupHeight - 6
        else if (pos === "left") {
          localX = button.width + 6
          localY = button.height / 2 - popupHeight / 2
        } else if (pos === "right") {
          localX = -popupWidth - 6
          localY = button.height / 2 - popupHeight / 2
        }
        var point = button.QsWindow.window.contentItem.mapFromItem(button, localX, localY)
        hoverTip.anchor.rect.x = Math.round(point.x)
        hoverTip.anchor.rect.y = Math.round(point.y)
      }
    }

    BorderSurface {
      id: tipBubble
      implicitWidth: tipBody.implicitWidth + Style.space(20)
      implicitHeight: tipBody.implicitHeight + Style.space(14)
      color: Commons.Color.tooltip.background
      borderSpec: Border.surfaceSpec("tooltip", "border", Commons.Color.tooltip.border, 1)
      radius: Style.cornerRadius

      Item {
        id: tipBody
        anchors.centerIn: parent
        implicitWidth: Math.max(linesCol.implicitWidth, clickHint.implicitWidth)
        implicitHeight: linesCol.implicitHeight + (root.tooltipLines.length > 0 ? Style.space(6) : 0) + clickHint.implicitHeight

        Column {
          id: linesCol
          spacing: Style.space(2)

          Repeater {
            model: root.tooltipLines

            Row {
              required property var modelData
              spacing: Style.space(8)

              Text {
                visible: modelData.glyph !== ""
                textFormat: Text.PlainText
                text: modelData.glyph
                color: Commons.Color.tooltip.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
                text: modelData.text
                color: Commons.Color.tooltip.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignLeft
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }

        Text {
          id: clickHint
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: linesCol.bottom
          anchors.topMargin: root.tooltipLines.length > 0 ? Style.space(6) : 0
          textFormat: Text.PlainText
          text: "Click for settings"
          color: Commons.Color.tooltip.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editorActive
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: panelColumn
          width: panelFlick.width
          spacing: Style.space(14)

          PanelHero {
            width: parent.width
            title: "Vitals"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "\uF2DB"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          ButtonGroup {
            id: tabGroup
            focusable: false
            options: [
              { value: "metrics", label: "Metrics" },
              { value: "display", label: "Display" },
              { value: "gpus", label: "GPUs" },
              { value: "thresholds", label: "Thresholds" }
            ]
            value: root.settingsTab
            foreground: root.foreground
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            cursorIndex: (root.cursorActive && root.selectedIndex === 0)
              ? tabGroup.selectedOptionIndex() : -1
            onChanged: function(next) { root.setSettingsTab(next) }
            onHovered: function(index, on) {
              if (on) {
                root.cursorActive = true
                root.selectedIndex = 0
              }
            }
          }

          Column {
            visible: root.settingsTab === "display"
            width: parent.width
            spacing: Style.space(10)

            Column {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                id: displayRepeater
                model: root.displayOptionRows

                Toggle {
                  required property var modelData
                  required property int index
                  width: parent.width
                  label: modelData.label
                  description: modelData.description
                  foreground: root.foreground
                  accent: Commons.Color.accent
                  fontFamily: root.fontFamily
                  checked: root.setting(modelData.key, root.settingDefaults[modelData.key])
                  hasCursor: root.cursorActive && root.settingsTab === "display" && root.selectedIndex === index + 1
                  onClicked: root.toggleSetting(modelData.key)
                  onHovered: function(on) { if (on) { root.cursorActive = true; root.selectedIndex = index + 1 } }
                }
              }

              Column {
                id: sectionWrap
                width: parent.width
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Bar position"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: "Move this widget to the left, center, or right of the bar."
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                ButtonGroup {
                  id: sectionGroup
                  focusable: false
                  options: [
                    { value: "left", label: "Left" },
                    { value: "center", label: "Center" },
                    { value: "right", label: "Right" }
                  ]
                  value: root.barSection()
                  foreground: root.foreground
                  accent: Commons.Color.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  cursorIndex: (root.cursorActive && root.settingsTab === "display" && root.selectedIndex === root.displayOptionRows.length + 1)
                    ? sectionGroup.selectedOptionIndex() : -1
                  onChanged: function(next) { root.moveToSection(next) }
                  onHovered: function(index, on) {
                    if (on) {
                      root.cursorActive = true
                      root.selectedIndex = root.displayOptionRows.length + 1
                    }
                  }
                }
              }
            }
          }

          Column {
            visible: root.settingsTab === "thresholds"
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Usage covers CPU, memory, disk, and GPU percent, including when memory is shown as a size. Temperature covers CPU and GPU. Left and right change the selected number or color. Value color changes the numbers only."
              color: Qt.darker(root.foreground, 1.35)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item {
              id: usageWarnWrap
              width: parent.width
              height: usageWarnField.implicitHeight
              NumberField {
                id: usageWarnField
                width: parent.width
                label: "Usage warning (%)"
                from: 0
                to: 99
                value: root.usageWarn
                foreground: root.foreground
                accent: Commons.Color.accent
                fontFamily: root.fontFamily
                hasCursor: root.cursorActive && root.settingsTab === "thresholds" && root.selectedIndex === 1
                onModified: function(value) { root.setThreshold("usage", "warn", value) }
                onHovered: function(on) { if (on) { root.cursorActive = true; root.selectedIndex = 1 } }
              }
              Connections {
                target: usageWarnField.field
                function onActiveFocusChanged() { root.syncEditorActive() }
              }
            }
            Item {
              id: usageCritWrap
              width: parent.width
              height: usageCritField.implicitHeight
              NumberField {
                id: usageCritField
                width: parent.width
                label: "Usage critical (%)"
                from: 1
                to: 100
                value: root.usageCrit
                foreground: root.foreground
                accent: Commons.Color.accent
                fontFamily: root.fontFamily
                hasCursor: root.cursorActive && root.settingsTab === "thresholds" && root.selectedIndex === 2
                onModified: function(value) { root.setThreshold("usage", "crit", value) }
                onHovered: function(on) { if (on) { root.cursorActive = true; root.selectedIndex = 2 } }
              }
              Connections {
                target: usageCritField.field
                function onActiveFocusChanged() { root.syncEditorActive() }
              }
            }
            Item {
              id: tempWarnWrap
              width: parent.width
              height: tempWarnField.implicitHeight
              NumberField {
                id: tempWarnField
                width: parent.width
                label: "Temperature warning (°C)"
                from: 0
                to: 119
                value: root.tempWarn
                foreground: root.foreground
                accent: Commons.Color.accent
                fontFamily: root.fontFamily
                hasCursor: root.cursorActive && root.settingsTab === "thresholds" && root.selectedIndex === 3
                onModified: function(value) { root.setThreshold("temp", "warn", value) }
                onHovered: function(on) { if (on) { root.cursorActive = true; root.selectedIndex = 3 } }
              }
              Connections {
                target: tempWarnField.field
                function onActiveFocusChanged() { root.syncEditorActive() }
              }
            }
            Item {
              id: tempCritWrap
              width: parent.width
              height: tempCritField.implicitHeight
              NumberField {
                id: tempCritField
                width: parent.width
                label: "Temperature critical (°C)"
                from: 1
                to: 120
                value: root.tempCrit
                foreground: root.foreground
                accent: Commons.Color.accent
                fontFamily: root.fontFamily
                hasCursor: root.cursorActive && root.settingsTab === "thresholds" && root.selectedIndex === 4
                onModified: function(value) { root.setThreshold("temp", "crit", value) }
                onHovered: function(on) { if (on) { root.cursorActive = true; root.selectedIndex = 4 } }
              }
              Connections {
                target: tempCritField.field
                function onActiveFocusChanged() { root.syncEditorActive() }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                id: colorRepeater
                model: root.colorChoices

                Column {
                  id: colorRow
                  required property var modelData
                  required property int index
                  property bool hexFocused: false
                  width: parent.width
                  spacing: Style.space(4)

                  Text {
                    textFormat: Text.PlainText
                    text: colorRow.modelData.label
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    visible: colorRow.modelData.description !== ""
                    width: parent.width
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                    text: colorRow.modelData.description
                    color: Qt.darker(root.foreground, 1.35)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Row {
                    spacing: Style.space(6)
                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(14)
                      height: Style.space(14)
                      radius: Style.space(3)
                      color: colorRow.modelData.key === "colorValue" && root.storedColor(colorRow.modelData.key) === ""
                        ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
                        : root.resolveColor(root.storedColor(colorRow.modelData.key), colorRow.modelData.colorRole)
                      border.width: 1
                      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
                    }
                    Button {
                      text: "Foreground"
                      bordered: true
                      selected: root.colorToken(colorRow.modelData.key) === "foreground"
                      foreground: root.foreground
                      accent: Commons.Color.accent
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      horizontalPadding: Style.space(8)
                      verticalPadding: Style.space(4)
                      hasCursor: root.cursorActive && root.settingsTab === "thresholds" && root.selectedIndex === 5 + colorRow.index
                      onClicked: root.chooseColorPreset(colorRow.modelData.key, "foreground")
                      onHovered: function(on) { if (on) { root.cursorActive = true; root.selectedIndex = 5 + colorRow.index } }
                    }
                    Button {
                      text: "Accent"
                      bordered: true
                      selected: root.colorToken(colorRow.modelData.key) === "accent"
                      foreground: root.foreground
                      accent: Commons.Color.accent
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      horizontalPadding: Style.space(8)
                      verticalPadding: Style.space(4)
                      hasCursor: root.cursorActive && root.settingsTab === "thresholds" && root.selectedIndex === 5 + colorRow.index
                      onClicked: root.chooseColorPreset(colorRow.modelData.key, "accent")
                      onHovered: function(on) { if (on) { root.cursorActive = true; root.selectedIndex = 5 + colorRow.index } }
                    }
                    Button {
                      text: "Urgent"
                      bordered: true
                      selected: root.colorToken(colorRow.modelData.key) === "urgent"
                      foreground: root.foreground
                      accent: Commons.Color.accent
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      horizontalPadding: Style.space(8)
                      verticalPadding: Style.space(4)
                      hasCursor: root.cursorActive && root.settingsTab === "thresholds" && root.selectedIndex === 5 + colorRow.index
                      onClicked: root.chooseColorPreset(colorRow.modelData.key, "urgent")
                      onHovered: function(on) { if (on) { root.cursorActive = true; root.selectedIndex = 5 + colorRow.index } }
                    }
                  }

                  TextField {
                    id: hexField
                    width: parent.width
                    placeholderText: root.hexPlaceholder(colorRow.modelData.key)
                    foreground: root.foreground
                    accent: Commons.Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    hasCursor: root.cursorActive && root.settingsTab === "thresholds" && root.selectedIndex === 5 + colorRow.index
                    Component.onCompleted: text = root.hexFieldText(colorRow.modelData.key)
                    onActiveFocusChanged: {
                      colorRow.hexFocused = activeFocus
                      root.syncEditorActive()
                    }
                    onEditingFinished: {
                      if (!root.applyHex(colorRow.modelData.key, text)) text = root.hexFieldText(colorRow.modelData.key)
                    }
                    onAccepted: {
                      if (!root.applyHex(colorRow.modelData.key, text)) text = root.hexFieldText(colorRow.modelData.key)
                    }
                  }
                  Connections {
                    target: root
                    function onSettingsChanged() {
                      if (!hexField.activeFocus) hexField.text = root.hexFieldText(colorRow.modelData.key)
                    }
                  }
                }
              }
            }
          }

          Column {
            visible: root.settingsTab === "metrics"
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Turn a metric off to hide it. The arrows change its order on the bar."
              color: Qt.darker(root.foreground, 1.35)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                id: metricRepeater
                model: root.order

                RowLayout {
                  id: metricRow
                  required property string modelData
                  required property int index
                  width: parent.width
                  spacing: Style.space(6)

                  ColumnLayout {
                    spacing: Style.space(2)
                    PanelActionButton {
                      iconText: "▲"
                      tooltipText: "Move up"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      size: Style.space(18)
                      fontSize: Style.font.caption
                      enabled: metricRow.index > 0
                      onClicked: root.moveMetric(metricRow.modelData, -1)
                    }
                    PanelActionButton {
                      iconText: "▼"
                      tooltipText: "Move down"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      size: Style.space(18)
                      fontSize: Style.font.caption
                      enabled: metricRow.index < root.order.length - 1
                      onClicked: root.moveMetric(metricRow.modelData, 1)
                    }
                  }

                  Toggle {
                    Layout.fillWidth: true
                    label: root.metricLabel(metricRow.modelData)
                    description: root.metricSummary(metricRow.modelData)
                    foreground: root.foreground
                    accent: Commons.Color.accent
                    fontFamily: root.fontFamily
                    checked: root.metricTracked(metricRow.modelData)
                    hasCursor: root.cursorActive && root.settingsTab === "metrics" && root.selectedIndex === metricRow.index + 1
                    onClicked: root.toggleSetting(root.trackKeyFor(metricRow.modelData))
                    onHovered: function(on) {
                      if (on) { root.cursorActive = true; root.selectedIndex = metricRow.index + 1 }
                    }
                  }
                }
              }
            }
          }

          Column {
            visible: root.settingsTab === "gpus"
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.gpuCatalog.length === 0
                ? (root.gpuDiscoveryDone ? "No GPU found." : "Looking for GPUs…")
                : "Turn a card off to hide it. A card found later is shown until you turn it off. With more than one card on, each one is labeled. A GPU that Linux has not enumerated, such as an integrated GPU switched off in firmware, is not listed."
              color: Qt.darker(root.foreground, 1.35)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                id: gpuRepeater
                model: root.gpuCatalog

                Toggle {
                  id: gpuToggle
                  required property var modelData
                  required property int index
                  width: parent.width
                  label: modelData.name
                  description: root.gpuBusLabel(modelData.gpuId) + " · " + root.gpuNumberText("gpu", modelData.gpuId) + " · " + root.gpuNumberText("gputemp", modelData.gpuId) + (root.gpuMemText(modelData.gpuId) ? " · " + root.gpuMemText(modelData.gpuId) : "")
                  foreground: root.foreground
                  accent: Commons.Color.accent
                  fontFamily: root.fontFamily
                  checked: root.isGpuEnabled(modelData.gpuId)
                  hasCursor: root.cursorActive && root.settingsTab === "gpus" && root.selectedIndex === index + 1
                  onClicked: root.toggleGpu(modelData.gpuId)
                  onHovered: function(on) {
                    if (on) { root.cursorActive = true; root.selectedIndex = index + 1 }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  component FillIcon: Item {
    id: fillRoot
    property string glyph: ""
    property real fraction: 0
    property color fillColor: Commons.Color.foreground
    property color emptyColor: fillColor
    property real emptyOpacity: 0.28
    property real pixelSize: Style.font.body
    property string fontFamily: Style.font.family

    implicitWidth: emptyGlyph.implicitWidth
    implicitHeight: emptyGlyph.implicitHeight

    TextMetrics {
      id: ink
      font.family: fillRoot.fontFamily
      font.pixelSize: fillRoot.pixelSize
      text: fillRoot.glyph
    }

    readonly property real inkTop: emptyGlyph.baselineOffset + ink.tightBoundingRect.y
    readonly property real inkHeight: Math.max(1, ink.tightBoundingRect.height)
    readonly property real inkBottom: inkTop + inkHeight

    Text {
      id: emptyGlyph
      textFormat: Text.PlainText
      text: fillRoot.glyph
      color: fillRoot.emptyColor
      opacity: fillRoot.emptyOpacity
      font.family: fillRoot.fontFamily
      font.pixelSize: fillRoot.pixelSize
      renderType: Text.NativeRendering
    }

    Item {
      id: clipMask
      x: 0
      width: fillRoot.width
      clip: true
      y: fillRoot.inkBottom - fillRoot.inkHeight * Math.max(0, Math.min(1, fillRoot.fraction))
      height: fillRoot.inkBottom - y

      Text {
        x: 0
        y: -clipMask.y
        width: emptyGlyph.width
        textFormat: Text.PlainText
        text: fillRoot.glyph
        color: fillRoot.fillColor
        font.family: fillRoot.fontFamily
        font.pixelSize: fillRoot.pixelSize
        renderType: Text.NativeRendering
      }
    }
  }
}
