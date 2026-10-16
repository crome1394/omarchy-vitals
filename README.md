# Vitals

A bar widget for [Omarchy](https://omarchy.org/) that shows live CPU, memory, disk, temperature, GPU, and network usage. Each capped metric is an icon that fills as usage rises, the same way the built-in wifi and battery icons do. The plugin id is `crome.vitals`, so it can sit next to Kenny De Mits' Resources plugin without sharing a name.

Click the widget for its settings. The panel opens on Metrics, and the other tabs are Display, GPUs, and Thresholds. Display includes the memory size option and where the widget sits on the bar.

CPU, memory, disk, CPU temperature, and network behavior is adapted from [Kenny De Mits' omarchy-bar-resources](https://github.com/Kyotroo/omarchy-bar-resources) (MIT).

## Install

```bash
omarchy plugin add https://github.com/crome1394/omarchy-vitals.git
omarchy plugin enable crome.vitals --section right
```

Move it later from the settings panel (Left, Center, Right) or with `omarchy bar move crome.vitals --section <left|center|right>`.

To install this checkout without cloning it:

```bash
rm -rf ~/.config/omarchy/plugins/crome.vitals
mkdir -p ~/.config/omarchy/plugins/crome.vitals
cp manifest.json Vitals.qml Model.js LICENSE README.md ~/.config/omarchy/plugins/crome.vitals/
omarchy-shell shell rescanPlugins
omarchy plugin enable crome.vitals --section right
```

Remove it with `omarchy plugin remove crome.vitals`. Settings live on the widget's entry in `~/.config/omarchy/shell.json` and are removed with it.

## Metrics

| Metric | Source | Notes |
|---|---|---|
| CPU | `/proc/stat` | Delta between two samples, like `top` |
| Memory | `/proc/meminfo` | Uses `MemAvailable`, not `MemFree`. Can show used size instead of a percentage |
| Disk | `df` on `/` | Used space on the root filesystem |
| CPU temperature | `/sys/class/hwmon` | `coretemp`, `k10temp`, or `zenpower`, whichever exists |
| GPU usage | `nvidia-smi`, or `gpu_busy_percent` | One icon per enabled card |
| GPU temperature | `nvidia-smi`, or the card's hwmon | Shown next to GPU usage when that metric is on |
| Network | `/proc/net/dev` | Combined throughput, excluding loopback |

NVIDIA cards are read with one `nvidia-smi` query (`utilization.gpu`, `temperature.gpu`, and VRAM). Other cards are read from sysfs when the kernel exposes `gpu_busy_percent` for `amdgpu`, `xe`, or `i915`. VRAM is included in the tooltip and the settings row, not as its own icon.

The GPU list in the settings panel has a switch for every card Linux has enumerated. A card that is off is left out of the bar and, for sysfs cards, out of the periodic sample. A card discovered later is shown until you turn it off. The choice is stored by PCI id, so a reboot does not reshuffle it. With more than one card enabled, each one is labeled with a short name. An integrated GPU that the firmware has switched off is not on the PCI bus, so it is not listed, including as a disabled row.

**Memory as amount** replaces the memory percentage with the used size, such as `17GB`. The icon still fills by percentage, and the tooltip still shows used and total. **Bar position** moves the widget to the left, center, or right of the bar.

A missing sensor reads `n/a` instead of a guessed value.

## Color thresholds

The settings panel has a **Color thresholds** switch, on by default.

- **Usage warning / critical** apply to CPU, memory, disk, and GPU percent. Defaults are 70 and 90.
- **Temperature warning / critical** apply to CPU and GPU temperature. Defaults are 70°C and 85°C.
- Warning is kept below critical.
- **Normal**, **warning**, and **critical** each take a theme color (foreground, accent, or urgent) or a `#RRGGBB` value. Normal defaults to the accent when **Use accent color** is on, otherwise the bar text color. Warning defaults to `#e6b84a`. Critical defaults to the theme urgent color.
- The icon fill uses the band color. Below the warning level stays normal. The number uses that same color unless **Value color** is set, on the Thresholds tab. Value color accepts foreground, accent, urgent, or `#RRGGBB`. Leave it automatic to keep the numbers matched to the icons. Network has no threshold of its own, so its numbers stay the bar text color until Value color is set.
- With the switch off, the fill matches the original widget: accent or foreground, and the urgent color at 90% or 85°C. Numbers stay the bar text color unless Value color is set.
- Hovering the widget shows each visible metric with the same icon used on the bar. Those lines are left-aligned. "Click for settings" stays centered under them.

The bar's width changes when a metric or a GPU is turned on or off. Each value reserves room for its widest reading (`100%`, `999TB` for a memory amount, `999°C`, `999.9MB/s`), so ticking numbers do not push the widgets beside it.

## License

MIT. See [LICENSE](LICENSE). The original copyright of Kenny De Mits is kept alongside this derivative.
