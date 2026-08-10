"""Fills education-contract prices and published heat output into
av_devices.json from a crawl of extron.com product pages.

    python tools/import_extron_web.py scraped.jsonl av_devices.json \
        [--report report.txt] [--fill-msrp] [--dry-run]

WHY THIS EXISTS
---------------
`import_price_list.py` turns a published price list into MSRP. Two things a
price list does not carry are the education contract price a school actually
pays and the heat a box puts into the room, and both are on extron.com — the
first behind a School & University sign-in, the second in the Specifications
tab. This reads a crawl of those pages (see the scraper that writes
scraped.jsonl) and lands both in the catalog.

extron.com refuses automated clients: the crawl has to come from a real signed
-in browser, which is why the fetching and the importing are separate programs.
The crawl is a plain JSONL file, so it can be re-run, inspected, and diffed
without touching the catalog.

MATCHING IS ON PART NUMBER, AND THEN CHECKED
--------------------------------------------
Same rule as import_price_list.py, and for the same reason: a part number that
appears on two entries must not silently write one entry's price onto the
other. A match counts only when the model name on the web page and the model
name in the catalog agree — one being a prefix of the other, which is what
happens when the catalog carries a colour or variant word ("NAV E 201 D White")
that the price table's model column does not. Everything else is left alone
and listed in the report for a person to look at.

WHICH BTU FIGURE
----------------
Extron publishes thermal dissipation twice for gear with an external supply:
the device alone, and the device together with its power supply. The larger,
combined figure is what goes in, because both halves sit in the room being
cooled and the number feeds a cooling load. Where only one figure is published
that one is used.

MSRP
----
Prices already in the catalog are NOT overwritten — they came from a dated
price list and quietly replacing them would lose that provenance. Differences
against the web are listed in the report. `--fill-msrp` fills entries that have
no price at all.
"""
import argparse
import json
import re
import sys
from collections import defaultdict


def flat(s):
    return re.sub(r'[^a-z0-9]', '', (s or '').lower())


def read_crawl(path):
    """(skus by part number, heat by page url) from the crawl."""
    skus, heat = {}, {}
    pages = 0
    for line in open(path, encoding='utf-8'):
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        pages += 1
        url = rec.get('url', '')
        heat[url] = {
            'btu': pick_btu(rec.get('btu') or []),
            'watts': pick_watts(rec.get('watts') or []),
        }
        for s in rec.get('skus') or []:
            part = (s.get('partNumber') or '').strip()
            if not part:
                continue
            # A part number seen twice with the same price is just the same SKU
            # listed on two pages; keep the first priced sighting.
            if part in skus and skus[part].get('education') is not None:
                continue
            skus[part] = dict(s, url=url)
    return skus, heat, pages


def _pick(entries, unit_words):
    """The combined device+supply figure, else the device, else anything."""
    if not entries:
        return None
    both = [e for e in entries if 'power supply' in (e.get('label') or '').lower()
            and 'device' in (e.get('label') or '').lower()]
    if both:
        return both[0]['value']
    dev = [e for e in entries if (e.get('label') or '').strip().lower() == 'device']
    if dev:
        return dev[0]['value']
    named = [e for e in entries
             if any(w in (e.get('label') or '').lower() for w in unit_words)]
    if named:
        return named[0]['value']
    return entries[0]['value']


def pick_btu(entries):
    return _pick(entries, ('thermal', 'dissipation'))


def pick_watts(entries):
    # 'Remote power budget' and the supply's own rating are capacities, not
    # draw, so they must never become the device's consumption.
    usable = [e for e in entries
              if 'budget' not in (e.get('label') or '').lower()
              and 'consumption' in (e.get('section') or '').lower()]
    return _pick(usable, ('consumption',))


def corroborates(catalog_model, web_model, description):
    """True when the web row is plainly the same product as the catalog entry."""
    c, w = flat(catalog_model), flat(web_model)
    if not c or not w:
        return False
    if c == w or c.startswith(w) or w.startswith(c):
        return True
    # Some rows carry the model only in the description column.
    return flat(description).startswith(c)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('crawl')
    ap.add_argument('catalog')
    ap.add_argument('--report')
    ap.add_argument('--fill-msrp', action='store_true')
    ap.add_argument('--dry-run', action='store_true')
    a = ap.parse_args()

    skus, heat, pages = read_crawl(a.crawl)
    cat = json.load(open(a.catalog, encoding='utf-8'))
    devices = cat['devices']

    stats = defaultdict(int)
    notes = defaultdict(list)

    for dev in devices:
        if dev.get('manufacturer') != 'Extron':
            continue
        stats['extron'] += 1
        part = (dev.get('partNumber') or '').strip()
        row = skus.get(part)
        if not row:
            stats['noWebRow'] += 1
            notes['no matching part number on extron.com'].append(
                f"{dev['model']}  ({part or 'no part number'})")
            continue
        if not corroborates(dev['model'], row.get('model'), row.get('description')):
            stats['unconfirmed'] += 1
            notes['part number matched but model name did not'].append(
                f"{dev['model']}  {part}  web says {row.get('model')!r}")
            continue
        stats['matched'] += 1

        edu = row.get('education')
        if edu:
            if dev.get('educationPrice') != edu:
                stats['eduWritten'] += 1
            dev['educationPrice'] = edu
        else:
            stats['noEduPrice'] += 1
            notes['matched but no education price published'].append(
                f"{dev['model']}  {part}")

        msrp = row.get('msrp')
        if msrp:
            have = dev.get('price')
            if not have:
                if a.fill_msrp:
                    dev['price'] = msrp
                    stats['msrpFilled'] += 1
                else:
                    notes['no price in catalog, web has one'].append(
                        f"{dev['model']}  {part}  ${msrp:,.2f}")
            elif abs(have - msrp) > 0.01:
                stats['msrpDiffers'] += 1
                notes['catalog MSRP differs from the web'].append(
                    f"{dev['model']}  {part}  catalog ${have:,.2f}  web ${msrp:,.2f}")

        # The page every figure above was read off, kept on the entry so the
        # next person to doubt a price or a heat figure can open the source
        # rather than search for it.
        page = row.get('url') or ''
        if page:
            dev['url'] = page
            stats['urlWritten'] += 1

        h = heat.get(page) or {}
        if h.get('btu'):
            dev['btuPerHour'] = h['btu']
            stats['btuWritten'] += 1
        else:
            notes['no thermal dissipation published'].append(
                f"{dev['model']}  {part}")

    lines = [
        f"crawl: {pages} pages, {len(skus)} part numbers",
        f"Extron entries in catalog: {stats['extron']}",
        f"  matched to a web row:    {stats['matched']}",
        f"  education price written: {stats['eduWritten']}",
        f"  BTU/hr written:          {stats['btuWritten']}",
        f"  product page written:    {stats['urlWritten']}",
        f"  MSRP filled:             {stats['msrpFilled']}",
        "",
        f"  no web row:              {stats['noWebRow']}",
        f"  model name unconfirmed:  {stats['unconfirmed']}",
        f"  no education price:      {stats['noEduPrice']}",
        f"  MSRP differs from web:   {stats['msrpDiffers']}",
        "",
    ]
    for heading, items in sorted(notes.items()):
        lines.append(f"--- {heading} ({len(items)}) ---")
        lines += [f"  {i}" for i in items]
        lines.append("")
    report = '\n'.join(lines)
    print(report[:4000])

    if a.report:
        with open(a.report, 'w', encoding='utf-8') as f:
            f.write(report)

    if a.dry_run:
        print('(dry run: catalog not written)')
        return

    cat.setdefault('__pricing', {})['educationPrice'] = {
        'source': 'extron.com product pages, Education Contract column',
        'entriesPriced': stats['eduWritten'],
    }
    cat['__pricing']['heat'] = {
        'source': 'extron.com Specifications tab, thermal dissipation '
                  '(device and power supply where both are published)',
        'entriesMeasured': stats['btuWritten'],
    }
    with open(a.catalog, 'w', encoding='utf-8') as f:
        json.dump(cat, f, indent=1, ensure_ascii=False)
        f.write('\n')
    print(f'wrote {a.catalog}')


if __name__ == '__main__':
    main()
