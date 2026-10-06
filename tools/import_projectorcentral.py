"""Fills projector power draw and end-of-production into av_devices.json from
a projectorcentral.com crawl.

    python tools/import_projectorcentral.py pc_scraped.jsonl av_devices.json \
        [--report report.txt] [--exact-only] [--dry-run]

WHAT IT WRITES
--------------
  powerWatts  the page's Power figure. The projectors came out of the Extron
              drawings with no wattage at all, and a projector is the biggest
              single load in most of these rooms — leaving it at 0 makes every
              circuit and cooling total short by the one device that matters.
  retired     true when the page says Discontinued. This only ever SETS the
              flag: an entry somebody retired by hand is left retired even if
              the page still says Shipping, because the reason may be local
              (off contract, not stocked) and is not this script's to overrule.
  url         the page the two figures came off.
  notes       the end-of-production month, appended, since the catalog has
              nowhere else to put a date.

MATCH KINDS, AND WHY THEY ARE IN THE FILE
-----------------------------------------
A projector is sold under different names per market, and the catalog and the
website rarely spell one the same way:

  exact   the names agree
  region  same model, different market/finish letter (PT-EW540 / pt-ew540u)
  alias   Epson's other market names for one projector — EB- (Europe), CB-
          (Asia), PowerLite / Pro / BrightLink (US)

All three are written by default, because they are the same projector. They
are NOT equally certain, so every inexact one is listed in the report, and
--exact-only writes nothing else. Worth knowing before trusting them wholesale:
regional variants really can differ — the US BrightLink 685Wi draws 373 W and
the European EB-685Wi 354 W — so a region or alias match is the right
projector, not necessarily the right market's figure.
"""
import argparse
import json
import re
from collections import defaultdict


# Panasonic marks a lens-less model with an L before the color and market
# letters: PT-REZ10LBU8, PT-MZ11KLWU8, PT-SLW65CL.
PANASONIC_NO_LENS = re.compile(r"^PT-[A-Z]+\d+[A-Z]*?L[BW]?(U[78G]?)?$", re.I)


def lens_not_included(dev):
    text = f"{dev.get('model', '')} {dev.get('notes', '')}".lower()
    if re.search(r"lens (not included|sold separately)|without (a )?lens",
                 text):
        return True
    return (dev.get("manufacturer", "").lower() == "panasonic"
            and bool(PANASONIC_NO_LENS.match(dev.get("model", "").strip())))


def put(dev, key, value):
    """Sets [key] where the app writes it, ahead of the notes and ports, so
    the app's next save does not move it."""
    if key in dev:
        dev[key] = value
        return
    items = list(dev.items())
    at = next((i for i, (k, _) in enumerate(items)
               if k in ("notes", "ports", "addedBy", "addedAt",
                        "changedBy", "changedAt")), len(items))
    items.insert(at, (key, value))
    dev.clear()
    dev.update(items)


def read_crawl(path):
    rows = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("crawl")
    ap.add_argument("catalog")
    ap.add_argument("--report")
    ap.add_argument("--exact-only", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--projection-only", action="store_true",
                    help="write throw ratio and lumens only")
    a = ap.parse_args()

    crawl = read_crawl(a.crawl)
    by_model = {r["model"]: r for r in crawl}

    cat = json.load(open(a.catalog, encoding="utf-8"))
    stats = defaultdict(int)
    notes = defaultdict(list)

    for dev in cat["devices"]:
        if dev.get("category") != "Projector":
            continue
        stats["projectors"] += 1
        row = by_model.get(dev["model"])
        if not row:
            stats["noPage"] += 1
            notes["no page on projectorcentral.com"].append(
                f"{dev['manufacturer']} {dev['model']}")
            continue
        if row.get("error"):
            stats["fetchFailed"] += 1
            notes["page failed to fetch"].append(
                f"{dev['manufacturer']} {dev['model']}  {row['error']}")
            continue
        if a.exact_only and row.get("match") != "exact":
            stats["skippedInexact"] += 1
            notes["skipped, not an exact name match"].append(
                f"{dev['manufacturer']} {dev['model']}  ->  {row['url']}")
            continue

        # Throw ratio and brightness, for the projection calculator. Only
        # filled where the catalog has none, like the watts. A projector sold
        # without a lens gets no throw ratio: the page's figure is for a lens
        # that is not in the box, and the lens on the estimate supplies it.
        lo, hi = row.get("throwRatioMin"), row.get("throwRatioMax")
        if lo and not dev.get("throwRatioMin"):
            if lens_not_included(dev):
                notes["sold without a lens, throw ratio left blank"].append(
                    f"{dev['model']}  (page says {lo}-{hi}:1)")
            else:
                put(dev, "throwRatioMin", lo)
                if hi and hi > lo:
                    put(dev, "throwRatioMax", hi)
                stats["throwWritten"] += 1
        elif not lo:
            notes["no throw ratio published"].append(dev["model"])
        lumens = row.get("lumens")
        if lumens and not dev.get("lumens"):
            put(dev, "lumens", lumens)
            stats["lumensWritten"] += 1

        # --projection-only fills those two and leaves everything else.
        if a.projection_only:
            continue

        if row.get("match") != "exact":
            notes[f"matched by {row['match']} — same projector, "
                  f"check the market"].append(
                f"{dev['manufacturer']} {dev['model']}  ->  {row['url']}"
                f"  ({row.get('watts')} W)")

        watts = row.get("watts")
        if watts:
            if not dev.get("powerWatts"):
                stats["wattsWritten"] += 1
            elif abs(dev["powerWatts"] - watts) > 0.5:
                notes["watts already recorded, left alone"].append(
                    f"{dev['model']}  catalog {dev['powerWatts']}  "
                    f"web {watts}")
                watts = None
            if watts:
                dev["powerWatts"] = watts
        else:
            notes["no power figure published"].append(dev["model"])

        status = (row.get("status") or "").strip()
        when = (row.get("statusDate") or "").strip()
        if status.lower().startswith("discontinued"):
            if not dev.get("retired"):
                dev["retired"] = True
                stats["retired"] += 1
            if when:
                stamp = f"End of production {when} (projectorcentral.com)."
                existing = dev.get("notes", "")
                if "End of production" not in existing:
                    dev["notes"] = (existing + " " + stamp).strip()
        else:
            stats["stillShipping"] += 1
            if dev.get("retired"):
                notes["retired here but still shipping on the web"].append(
                    f"{dev['model']}  ({status})")

        if row.get("url"):
            dev["url"] = row["url"]
            stats["urlWritten"] += 1

    lines = [
        f"crawl: {len(crawl)} pages",
        f"projectors in catalog:     {stats['projectors']}",
        f"  watts written:           {stats['wattsWritten']}",
        f"  newly marked retired:    {stats['retired']}",
        f"  still shipping:          {stats['stillShipping']}",
        f"  product page written:    {stats['urlWritten']}",
        f"  throw ratio written:     {stats['throwWritten']}",
        f"  lumens written:          {stats['lumensWritten']}",
        "",
        f"  no page on the site:     {stats['noPage']}",
        f"  fetch failed:            {stats['fetchFailed']}",
        f"  skipped as inexact:      {stats['skippedInexact']}",
        "",
    ]
    for heading, items in sorted(notes.items()):
        lines.append(f"--- {heading} ({len(items)}) ---")
        lines += [f"  {i}" for i in items]
        lines.append("")
    report = "\n".join(lines)
    print(report[:3500])
    if a.report:
        open(a.report, "w", encoding="utf-8").write(report)

    if a.dry_run:
        print("(dry run: catalog not written)")
        return

    if a.projection_only:
        # Written the way the app writes it, so the diff is only the new
        # figures.
        with open(a.catalog, "w", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(cat, indent=2, ensure_ascii=False))
        print(f"wrote {a.catalog}")
        return

    cat.setdefault("__pricing", {})["projectorSpecs"] = {
        "source": "projectorcentral.com spec pages",
        "wattsWritten": stats["wattsWritten"],
        "retiredFromEndOfProduction": stats["retired"],
    }
    with open(a.catalog, "w", encoding="utf-8") as f:
        json.dump(cat, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {a.catalog}")


if __name__ == "__main__":
    main()
