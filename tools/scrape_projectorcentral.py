"""Reads projectorcentral.com spec pages for a projector's power draw and
whether it is still in production.

    python tools/scrape_projectorcentral.py --matched pc_matched.json \
        --out pc_scraped.jsonl [--limit 5] [--delay 1.5]

WHY THIS SOURCE
---------------
The projectors in the catalog came off the Extron drawings, which say what a
box IS and nothing about what it draws or whether you can still buy one.
Panasonic and Epson publish both, in a different place and format per model,
and neither publishes a list. projectorcentral.com keeps one page per model
with the two facts this needs in a fixed shape:

    <dl><dd>Power</dd><dt>373 Watts 100V - 240V</dt></dl>
    <dl><dt>Status</dt><dd>Discontinued <label>May 2021</label></dd></dl>

Unlike extron.com there is no bot defense and no sign-in, so this is a plain
HTTP client rather than a browser. robots.txt (checked) allows the spec pages;
the crawl is serial with a delay because a courtesy is a courtesy.

WHAT IT DOES NOT DO
-------------------
It does not decide anything. Matching models to pages happens before this (see
--matched, which carries the match kind), and what to write happens after, in
import_projectorcentral.py. This step only fetches and parses, so a bad match
is visible in a file rather than baked into the catalog.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) "
      "Gecko/20100101 Firefox/128.0")

# <dd>Power</dd> <dt>373 Watts 100V - 240V</dt>
POWER = re.compile(
    r"<dd>\s*Power\s*</dd>\s*<dt[^>]*>\s*([\d,]+(?:\.\d+)?)\s*Watts",
    re.I | re.S)
# <dt>Status</dt> <dd> Discontinued <label>May 2021</label> </dd>
STATUS = re.compile(
    r"<dt>\s*Status\s*</dt>\s*<dd[^>]*>(.*?)</dd>", re.I | re.S)
RELEASED = re.compile(
    r"<dt>\s*Released\s*</dt>\s*<dd[^>]*>(.*?)</dd>", re.I | re.S)


def text(fragment):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", fragment or "")).strip()


def flush(*a):
    print(*a)
    sys.stdout.flush()


def fetch(url, tries=3):
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=45) as r:
                return r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if attempt == tries - 1:
                raise
        except Exception:
            if attempt == tries - 1:
                raise
        time.sleep(3 * (attempt + 1))
    return None


def parse(html):
    """{watts, status, statusDate, released} from a spec page."""
    out = {}
    m = POWER.search(html)
    if m:
        out["watts"] = float(m.group(1).replace(",", ""))

    m = STATUS.search(html)
    if m:
        raw = m.group(1)
        out["status"] = text(raw)
        # The month/year sits in its own <label> inside the status cell.
        date = re.search(r"<label>(.*?)</label>", raw, re.S)
        if date:
            out["statusDate"] = text(date.group(1))

    m = RELEASED.search(html)
    if m:
        out["released"] = text(m.group(1))

    # Throw ratio, brightness and lenses, for the projection calculator.
    specs = spec_rows(html)
    ratio = specs.get("throw ratio", "")
    nums = [float(n) for n in re.findall(r"(\d+(?:\.\d+)?)\s*:\s*1", ratio)]
    if nums:
        out["throwRatioMin"] = min(nums)
        out["throwRatioMax"] = max(nums)
    m = re.search(r"([\d,]+)\s*Lumens", specs.get("white brightness", ""))
    if m:
        out["lumens"] = float(m.group(1).replace(",", ""))
    for key, name in (("optional lenses", "optionalLenses"),
                      ("lens shift", "lensShift")):
        if key in specs:
            out[name] = specs[key]
    out.update(projector_specs(specs))
    out.update(listing(html))
    out["specs"] = specs
    return out


# <h1>Epson PowerLite L630U Projector</h1>
TITLE = re.compile(r"<h1>(.*?)</h1>", re.S)
MSRP = re.compile(r"<dt>\s*MSRP\s*</dt>\s*<dd[^>]*>\s*\$([\d,]+)", re.I | re.S)
USED_FOR = re.compile(
    r"<dt>\s*Best Used For\s*</dt>\s*<dd[^>]*>(.*?)</dd>", re.I | re.S)
GLOBAL = re.compile(r"<dt>\s*Global\s*</dt>\s*<dd[^>]*>(.*?)</dd>", re.I | re.S)
PANEL = re.compile(
    r"<dd>\s*Connection Panel\s*</dd>\s*<dt[^>]*>(.*?)</dt>", re.I | re.S)


def listing(html):
    """What a new catalog entry needs beyond the specs: the page's name for
    the projector, what it is sold for, its list price, its name in other
    markets and its connectors."""
    out = {}
    m = TITLE.search(html)
    if m:
        out["title"] = re.sub(r"\s+Projector$", "", text(m.group(1)))
    m = MSRP.search(html)
    if m:
        out["msrp"] = float(m.group(1).replace(",", ""))
    m = USED_FOR.search(html)
    if m:
        out["usedFor"] = [text(li) for li in
                          re.findall(r"<li>(.*?)(?=<li>|</ul>)", m.group(1),
                                     re.S) if text(li)]
        # The site's own mark for a classroom projector.
        out["education"] = "app-edu-icon" in m.group(1)
    m = GLOBAL.search(html)
    if m:
        out["alsoSoldAs"] = text(m.group(1))
    m = PANEL.search(html)
    if m:
        out["connections"] = [text(d) for d in
                              re.findall(r"<div>(.*?)</div>", m.group(1),
                                         re.S) if text(d)]
    return out


def first_number(s):
    m = re.search(r"(\d[\d,]*(?:\.\d+)?)", s or "")
    return float(m.group(1).replace(",", "")) if m else None


def shift_of(axis_text):
    """(up, down) percents off 'Vertical +/-50%' or '+60% / -0%'."""
    m = re.search(r"(?:\+\s*/\s*-|±)\s*(\d+(?:\.\d+)?)\s*%", axis_text)
    if m:
        v = float(m.group(1))
        return v, v
    up = re.search(r"\+\s*(\d+(?:\.\d+)?)\s*%", axis_text)
    down = re.search(r"-\s*(\d+(?:\.\d+)?)\s*%", axis_text)
    if not up and not down:
        return None
    return (float(up.group(1)) if up else 0.0,
            float(down.group(1)) if down else 0.0)


def projector_specs(specs):
    """The catalog's projector fields off the spec table."""
    out = {}
    m = re.search(r"(\d{3,5})\s*x\s*(\d{3,5})", specs.get("resolution", ""))
    if m:
        out["resolution"] = f"{m.group(1)}x{m.group(2)}"
    m = re.search(r"(\d+(?:\.\d+)?)\s*:\s*(\d+(?:\.\d+)?)",
                  specs.get("aspect ratio", ""))
    if m:
        out["aspectRatio"] = f"{m.group(1)}:{m.group(2)}"
    for key, value in specs.items():
        if "contrast" in key:
            m = re.search(r"([\d,]+)\s*:\s*1", value)
            if m:
                out["contrastRatio"] = f"{m.group(1)}:1"
                break
    source = specs.get("light source", "").strip()
    if source and source.lower() not in ("no", "n/a"):
        out["lightSource"] = source
    life = first_number(specs.get("light source life") or
                        specs.get("lamp life", ""))
    if life:
        out["lightLifeHours"] = life
    m = re.search(r"(\d+(?:\.\d+)?)\s*x\b", specs.get("included lens", ""))
    if m and float(m.group(1)) > 1:
        out["zoomRatio"] = float(m.group(1))
    shift = specs.get("lens shift", "")
    low = shift.lower()
    if low and low not in ("no", "none"):
        cut = {a: low.find(a) for a in ("vertical", "horizontal") if a in low}
        for axis, at in cut.items():
            ends = [p for p in cut.values() if p > at]
            part = shift[at:min(ends) if ends else len(shift)]
            got = shift_of(part)
            if not got:
                continue
            if axis == "vertical":
                out["lensShiftUp"], out["lensShiftDown"] = got
            else:
                out["lensShiftSide"] = max(got)
    m = re.search(r"(\d+(?:\.\d+)?)\s*lbs", specs.get("weight", ""), re.I)
    if m:
        out["weightLbs"] = float(m.group(1))
    m = re.search(r"(\d+(?:\.\d+)?)\s*dB", specs.get("audible noise", ""))
    if m:
        out["noiseDb"] = float(m.group(1))
    return out


# <dl><dd>Throw Ratio</dd><dt>1.37:1 - 2.19:1 <label>(D:W)</label></dt></dl>
SPEC_ROW = re.compile(r"<dl>\s*<dd>(.*?)</dd>\s*<dt[^>]*>(.*?)</dt>", re.S)


def spec_rows(html):
    """Every label: value row in the spec table, labels lowercased."""
    rows = {}
    for k, v in SPEC_ROW.findall(html):
        key = text(k).lower()
        if key:
            rows[key] = text(v).replace("&nbsp;", " ")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--matched", required=True,
                    help="JSON list of {manufacturer, model, url, match}")
    ap.add_argument("--out", default="pc_scraped.jsonl")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--delay", type=float, default=1.5)
    a = ap.parse_args()

    rows = json.load(open(a.matched, encoding="utf-8"))
    if a.limit:
        rows = rows[:a.limit]

    done = set()
    if os.path.exists(a.out):
        for line in open(a.out, encoding="utf-8"):
            try:
                done.add(json.loads(line)["model"])
            except Exception:
                pass
    todo = [r for r in rows if r["model"] not in done]
    flush(f"{len(todo)} to fetch ({len(done)} already done)")

    started, bad = time.time(), 0
    with open(a.out, "a", encoding="utf-8") as f:
        for i, row in enumerate(todo, 1):
            rec = dict(row)
            try:
                html = fetch(row["url"])
                if html is None:
                    rec["error"] = "404"
                    bad += 1
                else:
                    rec.update(parse(html))
            except Exception as e:
                rec["error"] = repr(e)[:200]
                bad += 1
            f.write(json.dumps(rec) + "\n")
            f.flush()
            if i % 20 == 0 or i == len(todo):
                rate = (time.time() - started) / i
                flush(f"[{i}/{len(todo)}] {rate:.1f}s/page  errors={bad}")
            time.sleep(a.delay)
    flush(f"done, {bad} errors")


if __name__ == "__main__":
    main()
