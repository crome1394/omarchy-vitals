const test = require("node:test")
const assert = require("node:assert/strict")
const { execFileSync } = require("node:child_process")
const Model = require("../Model.js")

test("cpu percent is the busy delta between two /proc/stat samples", () => {
  const prev = Model.parseCpuLine("cpu  10 0 5 85 0 0 0 0\ncpu0 1 0 1 8 0 0 0 0\n")
  const curr = Model.parseCpuLine("cpu  20 0 10 170 0 0 0 0\n")
  assert.equal(Model.cpuPercent(prev, curr), 15)
  assert.equal(Model.cpuPercent(null, curr), null)
})

test("memory uses MemAvailable", () => {
  const mem = Model.parseMem("MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: 400 kB\n")
  assert.equal(mem.usedPct, 60)
  assert.equal(mem.totalKb, 1000)
})

test("network skips loopback and rates a later sample", () => {
  const prev = Model.parseNetDev("lo: 50 0 0 0 0 0 0 0 50 0 0 0 0 0 0 0\neth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0\n")
  const curr = Model.parseNetDev("lo: 99 0 0 0 0 0 0 0 99 0 0 0 0 0 0 0\neth0: 3048 0 0 0 0 0 0 0 4048 0 0 0 0 0 0 0\n")
  assert.deepEqual(Model.netRate(prev, curr, 2), { rxBps: 1024, txBps: 1024 })
  assert.equal(Model.formatRate(1024), "1.0KB/s")
})

test("disk and cpu temperature parse the raw tools", () => {
  const disk = Model.parseDisk("1B-blocks Used Avail Use%\n1000 250 750 25%\n")
  assert.equal(disk.usedPct, 25)
  assert.equal(disk.usedBytes, 250)
  assert.equal(Model.parseTemp("45000\n"), 45)
  assert.equal(Model.parseTemp(""), null)
})

test("section splitter keeps each metric's raw text", () => {
  const sections = Model.splitSections("===STAT===\ncpu 1\n===NV===\n0, 1\n")
  assert.equal(sections.STAT, "cpu 1\n")
  assert.equal(sections.NV, "0, 1\n")
})

test("nvidia csv keeps a comma inside the name and treats N/A as missing", () => {
  const gpus = Model.parseNvidiaCsv(
    "00000000:01:00.0, 7, 46, 1910, 16303, NVIDIA GeForce RTX 5080\n" +
    "00000000:02:00.0, [N/A], [Not Supported], [N/A], 8192, Acme, Super GPU\n"
  )
  assert.equal(gpus.length, 2)
  assert.equal(gpus[0].id, "nv:00000000:01:00.0")
  assert.equal(gpus[0].utilPct, 7)
  assert.equal(gpus[0].tempC, 46)
  assert.equal(gpus[0].memUsedBytes, 1910 * 1024 * 1024)
  assert.equal(gpus[0].name, "NVIDIA GeForce RTX 5080")
  assert.equal(gpus[1].utilPct, null)
  assert.equal(gpus[1].tempC, null)
  assert.equal(gpus[1].memUsedBytes, null)
  assert.equal(gpus[1].name, "Acme, Super GPU")
})

test("catalog lists nvidia and drm cards without duplicating an id", () => {
  const text = [
    "00000000:01:00.0, NVIDIA GeForce RTX 5080",
    "===SYS===",
    "0000:c1:00.0\tRadeon RX 7800 XT\t/sys/busy\t/sys/temp\t/sys/used\t/sys/total",
    "0000:c1:00.0\tagain\t/sys/busy\t\t\t"
  ].join("\n")
  const cards = Model.parseGpuCatalog(text)
  assert.equal(cards.length, 2)
  assert.equal(cards[0].source, "nv")
  assert.equal(cards[0].id, "nv:00000000:01:00.0")
  assert.equal(cards[1].id, "drm:0000:c1:00.0")
  assert.equal(cards[1].tempPath, "/sys/temp")
})

test("sysfs gpu sample converts millidegrees and keeps byte counts", () => {
  const gpus = Model.parseSysfsGpuSample("drm:0000:c1:00.0\tRX 7800 XT\t12\t47000\t1024\t8192\n")
  assert.equal(gpus[0].utilPct, 12)
  assert.equal(gpus[0].tempC, 47)
  assert.equal(gpus[0].memUsedBytes, 1024)
})

test("short gpu names drop the vendor words", () => {
  assert.equal(Model.shortGpuName("NVIDIA GeForce RTX 5080"), "RTX 5080")
  assert.equal(Model.shortGpuName("AMD Radeon RX 7800 XT"), "RX 7800 XT")
  assert.equal(Model.shortGpuName("Intel Arc Graphics"), "Intel Arc Graphics")
  assert.equal(Model.shortGpuName(""), "GPU")
})

test("a gpu is shown until its id is disabled, and a new id stays shown", () => {
  assert.equal(Model.gpuEnabled("nv:00000000:01:00.0", []), true)
  assert.equal(Model.gpuEnabled("nv:00000000:01:00.0", ["nv:00000000:01:00.0"]), false)
  assert.equal(Model.gpuEnabled("nv:00000000:03:00.0", ["nv:00000000:01:00.0"]), true)
  assert.equal(Model.gpuEnabled("nv:1", null), true)
})

test("thresholds stay ordered around the field the user changed", () => {
  assert.deepEqual(Model.adjustThreshold("warn", 95, 90, 0, 100), { warn: 95, crit: 96 })
  assert.deepEqual(Model.adjustThreshold("crit", 70, 70, 0, 100), { warn: 69, crit: 70 })
  assert.deepEqual(Model.adjustThreshold("warn", 100, 90, 0, 100), { warn: 99, crit: 100 })
  assert.deepEqual(Model.normalizeThresholds(90, 80, 0, 100), { warn: 90, crit: 91 })
})

test("color bands switch at the warning and critical levels", () => {
  assert.equal(Model.colorBand(69, 70, 90), "normal")
  assert.equal(Model.colorBand(70, 70, 90), "warn")
  assert.equal(Model.colorBand(90, 70, 90), "critical")
  assert.equal(Model.colorBand(null, 70, 90), "normal")
})

test("color settings accept tokens and full hex only", () => {
  assert.equal(Model.parseColorSetting("Accent"), "accent")
  assert.equal(Model.parseColorSetting("#E6B84A"), "#e6b84a")
  assert.equal(Model.parseColorSetting("e6b84a"), "#e6b84a")
  assert.equal(Model.parseColorSetting("#fff"), "")
  assert.equal(Model.parseColorSetting("nope"), "")
  assert.equal(Model.parseColorSetting(""), "")
})

test("sample script skips disabled cards", () => {
  const catalog = [
    { gpuId: "nv:00000000:01:00.0", source: "nv", name: "RTX 5080" },
    { gpuId: "drm:0000:c1:00.0", source: "drm", name: "RX 7800 XT", busyPath: "/sys/busy", tempPath: "/sys/temp", memUsedPath: "", memTotalPath: "" }
  ]
  const allOn = Model.sampleScript("", catalog, [], false)
  assert.match(allOn, /nvidia-smi --query-gpu=/)
  assert.match(allOn, /\/sys\/busy/)

  const nvOff = Model.sampleScript("/tmp/temp", catalog, ["nv:00000000:01:00.0"], false)
  assert.doesNotMatch(nvOff, /nvidia-smi --query-gpu=/)
  assert.match(nvOff, /\/sys\/busy/)
  assert.match(nvOff, /cat '\/tmp\/temp'/)

  const whileOpen = Model.sampleScript("", catalog, ["nv:00000000:01:00.0", "drm:0000:c1:00.0"], true)
  assert.match(whileOpen, /nvidia-smi --query-gpu=/)
  assert.match(whileOpen, /\/sys\/busy/)
})

test("this machine's nvidia-smi output parses", () => {
  let raw = ""
  try {
    raw = execFileSync("nvidia-smi", [
      "--query-gpu=pci.bus_id,utilization.gpu,temperature.gpu,memory.used,memory.total,name",
      "--format=csv,noheader,nounits"
    ], { encoding: "utf8" })
  } catch {
    return
  }
  const gpus = Model.parseNvidiaCsv(raw)
  assert.ok(gpus.length >= 1)
  assert.equal(gpus[0].id, "nv:00000000:01:00.0")
  assert.match(gpus[0].name, /RTX 5080/)
  assert.ok(gpus[0].utilPct >= 0 && gpus[0].utilPct <= 100)
  assert.ok(gpus[0].tempC > 0 && gpus[0].tempC < 120)
  assert.ok(gpus[0].memTotalBytes > gpus[0].memUsedBytes)
})

test("discovery on this machine finds the discrete GPU and no drm duplicate", () => {
  let text = ""
  try {
    text = execFileSync("bash", ["-c", Model.discoveryScript()], { encoding: "utf8" })
  } catch {
    return
  }
  const cards = Model.parseGpuCatalog(text)
  assert.deepEqual(cards.map((card) => card.id), ["nv:00000000:01:00.0"])
  assert.match(cards[0].name, /RTX 5080/)
})
