"""Works out which projectorcentral.com page describes each projector in
av_devices.json, and writes the pairing for scrape_projectorcentral.py.

    python tools/match_projectorcentral.py av_devices.json \
        --out pc_matched.json [--unmatched pc_unmatched.json] [--sitemap cache.json]

WHY THIS IS ITS OWN STEP
------------------------
A projector is sold under a different name in every market, and the catalog
(built from Extron's drawings) and the website rarely agree on which one:

    catalog          projectorcentral.com     why
    PT-EW540         pt-ew540u                U is the US model
    PT-EW540L        pt-ew540ul               L is supplied without a lens
    EB-G7100         pro_g7100                Epson's US name for the G series
    CB-805F          powerlite_805f           CB is Asia, PowerLite is the US
    BrightLink 685Wi brightlink_685wi         agrees, for once

So the pairing is guesswork, and guesswork belongs in a file somebody can read
before it turns into wattages in a catalog. Every row records HOW it matched:

    exact   the names agree
    region  same model, different market or finish letter
    alias   Epson's other market names for the same projector

Two rules keep it honest. Digits are never altered — a different number is a
different projector. And where several pages could match, the one that agrees
about the lens-less "L" suffix wins, because PT-EW540 and PT-EW540L are
separate SKUs and are both on the site.

Coverage is partial by nature: projectorcentral.com is US-focused, so the
China-only Panasonic PT-SL*C / PT-FR*C series and some Epson EB- models have
no page at all. Those land in --unmatched rather than being forced onto a
near neighbor.
"""
import argparse
import collections
import json
import os
import re
import urllib.request

SITEMAP = "https://www.projectorcentral.com/sitemap-projectors.xml"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) "
      "Gecko/20100101 Firefox/128.0")

# Letters these makers hang off a model for market, color, and whether a lens
# is in the box. Letters only: see the note about digits above.
SUFFIXES = ["", "u", "e", "ea", "b", "w", "c", "bu", "wu", "be", "we",
            "l", "lb", "lw", "lu", "ul", "ubl", "uwl", "lbu", "lwu",
            "ba", "bd", "wa", "wd", "nl",
            "k", "ku", "uk", "us", "na", "s", "t"]

# The same slug also exists as a lamp page, a review, a price page and a throw
# calculator. Only the bare spec page carries the power and status figures.
SKIP = ("-projector-lamp", "-user-reviews", "-projectors.htm", "-lamp-life",
        "-review", "-street-price", "-competitors", "-projector-lamps",
        "-projection-calculator", "-prices.htm", "-throw-distance")


def flat(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def sitemap_urls(cache):
    if cache and os.path.exists(cache):
        return json.load(open(cache, encoding="utf-8"))
    req = urllib.request.Request(SITEMAP, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=90) as r:
        xml = r.read().decode("utf-8", "replace")
    urls = re.findall(r"<loc>([^<]+)</loc>", xml)
    if cache:
        json.dump(urls, open(cache, "w", encoding="utf-8"))
    return urls


def build_index(urls):
    """flattened model -> [(flattened manufacturer, url)]"""
    by_model = collections.defaultdict(list)
    for u in urls:
        if not u.endswith(".htm") or any(s in u for s in SKIP):
            continue
        slug = u.rsplit("/", 1)[1][:-4]
        if "-" not in slug:
            continue
        mfr, model = slug.split("-", 1)
        by_model[flat(model)].append((flat(mfr), u))
    return by_model


def brand_ok(catalog_mfr, slug_mfr):
    a = flat(catalog_mfr)
    return a.startswith(slug_mfr) or slug_mfr.startswith(a)


def alias_keys(model):
    """Epson sells one projector as EB- (Europe), CB- (Asia) and, in the US,
    PowerLite (standard), Pro (the G installation series) or BrightLink (the
    interactive Wi models). The digits are the constant."""
    keys = []
    m = model.strip().lower()
    for prefix in ("cb-", "eb-"):
        if m.startswith(prefix):
            rest = m[len(prefix):]
            other = "eb-" if prefix == "cb-" else "cb-"
            keys += [flat(other + rest), flat("pro " + rest),
                     flat("powerlite " + rest), flat("brightlink " + rest)]
            if rest.startswith("g"):
                keys.append(flat("powerlite pro " + rest))
    return keys


def find(by_model, mfr, model):
    """(url, kind) or (None, None)."""
    keys = [(flat(model), "exact")] + [(k, "alias") for k in alias_keys(model)]

    for key, kind in keys:
        for cand_mfr, url in by_model.get(key, []):
            if brand_ok(mfr, cand_mfr):
                return url, kind

    # Strip the model back to its base and try every market letter against it,
    # collecting all candidates and scoring them rather than taking the first:
    # PT-EW540L finds both pt-ew540u and pt-ew540ul, and only the second is
    # the lens-less model the catalog is naming.
    candidates = []
    for key, kind in keys:
        bases = {key}
        for suffix in SUFFIXES[1:]:
            if key.endswith(suffix) and len(key) > len(suffix) + 3:
                bases.add(key[:-len(suffix)])
        for base in bases:
            if not re.search(r"\d", base):
                continue
            for suffix in SUFFIXES:
                for cand_mfr, url in by_model.get(base + suffix, []):
                    if brand_ok(mfr, cand_mfr):
                        candidates.append((
                            base + suffix, url,
                            "region" if kind == "exact" else "alias+region",
                            key))
    if not candidates:
        return None, None

    def score(c):
        slug_key, _, _, catalog_key = c
        # Disagreeing about the lens costs more than any number of other
        # letters: it is the one wrong answer that looks right.
        lens = (slug_key.endswith("l"), catalog_key.endswith("l"))
        return (0 if lens[0] == lens[1] else 10) + abs(
            len(slug_key) - len(catalog_key))

    best = min(candidates, key=score)
    return best[1], best[2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("catalog")
    ap.add_argument("--out", default="pc_matched.json")
    ap.add_argument("--unmatched", default="pc_unmatched.json")
    ap.add_argument("--sitemap", help="cache file for the sitemap URL list")
    a = ap.parse_args()

    by_model = build_index(sitemap_urls(a.sitemap))
    cat = json.load(open(a.catalog, encoding="utf-8"))
    proj = [d for d in cat["devices"] if d.get("category") == "Projector"]

    rows, miss = [], []
    for d in proj:
        url, kind = find(by_model, d["manufacturer"], d["model"])
        if url:
            rows.append({"manufacturer": d["manufacturer"],
                         "model": d["model"], "url": url, "match": kind})
        else:
            miss.append(f"{d['manufacturer']} {d['model']}")

    print(f"projectors: {len(proj)}   matched: {len(rows)}   "
          f"unmatched: {len(miss)}")
    print("  " + str(collections.Counter(r["match"] for r in rows)))
    json.dump(rows, open(a.out, "w", encoding="utf-8"), indent=1)
    json.dump(miss, open(a.unmatched, "w", encoding="utf-8"), indent=1)
    print(f"wrote {a.out} and {a.unmatched}")


if __name__ == "__main__":
    main()
