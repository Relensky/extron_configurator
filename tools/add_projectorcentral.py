"""Adds classroom projectors from a projectorcentral.com crawl to
av_devices.json as new catalog entries.

    python tools/add_projectorcentral.py pc_scraped.jsonl av_devices.json \
        --brands epson,panasonic,nec,sharp,sony --year 2026 \
        [--classroom-list classroom.json] [--report report.txt] [--dry-run]

WHICH PAGES
-----------
A page is added when the projector is still in production (its Status is
not Discontinued), is a classroom projector, and is not already in the
catalog. Classroom means the page's "Best Used For" carries the site's
education mark, or the page came off the site's Classroom filter
(--classroom-list, a JSON list of {url}). Of those, every one from --brands
is added; from any other maker, only those released in --year.

ALREADY IN THE CATALOG
----------------------
A page is skipped when a catalog entry already points at it, when the
catalog names the same model (match_projectorcentral.find, which knows the
market letters and Epson's EB- / CB- / PowerLite names), or when the page's
"also sold as" name is a catalog model. Existing entries are left to
import_projectorcentral.py.

WHAT AN ENTRY GETS
------------------
Everything import_projectorcentral.py writes - throw ratio, lumens, power,
resolution, lens shift and the rest - plus the page's list price as MSRP and
connectors read off its connection panel. No part number: the page has none,
and one is not made up. A model sold without a lens gets no throw ratio or
zoom, as in the import.
"""
import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(__file__))
from import_projectorcentral import (  # noqa: E402
    SPEC_FIELDS, lens_not_included, read_crawl)
from match_projectorcentral import (  # noqa: E402
    alias_keys, build_index, find, flat)

BRAND_NAMES = {"nec": "NEC", "sharp_nec": "Sharp NEC"}


def slug_brand(url):
    return url.rsplit("/", 1)[1].split("-", 1)[0].lower()


def maker_and_model(row):
    """('Epson', 'PowerLite L630U') off the page title and its URL."""
    brand = slug_brand(row["url"])
    words = row.get("title", "").split()
    n = len(brand.split("_"))
    maker = BRAND_NAMES.get(brand) or " ".join(words[:n])
    return maker, " ".join(words[n:]).strip()


def panasonic_key(model):
    """One Panasonic projector however its market and finish are spelled:
    the catalog's PT-VMZ72U8 and the page's PT-VMZ72WU, or PT-MZ682BU8 and
    PT-MZ682-BU. U with a market digit is the US model; W is the white
    finish, which a bare U also means."""
    f = flat(model)
    f = re.sub(r"u[0-9g]?$", "", f)
    return re.sub(r"(?<=[0-9lk])w$", "", f)


def released_year(row):
    m = re.search(r"(\d{4})", row.get("released", ""))
    return int(m.group(1)) if m else None


def count_of(text):
    m = re.search(r"x\s*(\d+)", text)
    return int(m.group(1)) if m else 1


def ports_of(connections):
    """Catalog ports off the connection panel: inputs on the left, outputs
    on the right, network both ways, one power inlet. A connector there is
    more than one of is numbered: HDMI 1, HDMI 2."""
    found = []  # (direction, id, label, signal)

    def add(direction, pid, label, signal, n=1):
        found.extend([(direction, pid, label, signal)] * n)

    for c in connections:
        low = c.lower()
        n = count_of(low)
        is_out = re.search(r"\bout\b|monitor", low) is not None
        if "hdbaset" in low:
            add("input", "hdbaset", "HDBaseT", "hdbaset")
        elif "hdmi" in low:
            if is_out:
                add("output", "hdmi_out", "HDMI OUT", "hdmi", n)
            else:
                add("input", "hdmi", "HDMI", "hdmi", n)
        elif "displayport" in low:
            add("input", "displayport", "DisplayPort", "displayPort", n)
        elif "sdi" in low:
            add("output" if is_out else "input", "sdi", "SDI", "sdi", n)
        elif any(k in low for k in ("vga", "computer", "d-sub", "dsub")):
            if is_out:
                add("output", "vga_out", "MONITOR OUT", "vga", n)
            else:
                add("input", "vga", "COMPUTER", "vga", n)
        elif "audio" in low:
            if is_out:
                add("output", "audio_out", "AUDIO OUT", "analogAudio", n)
            else:
                add("input", "audio_in", "AUDIO IN", "analogAudio", n)
        elif any(k in low for k in ("network", "lan", "rj-45", "ethernet")):
            add("bidirectional", "lan", "LAN", "network")
        elif any(k in low for k in ("rs232", "rs-232", "serial")):
            add("input", "rs232", "RS-232", "serial")
        elif "usb" in low:
            add("input", "usb", "USB", "usbData")
        elif "dvi" in low:
            add("input", "dvi", "DVI-D", "other", n)
        elif "trigger" in low:
            add("output", "trigger", "TRIGGER", "other")
        elif any(k in low for k in ("composite", "s-video", "component")):
            add("input", "video", "VIDEO", "other")
        # Wireless, speakers and the like have no cable to draw.

    # One network jack, however the page lists it.
    seen_lan = False
    kept = []
    for f in found:
        if f[1] == "lan":
            if seen_lan:
                continue
            seen_lan = True
        kept.append(f)
    totals = Counter(f[1] for f in kept)
    numbered = Counter()
    ports = []
    for direction, pid, label, signal in sorted(
            kept, key=lambda f: f[0] == "output"):
        if totals[pid] > 1:
            numbered[pid] += 1
            pid, label = f"{pid}_{numbered[pid]}", f"{label} {numbered[pid]}"
        ports.append({"id": pid, "label": label, "signal": signal,
                      "direction": direction,
                      "side": "right" if direction == "output" else "left"})
    ports.append({"id": "in_power", "label": "POWER", "signal": "power",
                  "direction": "input", "side": "bottom"})
    return ports


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("crawl")
    ap.add_argument("catalog")
    ap.add_argument("--brands", default="epson,panasonic,nec,sharp,sony")
    ap.add_argument("--year", type=int, default=2026)
    ap.add_argument("--classroom-list")
    ap.add_argument("--report")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    brands = {b.strip().lower() for b in a.brands.split(",") if b.strip()}
    classroom = set()
    if a.classroom_list:
        classroom = {r["url"].lower()
                     for r in json.load(open(a.classroom_list,
                                             encoding="utf-8"))}

    cat = json.load(open(a.catalog, encoding="utf-8"))
    projectors = [d for d in cat["devices"] if d.get("category") == "Projector"]
    models = {flat(d["model"]) for d in cat["devices"]}
    panasonic = {panasonic_key(d["model"]) for d in projectors
                 if d["manufacturer"].lower() == "panasonic"}
    crawl = [r for r in read_crawl(a.crawl) if not r.get("error")]

    # Which pages the catalog already has.
    index = build_index([r["url"] for r in crawl])
    have = {(d.get("url") or "").lower() for d in projectors}
    for d in projectors:
        url, _ = find(index, d["manufacturer"], d["model"])
        if url:
            have.add(url.lower())

    notes = defaultdict(list)
    added = []
    for row in sorted(crawl, key=lambda r: r["url"]):
        url = row["url"]
        maker, model = maker_and_model(row)
        name = f"{maker} {model}"
        status = (row.get("status") or "").strip()
        if not model:
            continue
        if status.lower().startswith("discontinued"):
            continue
        if not (row.get("education") or url.lower() in classroom):
            continue
        brand = slug_brand(url)
        if brand not in brands and released_year(row) != a.year:
            continue
        also = re.search(r"Also sold as the\s+(.*?)\s+outside",
                         row.get("alsoSoldAs", ""))
        also_model = also.group(1).split(" ", 1)[-1] if also else ""
        # Epson's EB- page for a PowerLite the catalog has, and the like.
        aliases = {flat(model), *alias_keys(model)}
        if also_model:
            aliases |= {flat(also_model), *alias_keys(also_model)}
        same_panasonic = (maker.lower() == "panasonic"
                          and panasonic_key(model) in panasonic)
        if url.lower() in have or aliases & models or same_panasonic:
            notes["already in the catalog"].append(name)
            continue

        dev = {"model": model, "manufacturer": maker, "partNumber": "",
               "category": "Projector", "rackUnits": 0}
        if row.get("msrp"):
            dev["price"] = row["msrp"]
        no_lens = lens_not_included(dev)
        lo, hi = row.get("throwRatioMin"), row.get("throwRatioMax")
        if lo and not no_lens:
            dev["throwRatioMin"] = lo
            if hi and hi > lo:
                dev["throwRatioMax"] = hi
        if row.get("lumens"):
            dev["lumens"] = row["lumens"]
        for key in SPEC_FIELDS:
            value = row.get(key)
            if value in (None, "") or (key == "zoomRatio" and no_lens):
                continue
            dev[key] = value
        said = [f"Released {row['released']}." if row.get("released") else
                "", f"{status}." if status and status != "Shipping" else "",
                f"Also sold as {also.group(1)} outside the USA." if also
                else ""]
        dev["notes"] = " ".join(s for s in said if s)
        dev["ports"] = ports_of(row.get("connections", []))
        if row.get("watts"):
            dev["powerWatts"] = row["watts"]
        dev["url"] = url
        if not row.get("connections"):
            notes["no connection panel, ports left to the inlet"].append(name)
        added.append(dev)
        models.add(flat(model))
        if maker.lower() == "panasonic":
            panasonic.add(panasonic_key(model))
        notes[f"added ({maker})"].append(
            f"{model}  {row.get('released', '')}  {status}")

    by_maker = Counter(d["manufacturer"] for d in added)
    lines = [f"crawl: {len(crawl)} pages", f"added: {len(added)}",
             "  " + ", ".join(f"{k} {v}" for k, v in by_maker.most_common()),
             ""]
    for heading, items in sorted(notes.items()):
        lines.append(f"--- {heading} ({len(items)}) ---")
        lines += [f"  {i}" for i in items]
        lines.append("")
    report = "\n".join(lines)
    print(report[:4000])
    if a.report:
        open(a.report, "w", encoding="utf-8").write(report)
    if a.dry_run:
        print("(dry run: catalog not written)")
        return

    cat["devices"].extend(added)
    cat.setdefault("__pricing", {})["projectorsAdded"] = {
        "source": "projectorcentral.com classroom projectors",
        "added": len(added),
    }
    with open(a.catalog, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(cat, indent=2, ensure_ascii=False))
    print(f"wrote {a.catalog}")


if __name__ == "__main__":
    main()
