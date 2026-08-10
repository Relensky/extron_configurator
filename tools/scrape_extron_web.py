"""Reads extron.com product pages for education-contract price, MSRP, the
published heat output and the page's own URL, and writes them to a JSONL file
for `import_extron_web.py` to land in av_devices.json.

    python tools/scrape_extron_web.py --profile <dir> --urls product_urls.json \
        [--out scraped.jsonl] [--limit 5] [--url <u> ...] [--catalog av_devices.json]

WHY A BROWSER
-------------
extron.com sits behind a bot defense that rejects scripted HTTP clients
outright — requests, WebFetch and a headless browser all get "The requested URL
was rejected". A real Firefox is not refused, so this drives one through
Selenium. Two consequences worth knowing before running it:

  * The prices are only visible to a signed-in School & University account, so
    --profile must point at a Firefox profile that a PERSON has signed in with.
    Nothing here types or reads a credential; sign in by hand once and the
    profile's cookie carries the session.
  * It is one page at a time with no parallelism. ~1800 pages at ~6s is about
    three hours. That is deliberate: this is somebody else's website.

The product URLs come from https://www.extron.com/sitemap.xml — slugs cannot be
guessed from model names (variants like "AC 102 UK" share one page, and only
about a fifth of the catalog's models have a page of their own).

WHAT COMES OFF A PAGE
  * table.table-price - one row per SKU: model, version description, part
    number, Education Contract price, MSRP. 'Show all part numbers' is clicked
    first because a collapsed page shows only the lead SKU.
  * the #spec tab - 'Thermal dissipation' in BTU/HR and 'Power consumption' in
    watts. Both are published twice for gear with an external supply, as the
    device alone and as device + power supply, so BOTH are kept here and the
    choice is made at import time rather than thrown away now.

Writes one JSON object per page and skips URLs already in the output, so an
interrupted run resumes instead of starting over.
"""
import argparse, json, os, re, sys, time

from selenium import webdriver
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import TimeoutException, WebDriverException

MONEY = re.compile(r"\$\s*([\d,]+(?:\.\d{2})?)")
PART = re.compile(r"\d{2,3}-\d{3,4}-\d{2,3}[A-Z]?")


def flush(*a):
    print(*a)
    sys.stdout.flush()


def money(text):
    m = MONEY.search(text or "")
    return float(m.group(1).replace(",", "")) if m else None


def driver(profile):
    # Without -no-remote a second Firefox hands its command line to the one the
    # user already has open and exits, which Selenium sees as the browser dying
    # on startup.
    os.environ["MOZ_NO_REMOTE"] = "1"
    opts = Options()
    opts.add_argument("-no-remote")
    opts.add_argument("-profile")
    opts.add_argument(profile)
    # Images are the bulk of the page weight and none of the data.
    opts.set_preference("permissions.default.image", 2)
    # The data is in the initial document; waiting on every last subresource
    # roughly doubles the time per page.
    opts.page_load_strategy = "eager"
    d = webdriver.Firefox(options=opts)
    d.set_page_load_timeout(60)
    return d


PRICE_JS = """
var t = document.querySelector('table.table-price');
if (!t) return null;
return Array.from(t.querySelectorAll('tr')).map(
  tr => Array.from(tr.querySelectorAll('th,td')).map(c => (c.innerText||'').trim()));
"""

EXPAND_JS = """
var n = 0;
Array.from(document.querySelectorAll('a,button,span,div')).forEach(function (e) {
  if (e.children.length === 0 && /show all part numbers/i.test(e.textContent || '')) {
    e.click(); n++;
  }
});
return n;
"""

SPEC_JS = """
var a = document.querySelector('a[href="#spec"]');
if (a) a.click();
return !!a;
"""

SPEC_ROWS_JS = """
var el = document.querySelector('#spec');
if (!el) return null;
return Array.from(el.querySelectorAll('tr')).map(
  tr => Array.from(tr.querySelectorAll('th,td')).map(c => (c.innerText||'').trim()));
"""


def parse_price_rows(rows):
    """[{model, description, partNumber, education, msrp}] from the SKU table."""
    if not rows:
        return []
    head, idx = None, {}
    for r in rows:
        flat = [c.lower() for c in r]
        if any("part" in c for c in flat) and any("msrp" in c for c in flat):
            head = r
            for i, c in enumerate(flat):
                if "model" in c:
                    idx["model"] = i
                elif "description" in c:
                    idx["description"] = i
                elif "part" in c:
                    idx["part"] = i
                elif "education" in c or "contract" in c:
                    idx["education"] = i
                elif "msrp" in c:
                    idx["msrp"] = i
            break
    out = []
    for r in rows:
        if r is head or not r:
            continue
        # A data row is one that carries a part number somewhere.
        pcell = next((c for c in r if PART.fullmatch(c.strip())), None)
        if not pcell:
            continue

        def cell(key):
            i = idx.get(key)
            return r[i] if i is not None and i < len(r) else ""

        part = cell("part").strip()
        if not PART.fullmatch(part):
            part = pcell.strip()
        edu, msrp = money(cell("education")), money(cell("msrp"))
        if edu is None and msrp is None:
            # Fall back to positional money order: education column sits left
            # of MSRP on every page seen, so the first two amounts are it.
            amounts = [money(c) for c in r if money(c) is not None]
            if len(amounts) >= 2:
                edu, msrp = amounts[0], amounts[1]
            elif len(amounts) == 1:
                msrp = amounts[0]
        out.append({
            "model": cell("model").strip(),
            "description": cell("description").strip(),
            "partNumber": part,
            "education": edu,
            "msrp": msrp,
        })
    return out


def parse_spec_rows(rows):
    """Heat and power figures, each kept with the label that qualifies it."""
    btu, watts, section = [], [], ""
    for r in rows or []:
        if not r:
            continue
        label = r[0].strip()
        values = [c for c in r[1:] if c.strip()]
        if label and not values:
            section = label
            continue
        for v in values:
            for num in re.findall(r"([\d,]+(?:\.\d+)?)\s*BTU", v, re.I):
                btu.append({"section": section, "label": label,
                            "value": float(num.replace(",", ""))})
            for num in re.findall(r"([\d,]+(?:\.\d+)?)\s*watts?\b", v, re.I):
                watts.append({"section": section, "label": label,
                              "value": float(num.replace(",", ""))})
    return btu, watts


def scrape(d, url):
    rec = {"url": url}
    d.get(url)
    if "404.aspx" in d.current_url:
        rec["error"] = "404"
        return rec
    try:
        WebDriverWait(d, 8).until(
            EC.presence_of_element_located((By.CSS_SELECTOR, "table.table-price")))
    except TimeoutException:
        rec["noPriceTable"] = True

    try:
        if d.execute_script(EXPAND_JS):
            time.sleep(1.2)
    except WebDriverException:
        pass

    rec["skus"] = parse_price_rows(d.execute_script(PRICE_JS))

    try:
        d.execute_script(SPEC_JS)
        time.sleep(0.8)
        rows = d.execute_script(SPEC_ROWS_JS)
    except WebDriverException:
        rows = None
    btu, watts = parse_spec_rows(rows)
    rec["btu"], rec["watts"] = btu, watts
    rec["title"] = d.title
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", required=True,
                    help="Firefox profile directory signed in to extron.com")
    ap.add_argument("--urls", help="JSON list of product URLs (from the sitemap)")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--url", nargs="*")
    ap.add_argument("--out", default="scraped.jsonl")
    # The catalog, so the log can say how much of what we actually need is
    # covered — that is the number that decides when the crawl can stop.
    ap.add_argument("--catalog")
    a = ap.parse_args()
    if not a.url and not a.urls:
        ap.error("give --urls <file> or --url <address> ...")

    targets = set()
    if a.catalog:
        cat = json.load(open(a.catalog, encoding="utf-8"))
        targets = {x["partNumber"].strip() for x in cat["devices"]
                   if x.get("manufacturer") == "Extron" and x.get("partNumber")}

    urls = a.url or json.load(open(a.urls, encoding="utf-8"))
    if a.limit:
        urls = urls[:a.limit]

    done, found = set(), set()
    if os.path.exists(a.out):
        for line in open(a.out, encoding="utf-8"):
            try:
                rec = json.loads(line)
            except Exception:
                continue
            done.add(rec["url"])
            for s in rec.get("skus", []):
                if s.get("education") is not None:
                    found.add(s["partNumber"])
    todo = [u for u in urls if u not in done]
    flush(f"{len(todo)} to fetch ({len(done)} already done)")

    d = driver(a.profile)
    started, ok, bad = time.time(), 0, 0
    try:
        with open(a.out, "a", encoding="utf-8") as f:
            for i, url in enumerate(todo, 1):
                try:
                    rec = scrape(d, url)
                    ok += 1
                except Exception as e:
                    rec = {"url": url, "error": repr(e)[:300]}
                    bad += 1
                f.write(json.dumps(rec) + "\n")
                f.flush()
                for s in rec.get("skus", []):
                    if s.get("education") is not None:
                        found.add(s["partNumber"])
                if i % 25 == 0 or i == len(todo):
                    rate = (time.time() - started) / i
                    hit = len(found & targets) if targets else 0
                    flush(f"[{i}/{len(todo)}] {rate:.1f}s/page  "
                          f"eta {rate * (len(todo) - i) / 60:.0f}m  errors={bad}  "
                          f"catalog parts priced {hit}/{len(targets)}")
    finally:
        d.quit()
    flush(f"done: {ok} pages, {bad} errors")


if __name__ == "__main__":
    main()
