# The Beginner's Guide to Room Config
Your first week with the Room Config Builder
Nothing here needs code, and nothing here needs you to touch a JSON file.
---

# Read this first

Welcome. If you have been handed this app and a room to set up, this is the
short version: the twenty pages that get you from a blank screen to a room that
is drawn, priced and deployed.

The full manual is *Room Config Builder - Operation guide*. It answers
everything. This one answers the things you hit in the first week, in the order
you hit them.

> **You are never stuck.** Press **F1** anywhere in the app and a searchable
> list of every feature opens over whatever you were doing. Type the word off
> the button that confused you - "vendor", "spares", "lead time", "who installs
> it" - and it will find the page for it. Closing it puts you back exactly
> where you were.

## The one idea worth having

You describe the room **once**. Everything else draws itself.

Type in what the room has - a projector, two displays, a switcher, a camera -
and the app writes the processor's `config.json` **and** draws the control
schematic, the signal flow, the rack elevation and the cable schedule, **and**
prices the whole thing off your catalog.

So when something looks wrong on a drawing, the fix is almost never on the
drawing. It is in the room's description, or in one of the rule files that says
how a room turns into a picture. Change it there and every drawing follows.

# Step 1: The "one folder" rule

The easiest way to break things is to have files scattered everywhere. Before
you do anything else, put all of these in **one folder**:

| File or folder | What it is |
|---|---|
| `config.json` | The template a new room starts from |
| `ui_schema.json` | Tells the app how each setting should look on screen |
| `key_map.json` | Translates settings from older config files |
| `buildings.json` | Your building names and their codes |
| `processors.json` | The rooms you can deploy to, with their IP addresses |
| `av_devices.json` | The equipment catalog: connectors, sizes, prices |
| `av_flow_rules.json` | How a room turns itself into a drawing |
| `base_costs.json` | A typical price per kind of device, for early budgets |
| `labor_rates.json` | What an hour of each role costs |
| `devices\` | A folder holding the Python control modules |
| `documentation\` | PDF manuals, which the app can show you in-app |

Anything not there simply isn't used - nothing breaks because a file is
missing. But the more of them the folder has, the less you will have to type.

> **Ask where the shared copy is before you make your own.** `av_devices.json`,
> `ui_schema.json` and `av_flow_rules.json` describe how your shop works, not
> how your laptop is set up. If your team keeps them on a network drive, point
> at that - it is how two people drawing the same room draw it the same way.

# Step 2: Opening the app for the first time

A setup screen pops up. Don't panic.

1. Click **Browse** next to Root Folder.
2. Select the single folder you made in Step 1.
3. Almost everything else should turn **green (Found)**, because the app looked
   for them all in that one spot.
4. Click **Finish Setup**.

That's the hard part over. You can change any of it later from the **App
Config** tab.

## While you are in App Config

Two things there are worth setting now, because they quietly affect every
number you will see:

- **Pricing tier.** Every price in the app is published at two: list (MSRP) and
  the education / institutional price. Pick the one your department buys at.
- **Theme and text size.** Entirely up to you. The app checks its own colours
  for readability whichever you choose.

# Step 3: What you are actually looking at

The tabs run down the left. There are a lot of them, and you will use four in
your first week.

| Tab | Why you'd go there |
|---|---|
| **Project** | The whole building. Which rooms are on the job, what it all costs, who you're buying from. |
| **Cost** | What the room you're in comes to. |
| **Wizard** | Say what the room *has*. This is where a new room starts. |
| **Devices** | Fill in each device: model, IP address, how it's connected. |

The rest - Schematic, AV Flow, Floor Plan, Cabling, Racks - are **drawings the
app makes for you**. You don't fill them in; you look at them and correct the
room if they're wrong.

**Catalog**, **Schema** and **Flow Rules** are settings for the whole app rather
than for one room. Leave them alone until something is wrong that they explain.

> The rail always fits the window. Make the window small and the labels come
> off, leaving icons you can hover. You should never have to scroll it.

# Step 4: A room, start to finish

Here is the whole loop. It is shorter than it looks.

1. **New Config** - or open an existing room's `config.json`.
2. **Wizard tab.** Set the building, the room number and the room name. Then
   set how many of each kind of device the room has.
3. **Devices tab.** One sub-tab has appeared per device. Fill each one in: the
   model, its IP address, how it connects.
4. **System tab.** Which source is plugged into which switcher input, and which
   display hangs off which output.
5. **Look at the drawings.** Schematic and AV Flow have drawn themselves from
   what you just typed. If something is missing, it is nearly always a blank
   number on the System tab.
6. **Cost tab.** The estimate is already there, built from the boxes on the
   drawing.
7. **Save**, and **Send** to push the config to the processor.

## Adding devices - no code required

Never type out code to add a projector or a camera.

- Go to the **Wizard** tab.
- Find the category you want ("Projectors", "Cameras").
- Change the number to how many the room actually has - `0` to `2`.
- New tabs appear for those devices, with sensible defaults already filled in.

Take one away the same way. The app removes the block rather than leaving a
half-configured device behind in the file.

# Step 5: Cheat sheet for the confusing settings

Click a device tab - "Projector 1" - and you get a list of settings. Here is
what the tricky ones actually mean.

## IP Address / Host

**What it is:** the network address of the device.

**What to do:** type the IP address, like `192.168.1.50`. If the device is
connected by a **serial cable** straight to the main processor, type
`processor1` instead.

## Protocol

**What it is:** the language the device uses to talk over the network.

**What to do:** pick from the dropdown. Usually **TCP**, **SSH** or **UDP**.

## Keep Alive Command

**What it is:** a "poke" the app sends every so often so the device doesn't fall
asleep and drop the connection.

**What to do:** pick **Power** or **Input**. The app works out which commands
are available by reading your Python module files, so the list is already right.

## Input

**What it is:** which plug the device should switch to.

**What to do:** pick from the list - `HDMI 1`, `HDBaseT`, and so on.

## Module

**What it is:** the Python file that actually drives this device.

**What to do:** pick the one that matches the model. If nothing in the list
claims your model, that's fine - specify it anyway. The app will keep reminding
you the driver is missing, which is the point: nobody should find out on site.

## Install date

**What it is:** the day this unit went in.

**What to do:** fill it in if you know it. It costs you five seconds and it is
what the refresh plan is built out of - the year a room comes round again is
worked out from this and nothing else.

# Step 6: When a drawing looks wrong

The drawings are made from the room, so the fix is in the room. In rough order
of likelihood:

| What you see | What it usually is |
|---|---|
| A device is missing from the drawing | Its count on the Wizard is still 0, or its config block was never filled in. |
| A lead is missing | A blank input or output number on the **System** tab. Press **Draw the routing from config** and read the reason it gives. |
| A box that costs nothing | Its model isn't in the catalog. The Cost tab counts these for you so you know how much of the estimate is guesswork. |
| A field showing a raw key name in a plain text box | Nothing in `ui_schema.json` describes it. See the last chapter. |
| A drawing that no longer matches the room | Press **Recreate from config** on that tab. |

None of these are errors you have caused. A drawing that says something is
missing is doing its job.

# Step 7: A building, not just a room

Once you have a few rooms, the **Project** tab is where the actual work
happens. You don't have to understand all of it on day one, but it helps to
know what is there.

- **Rooms** - which configs are on the job, and what each comes to. Rooms nobody
  has drawn can be typed in as line items.
- **Equipment** - every part on the whole job **once**, quantities added up
  across rooms. Nine rooms with two transmitters each is eighteen transmitters
  on one line, which is what a vendor can actually quote.
- **Vendors** - the companies you buy from. Give each one the manufacturers and
  categories it sells and the parts tag themselves. Use **Pick from the job**
  rather than typing: the rules match exactly, so "Extron Electronics" against a
  catalog that says "Extron" quietly claims nothing.
- **Timeline** - when each part has to be *bought*, worked back from the day the
  building has to be finished.
- **Deliveries** - the purchase orders and what has turned up.
- **Lifecycle** - what the building already has and which year it falls due.
- **Responsibility** - who furnishes and who installs each line of scope. The
  document that settles "we thought *you* were pulling that conduit".

**The room picker is in the title bar**, on every tab. Pick a room, or step
through them with the arrows, and the editor loads it - the config, the drawing,
the racks, the estimate. Sitting on the Cost tab and stepping through eight
rooms is a perfectly ordinary thing to do.

> **Your edits count straight away, but they aren't saved yet.** Type a price
> and the building total moves. The room's *file* hasn't changed until you press
> **Save room** in the title bar - and the app tells you, in two places, when
> that is outstanding.

# Step 8: Getting the work out

Nearly every screen hands you something, in one of two shapes:

- a **spreadsheet**, for the people who work from it - a contractor prices a
  total, and a price gets typed into a spreadsheet
- a **picture**, for the people who only have to see it - a submittal, a slide,
  an email to a dean

The ones you will reach for first:

- **Save All** writes the whole room into one folder: every drawing as a PNG,
  every report, the workbook, and the config.
- **Workbook** (Project tab) is one spreadsheet with everything about the
  building.
- **Quote requests** writes one spreadsheet **per vendor**, into a folder you
  pick. That is the file you email. It has that vendor's parts and nothing else
  - no labor, no tax, no other vendor's pricing.
- **Screenshot & annotate** grabs the tab you're on and lets you draw on it, for
  the email that starts "the third output is wrong".

> Send a vendor the whole workbook instead of their own quote request and you
> have sent a supplier your margins and a competitor's prices. Use the right
> button.

# Need to change how a setting looks?

If a setting needs a new dropdown option, a better description, or a name your
team actually uses, you don't need a programmer.

The friendly way is the **Schema** tab, which is an editor for exactly this. Its
**Coverage** list shows every key in your config and whether anything describes
it; press **Describe** on one and fill in the label, the help text and what kind
of control it should be.

The other way is to open `ui_schema.json` in a text editor, change the text, and
press **Reload Schema** on the App Config tab. Both do the same thing.

The same is true for the drawings: if the app puts the wrong receiver in a run
or doesn't recognise a kind of source you use, that's a **rule**, and the **Flow
Rules** tab is where you change it. It is not a phone call and a wait for the
next build.

# Where to go next

- Press **F1**. Everything in the app is in there, searchable, and it is always
  current.
- Read *Room Config Builder - Operation guide* for the full version of anything
  here.
- The chapters in that guide worth reading early are **A room, start to
  finish**, **The job**, and **When something looks wrong**.
