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
address, never that it has four HDMI inputs, is 3U, draws 90 W and lists at
$8,500. Those facts drive the AV diagram, the rack elevation, the power and
heat estimates and the cost estimate, so they live once in a device catalog
rather than being re-typed per room.

The tab edits `av_devices.json` (Root Folder, or wherever the loaded one came
from). Per model: **connectors** (in/out, signal type, which edge of the box),
**rack units**, **power in** (mains / PoE / none), **estimated power draw**,
**heat output**, **unit price**, plus manufacturer, part number, category and
notes. Entries here override the app's built-in models; a built-in you never
touch stays built-in, so a later app build can still improve it, and **Save
catalog** only writes the entries that are yours.

### Power in, and heat out

Every catalog entry carries a **power inlet** unless it is genuinely passive
(a speaker, a cable, a blanking plate). The **Mains / PoE / None** toggle keeps
the inlet connector in step with itself — pick PoE and the port relabels, pick
None and it goes away — so the drawing and the rack load can never disagree
about whether a box is plugged into anything. PoE devices are counted in the
room's total draw but kept out of the mains current, because they come off the
switch's budget rather than the room's circuit.

**Heat** defaults to the watts converted (1 W = 3.412 BTU/hr) and can be
overridden per model where the manufacturer publishes a figure — an
amplifier's rated draw is not all heat, since some of it leaves through the
speaker terminals. The rack report totals it per frame, in BTU/hr and in tons,
which is what sizing a cabinet fan or a closet mini-split actually asks for.

### Where the catalog came from

The shipped `av_devices.json` holds **990 Extron models** imported from the
engineering stencils in `drawings_library/`: model, part number, description,
product family and the connector set read straight off each drawing. See
[DEVICE_CATALOG_IMPORT.md](DEVICE_CATALOG_IMPORT.md) for what came in and what
is still blank, and [tools/](tools/README.md) for re-running the import
against a refreshed stencil pack.

Rack heights, watts, BTU and prices are **not** in the drawings. They are left
at 0 — "not recorded" — rather than guessed, and every report counts what is
still missing instead of totalling a blank as free and cold.

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

## Opening and converting

Opening a file **opens the file**. When a legacy room needs migrating the
conversion still runs in memory, but nothing blocks the screen: a **Convert**
button next to New Config lights up with the number of changes waiting, and
that is where the migration log, the change-by-change review and "Use
Original" live. A room with nothing to migrate leaves the button grayed out,
so its state is also the answer to "does this file need converting?".

## Cost estimate (the `Cost` tab)

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
  labor, cable, mounts; taxable per line.
- **Tax** — one rate, applied to equipment plus the items and fees marked
  taxable.

Devices nobody has priced are counted and called out rather than being quietly
totalled as free.

**Screenshot** renders the estimate as a PNG with every control hidden and the
page forced light — the image is the quote, not a picture of the app with an
Export button on it — and stamps the date on it, because a quote nobody can
tell the age of is one somebody quotes back at you next year.

Saved with the diagram in `<config>_av_flow.json` — and **every config save
writes that sidecar**, so saving the project saves the estimate. It is not a
separate button to forget.

## Save All

The toolbar's **Save All** writes the whole job into `<folder>/<room name>/`,
the room name coming from the wizard. It contains the config, the AV sidecar
(diagram + estimate), the four-sheet workbook, plain-text device / AV / cost
reports, PNGs of the control schematic, signal flow and rack elevation, and a
copy of the custom catalog entries and the rate card — so the figures behind
the numbers travel with them and the estimate is auditable a year later.

Diagram images can only be rendered from a tab that is on screen, so Save All
walks the three diagram tabs to capture them and puts you back where you
started. Anything it could not capture is listed in the result dialog and in
the folder's `README.txt`, rather than being quietly missing.

## Where things are in the room (the `Floor Plan` tab)

The signal flow says what is cabled to what. It does not say where anything
**is** — and that is what the installer, the electrician and whoever pulls the
cable actually ask. "Six network jacks" is not something you can order conduit
against; "six network jacks in the front floor box" is.

So a room carries a short list of **locations** — the instructor station, the
front floor box, the ceiling, the rack — each with a **mounting surface**
(ceiling / wall / floor / rack / lectern / table / credenza / IDF), because
that is what changes the work. Every device, jack field and control run names
one, from a field on its own editor, and three things fall out of it:

- the reports count **jacks and cable runs per location**, grouped by surface,
  and count runs per **cable label** ("AV-" ×6, "NET-" ×12) — the numbers a
  rough-in is estimated from;
- the AV canvas can draw the **floor plan behind the diagram** so the boxes
  group by where they physically are;
- the Floor Plan tab carries **callouts** — a numbered marker that says "the
  rack here is Rack 1, described on the Racks tab of the workbook". The app
  resolves the target's name itself, so renaming a rack cannot leave the plan
  pointing at a name that no longer exists.

The counts run live across the top of the plan, from the same function the
report uses, so the page and the export cannot disagree.

The plan image is copied in beside the config and travels in the room folder;
it is not embedded, so the sidecar stays hand-readable and a 4 MB architectural
export stays out of it.

### Screen and shade control runs

A three-position screen switch by the door and a motor above the board is a run
with two ends and no signal — neither end is a box on the signal flow, so there
was nowhere to record it and it turned up as a surprise at rough-in. Each run
names where it **starts** and where it **ends**, what cable it is and how long,
and comes out on its own sheet.

### Jack numbering

A jack number is the room's addressing scheme: an installer at the plate finds
it on the report and expects one thing behind it. **Adding a wall box or patch
panel checks every number against every other jack in the room** — ignoring
case and separators, so `AV-01`, `av 01` and `AV01` are one jack — and refuses
a clash, with the next free block one click away. Renaming a jack by hand gets
the same check as a confirm rather than a refusal: a room really can have two
plates numbered alike because that is what is on the wall, it just must not
happen by accident. New boxes default to the room's own number as the prefix.

## Room type presets

A shop builds the same four or five rooms over and over, and starting each from
an empty canvas is how two rooms of the same type end up with different jack
prefixes and cable counts nobody can compare. A **room type** is a document —
the equipment, the locations, the jack fields with their numbering, the cabling,
the racks and the screen runs — offered when a room is created.

Presets are files under `room_presets/` in the Root Folder, so they sit on the
same drive the catalog and the rate card already do. Four ship with the app —
**basic classroom, hyflex classroom, huddle space, active learning space** —
written out on first use rather than compiled in, because the first thing
anybody will do is change them; an edited copy is never overwritten. **Report →
Save this room as a room type** writes the room you are looking at as another.

Applying one renumbers its jacks into this room's scheme, re-keys everything so
applying twice gives twice the gear rather than a collision, and reuses a
location that already exists by name rather than creating a second "Ceiling".
The room number, the building and the control config are left alone.

## Building the control side of a room that was only budgeted

A room is usually specified long before its control config: somebody walks the
space, lists the gear, draws a rack and puts a number on it. That leaves a full
diagram and a priced estimate and **no control blocks** — so building the
control side has meant typing every device in a second time.

**Build the control side from the diagram** (on the Cost tab, the System-tab
placeholder, and the missing-modules banner) does it from what is already
drawn: one config block per device, in the right family, carrying the same
`ui_schema` defaults the Setup Wizard writes, named **sequentially per family**
("Projector 1", "Projector 2") rather than from whatever was typed on the
canvas. The diagram node is re-keyed onto its block, so the two become one
device and the cables come with it.

Everything is shown before anything is written, with two things called out:

- devices **no python module claims** — created with the module blank, never
  guessed, so they stay on every missing-module list in the app and in the
  **Devices Without a Control Module** section of the report. This covers
  generic boxes (a projector, a power controller, a screen) exactly as it
  covers catalog models;
- devices **no device family claims**, which usually means a speaker or a wall
  plate that never had a control block — but a projector on that list means its
  catalog category is what needs fixing.

Nothing is destructive: existing blocks are left alone and the family counts are
raised rather than reset.

## The room workbook

**Report → Full room workbook (.xlsx)**, on both the Schematic and AV Flow
tabs, writes one book with a tab per question:

| Sheet | Contents |
|---|---|
| Control | the control system as configured, plus the room's estimated power draw, current at 120/208 V, heat load and per-device power schedule |
| AV Flow | cable schedule (every run with its source, destination and the location of each end), pack list (with rack U, in/out, watts and location), jack schedule, connector utilization |
| Locations | what is where, jacks and runs counted per location and grouped by mounting surface, runs per cable label, the screen and shade runs, and the floor plan's callouts |
| Racks | how full and how hot each frame is, and what sits on which U |
| Cost Estimate | equipment, other items, fees, tax, total |

Every sheet is dealt from the same section builders the single-sheet exports
use, so a figure cannot differ between the two buttons. The diagram image can
only be captured from the page on screen, so the tab you export from is the one
that gets illustrated.

## Devices without a control module

The catalog covers everything you can buy; the module library under `device/`
covers what the control system can actually drive. The gap between them is
reported rather than left to be found on site:

- the **Pack List** carries a `Control module` column, naming the module or
  saying `none`;
- a **Devices Without a Control Module** section lists the room's undriven
  devices, and drops out entirely when there are none.

This is resolved live rather than recorded in `av_devices.json`, because which
models have a driver changes every time a module is added to the library.

## Wall boxes and patch panels

**Add wall box / patch panel** numbers its jacks `<prefix><number>`, defaulting
to the room-number scheme: prefix `1110`, first number `01`, giving `111001`,
`111002`, … The first number's width sets the padding, so `01` keeps two
digits and `1` numbers plainly.

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
