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
    "network":            { ... },        # and these, per connection style
    "serial":             { ... },
    "serialoverethernet": { ... },
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

- **`network` / `serial` / `serialoverethernet` / `http`** — the same kind of
  block, per connection style. One flat `connection` block can only spell out
  one way of reaching the box, so a driver that speaks both RS-232 and TCP left
  the wrong port behind when somebody changed `com_type` in the editor. Declare
  the connection-specific half here and:

  - changing **Com Type** on the Devices tab loads that block straight away
    (and says so in a snackbar). Blank values are never written over a
    site-specific one, and a block that repeats `com_type` cannot bounce the
    choice back;
  - picking a **model** merges the block for whichever connection the defaults
    land on over the flat `connection` + `defaults`, so the specific figure
    wins.

  They may also be grouped under a `"com_types": { ... }` dict, which wins over
  the top-level spelling. Names are matched case- and punctuation-insensitively
  (`SerialOverEthernet`, `serial_over_ethernet`, `Serial Over Ethernet`); a
  block named anything else is ignored rather than guessed at.

  ```python
  DEVICE_INFO = {
      "models": ["VPL-PHZ60"],
      "connection": {"com_type": "Network", "host": "processor1"},
      "network":            {"protocol": "TCP", "net_port": 53595},
      "serialoverethernet": {"protocol": "TCP", "net_port": 2001},
      "serial":             {"baud": 38400},
  }
  ```

- **Check Module Defaults** (Devices tab) — the review that runs after a
  conversion, on demand, for the device on screen. It lists every property the
  block has filled in **differently** from what the model's own driver states —
  the device converted to SSH because its family is SSH while its driver says
  TCP on a port of its own — with the connection and keep-alive keys ticked and
  the driver's naming left alone. Its neighbour **Check Defaults** answers the
  other question: which keys the block is *missing*.

## Device Editor (the `Catalog` tab)

The room config describes control and nothing else — it knows a device's IP
address, never that it has four HDMI inputs, is 3U, draws 90 W and lists at
$8,500. Those facts drive the AV diagram, the rack elevation, the power and
heat estimates and the cost estimate, so they live once in a device catalog
rather than being re-typed per room.

The tab edits `av_devices.json` (Root Folder, or wherever the loaded one came
from). Per model: **connectors** (in/out, signal type, which edge of the box),
**rack units**, **keep clear above / below**, **power in** (mains / PoE /
none), **estimated power draw**, **heat output**, **unit price**, plus
manufacturer, part number, category and notes. Entries here override the app's built-in models; a built-in you never
touch stays built-in, so a later app build can still improve it, and **Save
catalog** only writes the entries that are yours.

### Cable by the length

A room does not buy "HDMI cable" — it buys a 3 ft one and a 25 ft one at
different prices, and quoting every run at one figure is wrong in both
directions at once. A cable entry therefore carries a **length** as well as a
signal (`cableLengthFt` in `av_devices.json`), and a type is broken down by
adding one entry per length, each with its own model and price. Leave the
length blank for bulk cable off a spool.

The estimate then puts every drawn run on the **shortest stock length that
reaches it** and gives each of those a line of its own: `HDMI 6 ft ×4` at one
price, `HDMI 25 ft ×2` at another. A run longer than anything stocked is quoted
at the longest. Spares stay on the type rather than on one of its lengths, and
a type with a single entry comes out as the one line it always did — including
any price typed on it by hand.

### Minimum space in a rack

A rack elevation says what fits and nothing about what should not be touching.
An amplifier that vents upwards, a drawer whose lid opens, a box with its
intake on the top cover — all of them fit under the next unit and all of them
fail on site. **Keep clear above** and **Keep clear below** record that on the
model, in rack units, and every room that racks the part inherits it
(`clearanceAboveU` / `clearanceBelowU` in `av_devices.json`).

The rack elevation shades those rails **light red**, and a box standing in one
is outlined in red with a warning in its tooltip. It is a warning and never a
rule: the rack still accepts every drop, because the person in front of the
frame knows things the catalog does not.

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

### Inputs the room has no source for

A room's source list is spelled twice — `gui_inputs` counts them, `gui_tab_type`
names them ("DOC_USB_WL") — and the switcher input each source lands on is a key
of its own. Nothing tied the two together, so a room retyped from six sources
down to four kept shipping `input_dvd` and `input_blu_ray`: input numbers for
buttons the panel does not draw, pointing at switcher inputs something else is
now plugged into. Loading a room now **removes the `input_*` keys its sources do
not entitle it to**, and the camera inputs go with `dev_cameras` when it is 0.
Retyping the sources puts the numbers straight back, so it stays a reversible
choice. Which token entitles which key is schema-driven — `source_inputs` in
`ui_schema.json` — and a key the schema does not name is never touched. A room
that has not *stated* its sources at all is left alone: a silence is a question,
not a No.

## Rack elevations (the `Racks` tab)

Frames drawn to scale with numbered U rails. Anything with a rack height drops
into a free span, and several small boxes share one rail — the row re-splits to
fit them and closes ranks again the moment one is dragged off it, so two
survivors of a three-way split go back to halves rather than sitting in thirds
with a hole beside them.

Two ways to put something in that is not a device on the signal flow:

- **Add plate / shelf** — vent plates, blanks, shelves, drawers and lacing
  bars, off the catalog's rack categories, priced into the estimate under Rack
  hardware. On the toolbar whether or not edit mode is on: ordering the parts
  and arranging the frame are different jobs.
- **Add other device** — the box in the rack that has no catalog entry, a Cisco
  switch or an owner-furnished appliance. It occupies rails like anything else
  and is quoted under **Equipment**, not Rack hardware — a four-figure box
  filed with the blanking plates is a four-figure box nobody totals. Leave the
  price blank and the cost sheet reports it as **not priced** until somebody
  fills one in. It is deliberately not written to the catalog: a model with no
  part number and no price is a fact about this job, not a price-list entry.

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

**Add to catalog** (the 📚 icon on any line added by hand) is the trip back the
other way. A typed line is how a part enters the building — somebody is quoted
a figure over the phone and types it on the job in front of them — and until
now that was where it stopped, so the next room typed the same box in again at
whatever price that person remembered. It writes the entry to `av_devices.json`
once, points the line at it and drops the typed price, so the line is priced
like everything else from then on and a revision reaches every room that uses
it. Offered on Equipment, Rack hardware, Cabling and Other items; greyed out on
a line that already comes off the catalog, and on a counted line, whose price
belongs to the thing on the diagram.

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

### The key

A plan exported as a PNG and mailed to a contractor is read away from this app,
and every convention on it means nothing on its own. So each sheet carries a
**key**, drawn on the sheet itself and inside the boundary that gets captured —
it is part of the exported image and of the sheet in the workbook, not a panel
that only exists on screen. It lists the **mounting-surface icons** actually
used on that sheet, the **cable runs** with their colour, dash pattern and
number, the **callouts** and what each points at, and the **notation** colours.
Drag it where it reads best (per sheet — a legend clear of the title block on
one drawing can be on top of it on another) or turn it off from the toolbar.

### Blank space round the drawing

An architectural export draws all the way to its own border, so the key, the
callout list and the notes end up on top of the walls. **Blank space round the
drawing** in the sheet's settings adds paper on any of the four sides, in plan
pixels. It is part of the sheet, so it is in the exported PNG and in the
workbook image — and adding space on the left or top moves everything already
drawn with the plan, so a marker stays on the wall it was placed on.

### Label colours

An architectural plan is a line drawing, and text dropped straight onto one
lands on a wall. Every label on the sheet is therefore printed on a plate, and
**Label colours** on the toolbar says what colour that plate and the words on
it are — separately for **location names**, **callout markers** and **cable run
labels**, because the three are read at different moments by different people:
a sheet issued for rough-in wants the runs shouting and the callouts quiet, and
the same sheet in a design review wants the opposite.

The colours are per sheet, like everything else drawn on one, and stored in the
sidecar. A kind nobody has recoloured follows the light or dark drawing it is
on, exactly as it always did; the reset arrow on each row puts it back.

### Reading a drawing that is not in colour

Colour alone fails the moment a sheet is printed, photocopied, or read by
somebody who cannot distinguish red from green — and it fails hardest on the
three parallel lines between the same two boxes, which is exactly where it
matters. So a run carries a **dash pattern** as well as a colour, keyed off the
cable rather than the run, so "Cat 6a is the dashed one" is true of every Cat 6a
on the sheet. Crossings are drawn as a **hop**, because two lines meeting at a
point is otherwise indistinguishable from two lines joining at one. A run that
carries on past the sheet — to the IDF, or simply to a location nobody has
placed on this drawing — leaves the page as a **squiggle** labelled with where
it is going, rather than a line that stops at the border for no reason.

Both drawings export a **black-and-white version for print**, rendered in the
light theme before the colour is dropped: a dark-mode capture converted to grey
is a black page with pale lines on it, which a printer renders as a black page.

### Editing a run by hand

Select a run and it grows handles: a hollow dot at the middle of each leg adds
a bend, a filled dot is a bend you can drag, and a double-click drops one
again. A dragged bend **snaps square** with the bends either side of it as it
comes close, because cable runs along walls and trays and hitting an exact
right angle by dragging a dot is a thing nobody can do. **Right-click a hollow
dot** to put a 90° turn in outright — an L on a diagonal leg, and a jog out and
back on a leg that is already straight.

The drag is held locally and written once on release, so steering a run no
longer re-routes every other run on the sheet between pointer events.

Run labels can be **dragged** where they read best (double-click puts one back)
and **right-clicked to hide** just that one; **Labels** on the toolbar says how
many are hidden and brings them all back. Hidden labels and moved labels are
kept in the room's sidecar. On the Cabling sheet, each run also has a square
handle at each end that moves **where it lands on its box** — cable comes into
a floor box from one side, and four runs pointing at the middle of the same box
say nothing about which knockout each of them uses.

### Cable runs between places

A three-position screen switch by the door and a motor above the board is a run
with two ends and no signal — neither end is a box on the signal flow, so there
was nowhere to record it and it turned up as a surprise at rough-in. Each run
names where it **starts** and where it **ends**, what cable it is and how long,
and comes out on its own sheet.

Two things beyond that, because the run that actually gets installed is rarely
a straight line between two pieces of gear:

- a **cable number** (`C-101`), printed on the run and in the schedule, so the
  drawing, the schedule and the label on the cable all say the same thing;
- the places it is **routed through** — projector box, AV pull box, equipment
  rack — in order. Each hop is a leg on the cabling sheet, so the drawing shows
  the path the cable is pulled along and the pull box appears as the box
  somebody has to install, instead of both being implied by a line straight
  through the middle of the room.

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

**The book icon in the toolbar**, on every tab, writes one book with a tab per
question:

| Sheet | Contents |
|---|---|
| Control | the control system as configured, plus the room's estimated power draw, current at 120/208 V, heat load and per-device power schedule |
| AV Flow | cable schedule (every run with its source, destination and the location of each end), pack list (with rack U, in/out, watts and location), jack schedule, connector utilization |
| Locations | what is where, jacks and runs counted per location and grouped by mounting surface, runs per cable label, the screen and shade runs, and the floor plan's callouts |
| Racks | how full and how hot each frame is, and what sits on which U |
| Cost Estimate | equipment, other items, fees, tax, total |

Every sheet is dealt from the same section builders the single-sheet exports
use, so a figure cannot differ between the two buttons. The diagram image can
only be captured from the page on screen, so the export visits each drawing tab
in turn and puts you back where you were.

### One tab at a time

Beside the workbook button is the **download icon**: the tab you are on, on its
own, as a **spreadsheet (.xlsx)**, as **plain text (.txt)**, or **copied to the
clipboard**. Same tables, same builders — the electrician gets the run
schedule, purchasing gets the estimate, and neither has to be sent the other
four sheets. The .xlsx carries that tab's own drawing when it is a drawing tab.
The Catalog exports with no room loaded, since it is the app's price list
rather than a room document.

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
