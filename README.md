# extron_configurator

Room Config Builder — a Flutter desktop app to edit and build the `config.json`
files that drive Extron processors, from a library of Python device modules.

## Device modules & `DEVICE_INFO`

Each Python device module under `device/` can declare a module-level
`DEVICE_INFO` dict that the **app** reads (the driver ignores it). It populates
the Model dropdown on each device tab and seeds a new device's settings. See
`device/avr_TR311.py` and `device/extr_dsp_DMP_64_Plus_Series.py` for reference
implementations.

```python
DEVICE_INFO = {
    "device_type": "camera",              # which tab(s) list these models
    "models": ["TR311HW", "TR311"],       # default module for these model names
    "omit": ["group_*"],                  # keys this model does NOT use
    "connection": { ... },                # config.json device properties, and
    "defaults":   { ... },                #   these — merged by the app
}
```

- **`device_type`** — one value or a list; case/plural-insensitive. A model with
  no `device_type` is hidden from the per-tab list and appears only when the
  picker's **Show all device types** checkbox is ticked. Valid values:

  | Tab | Value | Also accepted |
  |---|---|---|
  | Cameras | `camera` | |
  | Projectors / Displays | `projector` | `display` |
  | Switchers | `switcher` | |
  | DSPs | `dsp` | |
  | USB Switchers | `usb` | (`switcher` also matches this tab) |
  | Power Controllers | `power` | `controller` |
  | MediaPorts | `mediaport` | |
  | Wireless (ShareLink) | `wireless` | `sharelink` |
  | Recorders | `recorder` | |
  | Screens (Relays/Network) | `screen` | `relay`, `network` |

  Families come from `ui_schema.json` (`device_types`); matching is token-based
  in `AppStateProvider.modelMatchesDevice`.

- **`models`** — marks this file as the default module for those model names
  (falls back to the driver's `self.Models` keys when omitted).

- **`omit`** — config keys this model doesn't use, as exact names or `*` globs.
  The defaults that build a device block are family-wide: `key_map.json` gives
  every `SWITCHERDEVICE_*` the seven `group_*` audio group numbers, which is
  right for a matrix acting as the room's audio hub and wrong for a plain
  scaler. Listing `"omit": ["group_*"]` strips them after the defaults run, and
  keeps **Check Defaults** from offering them back. Each removal is reported in
  the conversion log.

  This has to be declared rather than detected: the IN1608 driver defines eight
  `UpdateGroup*` commands, so module capability says "yes" for exactly the
  models that don't use them. Whether a model uses them is a deployment fact.

- **`connection` + `defaults`** — `config.json` device properties, split only
  for readability (the app merges them). They may carry the full field set;
  leave site-specific values (`ip_address`, `serial_port`, `password`) blank and
  omit `model`/`module` (the picker sets those). Keep values JSON-style.

  When a model is picked and it changes the device's module, the app asks:
  **Apply module defaults** (a new device — writes these values, substituting
  the device's index into `btn_name`/`gve_id`) or **Keep current settings** (a
  conversion — leaves the device untouched and lists which fields differ from
  the module defaults).

## Device Editor (the `Catalog` tab)

The room config describes control and nothing else — it knows a device's IP
address, never that it has four HDMI inputs, is 2U, draws 90 W and lists at
$8,500. Those four facts drive the AV diagram, the rack elevation, the power
estimate and the cost estimate, so they live once in a device catalog rather
than being re-typed per room.

The tab edits `av_devices.json` (Root Folder, or wherever the loaded one came
from). Per model: **connectors** (in/out, signal type, which edge of the box),
**rack units**, **estimated power draw**, **unit price**, plus manufacturer,
part number, category and notes. Entries here override the app's built-in
models; a built-in you never touch stays built-in, so a later app build can
still improve it, and **Save catalog** only writes the entries that are yours.

Nothing is written to disk until **Save catalog** — a mistyped price never
reaches a shared drive on its own.

### Merging another engineer's catalog

Two people keep two copies of this file: one has priced the switchers, the
other has drawn their connectors. Neither is authoritative, so **Merge from
file...** compares the two entry by entry *and field by field* and shows only
what actually differs, each difference with its own checkbox (or **Select
all**). Applying copies exactly what is ticked.

- a model you have and they don't is left alone — a merge adds and updates,
  it never deletes
- a field you filled in is never overwritten by a blank they never got to
- merged entries become yours, so the next save writes them

**Export a copy...** hands your catalog to someone else without repointing
your own saves at their folder.

## Cost estimate (AV Flow tab → `Cost`)

Prices the room that is drawn on the AV canvas. Quantities are the devices on
the diagram, grouped exactly as the pack list groups them, so the estimate and
the equipment order cannot drift apart. Unit prices come from the catalog; a
price typed on this page is a **room override** — what this job was quoted —
kept in the room's sidecar and never written back over the catalog.

On top of the equipment:

- **Fees** — any number, each a percentage of the pre-tax subtotal (freight,
  install, contingency, overhead). They do not compound onto each other: two
  5% fees are 10% of the job. Each says whether it is itself taxable.
- **Other items** — flat lines with their own quantity and unit price for
  labour, cable, mounts; taxable per line.
- **Tax** — one rate, applied to equipment plus the items and fees marked
  taxable.

Devices nobody has priced are counted and called out rather than being quietly
totalled as free.

Saved with the diagram in `<config>_av_flow.json`.

## The room workbook

**Report → Full room workbook (.xlsx)**, on both the Schematic and AV Flow
tabs, writes one book with a tab per question:

| Sheet | Contents |
|---|---|
| Control | the control system as configured, plus the room's estimated power draw, current at 120/208 V, heat load and per-device power schedule |
| AV Flow | cable schedule, pack list (with rack U, in/out and watts), jack schedule, connector utilization |
| Racks | how full and how hot each frame is, and what sits on which U |
| Cost Estimate | equipment, other items, fees, tax, total |

Every sheet is dealt from the same section builders the single-sheet exports
use, so a figure cannot differ between the two buttons. The diagram image can
only be captured from the page on screen, so the tab you export from is the one
that gets illustrated.

## In-app PDF manuals

Each device form has a **Manual (PDF)** button. It opens
`<module base name>.pdf` from the Documentation folder (set in **App Config**,
default `<root>/documentation`) in an in-app viewer (scroll / zoom / pages),
with an **Open externally** fallback to the OS PDF viewer.

## Screenshot & annotate

The toolbar **camera** button captures the current content area and opens an
annotator: mark it up with pen, line, arrow, rectangle, highlight, and text
labels (with color and stroke-width selection), then **Export PDF** (save via
the file dialog) or **Print**.
