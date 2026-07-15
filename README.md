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

- **`connection` + `defaults`** — `config.json` device properties, split only
  for readability (the app merges them). They may carry the full field set;
  leave site-specific values (`ip_address`, `serial_port`, `password`) blank and
  omit `model`/`module` (the picker sets those). Keep values JSON-style.

  When a model is picked and it changes the device's module, the app asks:
  **Apply module defaults** (a new device — writes these values, substituting
  the device's index into `btn_name`/`gve_id`) or **Keep current settings** (a
  conversion — leaves the device untouched and lists which fields differ from
  the module defaults).

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
