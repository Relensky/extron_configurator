# Catalog import tools

`av_devices.json` — the device catalog the AV Flow, rack, power and cost
features all read — is generated from the Extron Visio engineering stencils in
`drawings_library/`. These two scripts are how, so a refreshed stencil pack can
be re-imported instead of re-typed.

```bash
python tools/read_drawing_stencils.py drawings_library extracted.json
python tools/build_device_catalog.py extracted.json av_devices.json DEVICE_CATALOG_IMPORT.md device
```

**`read_drawing_stencils.py`** opens each `.vssx` (a zip of Visio XML) and, per
master shape, reads the Shape Data (model, part number, make, description) and
the connectors off the drawing. The drawings follow one convention — inputs
down the left edge, outputs down the right, each connector a label with its
connector type underneath and its port number outside — which is what makes
the port direction readable. Connectors nested in Visio groups are positioned
in the group's own coordinate system, so the reader walks the shape tree and
accumulates the offsets; reading `PinX` flat gives every connector in a group
the same position and loses most of them.

**`build_device_catalog.py`** adds the power inlet each entry carries, keeps
the rack heights the app's built-in table already knew (the drawings do not
record size), and writes `DEVICE_CATALOG_IMPORT.md` — including which imported
models have no Python control module.

`test/catalog_import_test.dart` guards the result: every entry parses, every
powered device has exactly one inlet, inputs are on the left and outputs on
the right, port ids are unique, and nothing has been given an invented price
or wattage.

## What the drawings do not carry

Rack units, power draw, heat output and price are not in the stencils. They
are left at 0, meaning "not recorded", and the reports count what is missing
rather than treating a blank as zero. Fill them in on the **Catalog** tab, or
import them:

```bash
python tools/import_price_list.py "Extron price list.pdf" av_devices.json
python tools/scrape_extron_web.py --profile <firefox profile> --urls product_urls.json --out scraped.jsonl
python tools/import_extron_web.py scraped.jsonl av_devices.json --fill-msrp --report import.txt
```

**`import_price_list.py`** turns a published price list (PDF or CSV) into MSRP.

**`scrape_extron_web.py`** reads extron.com product pages for the things a
price list does not carry: the **education contract price**, the published
**thermal dissipation**, and the product page's own URL. Two things make it
awkward, and both are inherent rather than fixable:

* extron.com rejects scripted HTTP clients — `requests` and headless browsers
  get a bot-defense page — so it drives a real Firefox through Selenium
  (`pip install selenium`). One page at a time, ~6s each; ~1800 pages is about
  three hours. It is somebody else's website.
* Education pricing is only visible to a signed-in School & University
  account. **Sign in by hand once** in the profile passed to `--profile`; the
  script never touches credentials. Get the URL list from
  `https://www.extron.com/sitemap.xml` — model-name slugs cannot be guessed,
  since variants share a page.

**`import_extron_web.py`** lands the crawl in the catalog, matching on part
number and requiring the model name to agree before it writes anything.
Existing MSRP is left alone (it carries the price list's date); `--fill-msrp`
fills entries that have none. Everything it declines to match is listed in the
report.

## Projectors

The projectors need a different source: Extron's drawings do not carry their
power draw, and Panasonic and Epson publish it per model with no list.
`projectorcentral.com` has one page per model with the draw and the end of
production on it, and unlike extron.com it takes a plain HTTP client.

```bash
python tools/match_projectorcentral.py av_devices.json --out pc_matched.json --sitemap pc_urls.json
python tools/scrape_projectorcentral.py --matched pc_matched.json --out pc_scraped.jsonl
python tools/import_projectorcentral.py pc_scraped.jsonl av_devices.json --report pc_report.txt
```

Matching is the hard part and is deliberately its own step, written to a file
somebody can read before it becomes wattages: one projector is sold as
`PT-EW540` here, `pt-ew540u` in the US and `pt-ew540ul` without a lens, and
Epson's `EB-G7100` is the US `Pro G7100`. Every row records whether it matched
**exact**, by **region** letter, or by market **alias**, and the import lists
the inexact ones. Regional variants really do differ — the US BrightLink 685Wi
draws 373 W and the European EB-685Wi 354 W — so an inexact match is the right
projector, not guaranteed the right market's figure. `--exact-only` writes
nothing but exact matches.

Retirement comes off the page's **Status**: `Discontinued <month>` sets
`retired` and appends the end-of-production month to the entry's notes. The
import only ever *sets* that flag — something retired by hand stays retired,
because the reason may be local (off contract, not stocked) rather than the
manufacturer's.

## What is in the rooms nobody has drawn

The refresh plan carries most of the estate as **line items**: a room name, a
date, a life and a figure off the master sheet, with no config file behind
them. That is enough to budget a room and not enough to say what is in it — the
room type on the line ("2 Projector") is what the sheet priced it against, not
an inventory.

The GVE control system has been polled for every room it manages, and that poll
is one. `import_gve_equipment.py` joins the two:

```bash
python tools/import_gve_equipment.py path/to/GveSystemData.json "RYG campus"
python tools/import_gve_equipment.py path/to/GveSystemData.json --dry-run
```

It writes an `equipment` list onto each line item — model, what the box does,
how many — and prints what it could and could not join. It is **idempotent**:
re-running replaces each list rather than appending, and a room that has left
the poll loses its stale one.

**It never touches `replacementCost`.** That figure is a refresh — new gear,
cabling, labor — and the survey is what is installed today, most of it a decade
old. The app shows both and says which is which.

**Prices are not written.** Each line carries the model and the ROLE it plays,
in the base-cost card's own words, and the app prices the model off the catalog
first and the role off the card second — so a change of pricing tier or a
corrected card reaches these rooms with no re-import. A role the card has no
honest line for (a document camera, a VCR) is left blank and reports as
unpriced rather than costed at a category it merely resembles.

**Every re-run reports what it changed.** Two sections at the end: the places
the MODEL overruled the device type the poll filed a box under, and every line
that differs from what is already on the plan. The poll files twenty-three
Da-Lite screen controllers as 'Controller', which would price a relay box at a
control processor's figure and put a processor in twenty-three rooms that have
not got one; where the catalog identifies the model and files it under a
category that names a role, the catalog wins and the disagreement is printed.
Catalog categories that are product FAMILIES - 'Control Systems', 'DTP
Systems' - never overrule a device type, because they say what aisle a part
was imported from rather than what it does.

**Room names are matched exactly**, with three documented exceptions: a poll
that names a divisible hall for both halves (`FAEC 111 117`), a plan name
that slashes a pair (`SCI 126a/b`), and a lettered half the poll knows only by
its base number (`CLSA 100A` against `CLSA 100`). Each of those writes the poll
it read into the line's notes, marked shared, so nobody adds the halves
together.

`test/manual_room_equipment_test.dart` reads the result back: every line parses,
every surveyed box has a model and a positive quantity, and a line item with
eleven surveyed boxes is still one thing falling due on the plan.
