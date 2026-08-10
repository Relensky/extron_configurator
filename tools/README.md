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
rather than treating a blank as zero. Fill them in on the **Catalog** tab.
