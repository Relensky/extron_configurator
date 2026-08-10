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
    return out


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
