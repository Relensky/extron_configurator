"""Fills MSRP (and optionally education) prices into av_devices.json from a
published price list.

    python tools/import_price_list.py <price list.pdf|.csv> av_devices.json \
        [--tier msrp|education] [--source "Extron October 2025"] \
        [--report report.txt] [--dry-run]

WHY THIS EXISTS
---------------
The catalog is built from Extron's engineering drawings, which say what a box
IS and nothing about what it costs. Manufacturer prices move at least yearly,
and extron.com is behind a bot defense that refuses automated requests, so the
prices cannot be pulled per-product on demand. What every dealer and every
state contract DOES have is a price list: a flat table of part number,
description, and price. This turns one of those into catalog prices in one
pass, and can be re-run against next year's list.

MATCHING IS ON PART NUMBER, AND THEN CHECKED
--------------------------------------------
A part number alone is not enough. Catalogs drift, entries get copied, and a
generic row can end up carrying somebody else's SKU — writing $5,340 onto an
entry called "AAP" because they happened to share a part number is exactly the
sort of quiet error a quoting tool must not make. So every match must also
CORROBORATE: the price list's description has to begin with the catalog's model
name (allowing for the trailing color and variant words a model name carries
and a description does not). Anything that fails is left alone and listed in
the report, to be looked at by a person.

INPUT FORMATS
-------------
  * PDF  — any list whose rows read "<part no> <model + description> $<price>".
           Needs `pip install pypdf`.
  * CSV  — columns named part/partnumber/part no, price/msrp, and optionally
           description. Header row required; column order does not matter.
"""
import csv
import io
import json
import os
import re
import sys

PART_RE = r'\d{2,3}-\d{3,4}-\d{2,3}[A-Z]?'


def flat(s):
    return re.sub(r'[^a-z0-9]', '', s.lower())


def read_pdf(path):
    """{part number: (description, price)} from a price list PDF."""
    try:
        import pypdf
    except ImportError:
        sys.exit('Reading a PDF needs pypdf:  pip install pypdf')
    pages = pypdf.PdfReader(path).pages
    text = '\n'.join((p.extract_text() or '') for p in pages).replace('\n', ' ')
    # Prices come out of the PDF with kerning spaces inside them ("$11 0.00"),
    # so the digits are matched loosely and the spaces stripped afterwards.
    pattern = re.compile(r'(' + PART_RE + r')\s+(.*?)\s+\$\s*([\d,\s]+\.\s*\d{2})')
    out = {}
    for m in pattern.finditer(text):
        part = m.group(1)
        if part in out:
            continue  # first occurrence wins; lists repeat parts in summaries
        try:
            price = float(m.group(3).replace(' ', '').replace(',', ''))
        except ValueError:
            continue
        if price <= 0:
            continue
        out[part] = (re.sub(r'\s+', ' ', m.group(2)).strip(), price)
    return out


def read_csv(path):
    out = {}
    with io.open(path, encoding='utf-8-sig', newline='') as fh:
        for row in csv.DictReader(fh):
            keys = {re.sub(r'[^a-z]', '', (k or '').lower()): (v or '')
                    for k, v in row.items()}
            part = (keys.get('partnumber') or keys.get('partno')
                    or keys.get('part') or keys.get('sku') or '').strip()
            raw = (keys.get('msrp') or keys.get('price')
                   or keys.get('listprice') or '').strip()
            if not part or not raw:
                continue
            try:
                price = float(re.sub(r'[^0-9.]', '', raw))
            except ValueError:
                continue
            if price <= 0:
                continue
            out[part] = ((keys.get('description') or '').strip(), price)
    return out


def corroborates(model, description):
    """True when the price list row is plausibly about this catalog model.

    Three ways to agree, in falling order of strictness — a description
    normally opens with the model name, but a catalog model often carries
    trailing qualifiers ("..., Black", "... Uncompressed") that the
    description spells out differently or later.
    """
    desc = flat(description)
    if not desc:
        return False

    whole = flat(model)
    if whole and desc.startswith(whole[:max(6, int(len(whole) * 0.6))]):
        return True

    before_comma = flat(model.split(',')[0])
    if len(before_comma) >= 4 and desc.startswith(before_comma):
        return True

    words = model.split()
    if len(words) > 1:
        dropped = flat(' '.join(words[:-1]))
        if len(dropped) >= 6 and desc.startswith(dropped):
            return True
    return False


def main():
    # Hand-rolled rather than argparse so the tool stays a single file with no
    # imports beyond the standard library, like its neighbours here.
    argv = sys.argv[1:]
    args, opts, i = [], {}, 0
    while i < len(argv):
        a = argv[i]
        if a.startswith('--'):
            name = a[2:]
            if '=' in name:
                key, value = name.split('=', 1)
                opts[key] = value
            elif i + 1 < len(argv) and not argv[i + 1].startswith('--'):
                opts[name] = argv[i + 1]
                i += 1
            else:
                opts[name] = 'true'
        else:
            args.append(a)
        i += 1
    if len(args) < 2:
        sys.exit(__doc__)
    list_path, catalog_path = args[0], args[1]

    def flag(name, default=''):
        return opts.get(name, default)

    tier = flag('tier', 'msrp')
    if tier not in ('msrp', 'education'):
        sys.exit('--tier must be msrp or education')
    source = flag('source', os.path.basename(list_path))
    report_path = flag('report', '')
    dry_run = 'dry-run' in opts

    reader = read_pdf if list_path.lower().endswith('.pdf') else read_csv
    prices = reader(list_path)
    print('price list rows: %d' % len(prices))

    with io.open(catalog_path, encoding='utf-8') as fh:
        catalog = json.load(fh)
    devices = catalog.get('devices', [])

    field = 'price' if tier == 'msrp' else 'educationPrice'
    updated, unchanged, mismatched, missing = 0, 0, [], []

    for dev in devices:
        part = (dev.get('partNumber') or '').strip()
        if not part or part not in prices:
            missing.append(dev.get('model', part))
            continue
        description, price = prices[part]
        if not corroborates(dev.get('model', ''), description):
            mismatched.append((part, dev.get('model', ''), description, price))
            continue
        if dev.get(field) == price:
            unchanged += 1
            continue
        dev[field] = price
        updated += 1

    print('%s set: %d   already correct: %d   left alone (no match in list): '
          '%d   left alone (description disagrees): %d'
          % (field, updated, unchanged, len(missing), len(mismatched)))

    if not dry_run:
        # Provenance, so a year from now it is clear which list these came from
        # and how old they are.
        stamp = catalog.setdefault('__pricing', {})
        stamp[field] = {'source': source, 'imported': _today(),
                        'entriesPriced': updated + unchanged}
        with io.open(catalog_path, 'w', encoding='utf-8') as fh:
            fh.write(json.dumps(catalog, indent=1, ensure_ascii=False))
        print('written to %s' % catalog_path)

    if report_path:
        with io.open(report_path, 'w', encoding='utf-8') as fh:
            fh.write('Price import from %s (tier: %s)\n\n' % (source, tier))
            fh.write('LEFT ALONE — description disagrees with the model '
                     '(%d). Check these by hand:\n' % len(mismatched))
            for part, model, description, price in mismatched:
                fh.write('  %-14s catalog: %-40s list: %s  $%.2f\n'
                         % (part, model, description[:60], price))
            fh.write('\nLEFT ALONE — no row in the price list (%d):\n'
                     % len(missing))
            for model in missing:
                fh.write('  %s\n' % model)
        print('report written to %s' % report_path)


def _today():
    import datetime
    return datetime.date.today().isoformat()


if __name__ == '__main__':
    main()
