// Parsing and threshold math for the Vitals widget. Kept out of the QML
// file so the sampling rules can be tested on their own.
//
// CPU, memory, disk, temperature, and network parsing follows
// omarchy-bar-resources (Kenny De Mits, MIT). GPU discovery, the enabled-GPU
// filter, and color thresholds are added here.

// The aggregate "cpu  ..." line from /proc/stat, never a per-core "cpu0" line
// (those have no space before the digits, so the regex below skips them).
function parseCpuLine(text) {
  var m = /^cpu\s+([\d\s]+)$/m.exec(String(text || ""))
  if (!m) return null

  var parts = m[1].trim().split(/\s+/).map(Number)
  var user = parts[0] || 0, nice = parts[1] || 0, system = parts[2] || 0, idle = parts[3] || 0
  var iowait = parts[4] || 0, irq = parts[5] || 0, softirq = parts[6] || 0, steal = parts[7] || 0

  return {
    idleAll: idle + iowait,
    total: user + nice + system + idle + iowait + irq + softirq + steal
  }
}

// Percent busy between two /proc/stat samples. Null until a second sample
// exists, since a single reading has no delta to measure usage from.
function cpuPercent(prev, curr) {
  if (!prev || !curr) return null
  var totalDelta = curr.total - prev.total
  var idleDelta = curr.idleAll - prev.idleAll
  if (totalDelta <= 0) return null
  return Math.round(100 * (1 - idleDelta / totalDelta))
}

// MemAvailable (not MemFree) is the kernel's own estimate of what's usable
// without swapping, so it already accounts for reclaimable cache/buffers.
function parseMem(text) {
  var raw = String(text || "")
  var totalM = /^MemTotal:\s+(\d+)/m.exec(raw)
  var availM = /^MemAvailable:\s+(\d+)/m.exec(raw)
  if (!totalM || !availM) return null

  var totalKb = parseInt(totalM[1], 10)
  var availKb = parseInt(availM[1], 10)
  return {
    totalKb: totalKb,
    availKb: availKb,
    usedPct: totalKb > 0 ? Math.round(100 * (1 - availKb / totalKb)) : 0
  }
}

// Sum of rx/tx bytes across every interface except loopback, from
// /proc/net/dev. Format is "iface: rxBytes rxPackets ... (8 recv fields)
// txBytes txPackets ...", so the tx byte count is the first field after
// the 8 receive columns.
function parseNetDev(text) {
  var raw = String(text || "")
  var re = /^\s*([^:\s]+):\s*(\d+)(?:\s+\d+){7}\s+(\d+)/gm
  var rxBytes = 0, txBytes = 0
  var m
  while ((m = re.exec(raw)) !== null) {
    if (m[1] === "lo") continue
    rxBytes += parseInt(m[2], 10)
    txBytes += parseInt(m[3], 10)
  }
  return { rxBytes: rxBytes, txBytes: txBytes }
}

// Bytes/sec between two /proc/net/dev samples. Null until a second sample
// exists, or if a counter went backwards (an interface reset/reappeared).
function netRate(prev, curr, dtSeconds) {
  if (!prev || !curr || !(dtSeconds > 0)) return null
  var rxDelta = curr.rxBytes - prev.rxBytes
  var txDelta = curr.txBytes - prev.txBytes
  if (rxDelta < 0 || txDelta < 0) return null
  return { rxBps: rxDelta / dtSeconds, txBps: txDelta / dtSeconds }
}

// Compact human-readable byte count, e.g. "340KB", "1.2GB".
function formatBytes(bytes) {
  var v = Math.max(0, Number(bytes) || 0)
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024
    i++
  }
  var decimals = v < 10 && i > 0 ? 1 : 0
  return v.toFixed(decimals) + units[i]
}

function formatRate(bytesPerSec) {
  return formatBytes(bytesPerSec) + "/s"
}

// temp1_input-style sysfs content: a bare integer in millidegrees C, or
// empty when no thermal sensor was found for this hardware.
function parseTemp(text) {
  var raw = String(text || "").trim()
  if (raw === "") return null
  var v = parseFloat(raw)
  return isNaN(v) ? null : v / 1000
}

// Last line of `df -B1 --output=size,used,avail,pcent /`.
function parseDisk(text) {
  var lines = String(text || "").trim().split("\n")
  if (lines.length === 0) return null
  var cols = lines[lines.length - 1].trim().split(/\s+/)
  if (cols.length < 4) return null

  var totalBytes = parseInt(cols[0], 10)
  var usedBytes = parseInt(cols[1], 10)
  var availBytes = parseInt(cols[2], 10)
  var usedPct = parseInt(cols[3], 10) // parseInt stops at the trailing "%"
  if (isNaN(totalBytes) || isNaN(usedPct)) return null

  return { totalBytes: totalBytes, usedBytes: usedBytes, availBytes: availBytes, usedPct: usedPct }
}

// Splits one combined sample into named sections. The sampling command
// prints "===NAME===" markers between each metric's raw output so one
// process spawn can gather everything in a single read.
function splitSections(text) {
  var parts = String(text || "").split(/===([A-Z]+)===\r?\n?/)
  var sections = {}
  for (var i = 1; i < parts.length; i += 2) sections[parts[i]] = parts[i + 1] || ""
  return sections
}

function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

// nvidia-smi numbers are either a bare value or a bracketed "not available".
function parseLooseNumber(text) {
  var raw = String(text === undefined || text === null ? "" : text).trim()
  if (raw === "" || raw === "[N/A]" || raw === "[Not Supported]" || raw.toLowerCase() === "n/a") return null
  var v = parseFloat(raw)
  return isNaN(v) ? null : v
}

// One nvidia-smi CSV line per GPU:
// pci.bus_id, utilization.gpu, temperature.gpu, memory.used, memory.total, name
// Name is last so a comma inside it stays part of the name. Memory is MiB.
// The id matches the catalog id from pci.bus_id ("nv:" + lowercase bus id).
function parseNvidiaCsv(text) {
  var lines = String(text || "").split(/\r?\n/)
  var gpus = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    var parts = line.split(",")
    if (parts.length < 6) continue
    var pci = parts[0].trim()
    if (pci === "") continue
    var memUsed = parseLooseNumber(parts[3])
    var memTotal = parseLooseNumber(parts[4])
    gpus.push({
      id: "nv:" + pci.toLowerCase(),
      name: parts.slice(5).join(",").trim() || pci,
      utilPct: parseLooseNumber(parts[1]),
      tempC: parseLooseNumber(parts[2]),
      memUsedBytes: memUsed === null ? null : memUsed * 1024 * 1024,
      memTotalBytes: memTotal === null ? null : memTotal * 1024 * 1024
    })
  }
  return gpus
}

// Discovery output. NVIDIA lines come first, then a ===SYS=== marker and one
// tab-separated DRM card per line:
// pci, name, busyPath, tempPath, memUsedPath, memTotalPath
function parseGpuCatalog(text) {
  var parts = String(text || "").split(/===SYS===\r?\n?/)
  var nvText = parts[0] || ""
  var sysText = parts[1] || ""
  var gpus = []
  var seen = {}

  var nvLines = nvText.split(/\r?\n/)
  for (var i = 0; i < nvLines.length; i++) {
    var line = nvLines[i].trim()
    if (line === "") continue
    var comma = line.indexOf(",")
    if (comma < 0) continue
    var pci = line.slice(0, comma).trim()
    var name = line.slice(comma + 1).trim()
    if (pci === "") continue
    var id = "nv:" + pci.toLowerCase()
    if (seen[id]) continue
    seen[id] = true
    gpus.push({ id: id, name: name || pci, source: "nv", pci: pci })
  }

  var sysLines = sysText.split(/\r?\n/)
  for (var j = 0; j < sysLines.length; j++) {
    var row = sysLines[j]
    if (row.trim() === "") continue
    var cols = row.split("\t")
    if (cols.length < 3 || cols[0].trim() === "") continue
    var drmId = "drm:" + cols[0].trim().toLowerCase()
    if (seen[drmId]) continue
    seen[drmId] = true
    gpus.push({
      id: drmId,
      name: cols[1].trim() || cols[0].trim(),
      source: "drm",
      busyPath: cols[2].trim(),
      tempPath: (cols[3] || "").trim(),
      memUsedPath: (cols[4] || "").trim(),
      memTotalPath: (cols[5] || "").trim()
    })
  }
  return gpus
}

// Tab-separated sample rows emitted for DRM cards:
// id, name, gpu_busy_percent, temp millidegrees, vram used bytes, vram total bytes
function parseSysfsGpuSample(text) {
  var lines = String(text || "").split(/\r?\n/)
  var gpus = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.trim() === "") continue
    var cols = line.split("\t")
    if (cols[0].trim() === "") continue
    var tempMilli = parseLooseNumber(cols[3])
    gpus.push({
      id: cols[0].trim(),
      name: (cols[1] || "").trim() || cols[0].trim(),
      utilPct: parseLooseNumber(cols[2]),
      tempC: tempMilli === null ? null : tempMilli / 1000,
      memUsedBytes: parseLooseNumber(cols[4]),
      memTotalBytes: parseLooseNumber(cols[5])
    })
  }
  return gpus
}

// "NVIDIA GeForce RTX 5080" -> "RTX 5080". The bar only shows this when more
// than one card is enabled, so the short form just has to tell them apart.
function shortGpuName(name) {
  var cleaned = String(name || "").replace(/[\t\r\n]+/g, " ").replace(/\s+/g, " ").trim()
  if (cleaned === "") return "GPU"
  var stripped = cleaned
    .replace(/\b(NVIDIA|GeForce|AMD|Radeon|Intel|Arc|Graphics|Corporation)\b/gi, " ")
    .replace(/\s+/g, " ")
    .trim()
  return stripped || cleaned
}

// A card is shown unless its stable id is in the saved disabled list. A card
// that has never been seen is enabled, so a GPU plugged in later shows up
// until the user turns it off.
function gpuEnabled(id, disabledIds) {
  if (!id) return false
  if (!Array.isArray(disabledIds)) return true
  return disabledIds.indexOf(String(id)) === -1
}

function clampInt(value, min, max, fallback) {
  var n = parseInt(value, 10)
  if (isNaN(n)) n = fallback
  if (n < min) n = min
  if (n > max) n = max
  return n
}

// Display pair. If a hand-edited setting has warning >= critical, critical
// moves up, then warning moves down if critical is already at the top.
function normalizeThresholds(warn, crit, min, max) {
  var w = clampInt(warn, min, max, min)
  var c = clampInt(crit, min, max, max)
  if (w >= c) c = Math.min(max, w + 1)
  if (w >= c) w = Math.max(min, c - 1)
  return { warn: w, crit: c }
}

// Edit pair. The field the user just changed wins; the other field moves
// only far enough to keep warning strictly below critical.
function adjustThreshold(which, warn, crit, min, max) {
  var w = clampInt(warn, min, max, min)
  var c = clampInt(crit, min, max, max)
  if (w >= c) {
    if (which === "crit") w = Math.max(min, c - 1)
    else c = Math.min(max, w + 1)
    if (w >= c) {
      if (which === "crit") c = Math.min(max, w + 1)
      else w = Math.max(min, c - 1)
    }
  }
  return { warn: w, crit: c }
}

// "normal" below warning, "warn" from the warning level, "critical" from the
// critical level. A missing reading stays normal so the icon is not painted
// urgent just because the sensor has not answered yet.
function colorBand(value, warn, crit) {
  if (value === null || value === undefined || isNaN(Number(value))) return "normal"
  if (Number(value) >= crit) return "critical"
  if (Number(value) >= warn) return "warn"
  return "normal"
}

// "" means "use the role default". Tokens are theme colors. Anything else
// must be #RRGGBB. Invalid text collapses to "" so a bad paste cannot stick.
function parseColorSetting(value) {
  if (value === null || value === undefined) return ""
  var text = String(value).trim().toLowerCase()
  if (text === "" || text === "auto") return ""
  if (text === "foreground" || text === "accent" || text === "urgent") return text
  if (/^#[0-9a-f]{6}$/.test(text)) return text
  if (/^[0-9a-f]{6}$/.test(text)) return "#" + text
  return ""
}

// One-shot catalog of every GPU. NVIDIA is listed from nvidia-smi. Other
// vendors are DRM cards with gpu_busy_percent whose driver is amdgpu, xe,
// or i915. The proprietary NVIDIA driver does not expose that file, so a
// card is not listed twice.
function discoveryScript() {
  return [
    "if command -v nvidia-smi >/dev/null 2>&1; then",
    "  nvidia-smi --query-gpu=pci.bus_id,name --format=csv,noheader,nounits 2>/dev/null || true",
    "fi",
    "echo ===SYS===",
    "for dev in /sys/class/drm/card[0-9]*; do",
    "  [ -e \"$dev/device/gpu_busy_percent\" ] || continue",
    "  drv=$(basename \"$(readlink -f \"$dev/device/driver\")\" 2>/dev/null || true)",
    "  case \"$drv\" in amdgpu|xe|i915) ;; *) continue ;; esac",
    "  pci=$(basename \"$(readlink -f \"$dev/device\")\")",
    "  name=\"\"",
    "  if [ -r \"$dev/device/product_name\" ]; then name=$(tr -s '[:space:]' ' ' < \"$dev/device/product_name\"); fi",
    "  [ -n \"$name\" ] || name=\"$drv $pci\"",
    "  temp=\"\"",
    "  for candidate in \"$dev\"/device/hwmon/hwmon*/temp1_input; do",
    "    [ -e \"$candidate\" ] || continue",
    "    temp=$candidate",
    "    break",
    "  done",
    "  printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$pci\" \"$name\" \"$dev/device/gpu_busy_percent\" \"$temp\" \"$dev/device/mem_info_vram_used\" \"$dev/device/mem_info_vram_total\"",
    "done"
  ].join("\n")
}

function catArg(path) {
  if (!path) return "''"
  return "\"$(cat " + shellQuote(path) + " 2>/dev/null || true)\""
}

// Periodic sample. Disabled DRM cards are left out of the script. nvidia-smi
// is omitted entirely when every NVIDIA card is disabled. includeDisabled
// is set while the settings panel is open so each row can still show a
// live reading. One nvidia-smi invocation reports every NVIDIA card; the
// bar still hides the ones that are off.
function sampleScript(tempPath, catalog, disabledIds, includeDisabled) {
  var lines = [
    "echo ===STAT===",
    "cat /proc/stat",
    "echo ===MEM===",
    "cat /proc/meminfo",
    "echo ===NET===",
    "cat /proc/net/dev",
    "echo ===TEMP===",
    tempPath ? "cat " + shellQuote(tempPath) + " 2>/dev/null || true" : "true",
    "echo ===DISK===",
    "df -B1 --output=size,used,avail,pcent /",
    "echo ===NV==="
  ]
  var cards = Array.isArray(catalog) ? catalog : []
  var wantNvidia = false
  var sysfs = []
  for (var i = 0; i < cards.length; i++) {
    var card = cards[i]
    if (!card) continue
    // gpuId is the QML name. Repeater models cannot expose a role called id.
    var cardId = card.gpuId || card.id
    if (!cardId) continue
    if (!includeDisabled && !gpuEnabled(cardId, disabledIds)) continue
    if (card.source === "nv") wantNvidia = true
    else if (card.source === "drm") sysfs.push({
      id: cardId,
      name: card.name,
      busyPath: card.busyPath,
      tempPath: card.tempPath,
      memUsedPath: card.memUsedPath,
      memTotalPath: card.memTotalPath
    })
  }
  lines.push(wantNvidia
    ? "nvidia-smi --query-gpu=pci.bus_id,utilization.gpu,temperature.gpu,memory.used,memory.total,name --format=csv,noheader,nounits 2>/dev/null || true"
    : "true")
  lines.push("echo ===SYSGPU===")
  if (sysfs.length === 0) {
    lines.push("true")
  } else {
    for (var j = 0; j < sysfs.length; j++) {
      var card = sysfs[j]
      lines.push("printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' " + [
        shellQuote(card.id),
        shellQuote(card.name || card.id),
        catArg(card.busyPath),
        catArg(card.tempPath),
        catArg(card.memUsedPath),
        catArg(card.memTotalPath)
      ].join(" "))
    }
  }
  return lines.join("\n")
}

if (typeof module !== "undefined") {
  module.exports = {
    parseCpuLine: parseCpuLine,
    cpuPercent: cpuPercent,
    parseMem: parseMem,
    parseNetDev: parseNetDev,
    netRate: netRate,
    formatBytes: formatBytes,
    formatRate: formatRate,
    parseTemp: parseTemp,
    parseDisk: parseDisk,
    splitSections: splitSections,
    shellQuote: shellQuote,
    parseLooseNumber: parseLooseNumber,
    parseNvidiaCsv: parseNvidiaCsv,
    parseGpuCatalog: parseGpuCatalog,
    parseSysfsGpuSample: parseSysfsGpuSample,
    shortGpuName: shortGpuName,
    gpuEnabled: gpuEnabled,
    clampInt: clampInt,
    normalizeThresholds: normalizeThresholds,
    adjustThreshold: adjustThreshold,
    colorBand: colorBand,
    parseColorSetting: parseColorSetting,
    discoveryScript: discoveryScript,
    sampleScript: sampleScript
  }
}
