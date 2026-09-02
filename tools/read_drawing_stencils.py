"""Reads the Extron Visio engineering stencils in drawings_library/ and emits
av_devices.json entries: model, part number, description, category, and the
connector set read off the drawing.

The drawings are block diagrams with a fixed convention: inputs down the left
edge, outputs down the right, each connector a label ("HDMI", "AUDIO OUT")
with its connector type ("[F TYPE A]", "[3 POLE CS]") directly underneath and
its port number to the outside.
"""
import json
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict

ROOT = sys.argv[1] if len(sys.argv) > 1 else 'drawings_library'

MASTER_RE = re.compile(r"visio/masters/master\d+\.xml$")
TYPE_RE = re.compile(r'^\[.*\]$')
NUM_RE = re.compile(r'^\d{1,3}[A-Z]?$')


def clean(s):
    s = re.sub(r'<[^>]+>', '', s)
    s = s.replace('&#10;', ' ').replace('&#13;', ' ')
    s = (s.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>')
          .replace('&apos;', "'").replace('&quot;', '"'))
    s = s.replace('�', '-')
    return ' '.join(s.split())


def shape_props(xml):
    """Label -> Value from the master's Shape Data (Property) section."""
    out = {}
    sec = re.search(r"<Section N='Property'>(.*?)</Section>", xml, re.S)
    if not sec:
        return out
    for row in re.finditer(r"<Row N='[^']*'>(.*?)</Row>", sec.group(1), re.S):
        body = row.group(1)
        v = re.search(r"<Cell N='Value' V='([^']*)'", body)
        l = re.search(r"<Cell N='Label' V='([^']*)'", body)
        if v and l:
            out[l.group(1)] = clean(v.group(1))
    return out


NS = {'v': 'http://schemas.microsoft.com/office/visio/2012/main'}


def _cell(shape, name):
    for c in shape.findall('v:Cell', NS):
        if c.get('N') == name:
            try:
                return float(c.get('V'))
            except (TypeError, ValueError):
                return None
    return None


def _walk(container, ox, oy, out):
    """Absolute positions of every text-carrying shape under [container].

    Half the stencils put their connectors inside a Visio GROUP, whose
    children are positioned in the group's own coordinate system. Reading
    PinX/PinY flat gives every one of those the same position — which is how
    a 21-connector drawing came out with two ports. A child's absolute origin
    is the parent's pin less its local pin, accumulated down the tree.
    """
    for shape in container.findall('v:Shape', NS):
        px, py = _cell(shape, 'PinX'), _cell(shape, 'PinY')
        if px is None or py is None:
            continue
        ax, ay = ox + px, oy + py

        text = shape.find('v:Text', NS)
        if text is not None:
            t = clean(''.join(text.itertext()))
            if t:
                out.append((ax, ay, t))

        kids = shape.find('v:Shapes', NS)
        if kids is not None:
            lx = _cell(shape, 'LocPinX') or 0.0
            ly = _cell(shape, 'LocPinY') or 0.0
            _walk(kids, ax - lx, ay - ly, out)


def text_shapes(xml):
    """(x, y, text) for every shape carrying text, in page coordinates."""
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return []
    out = []
    for shapes in root.findall('v:Shapes', NS):
        _walk(shapes, 0.0, 0.0, out)
    if not out:
        _walk(root, 0.0, 0.0, out)
    return out


# --- signal typing --------------------------------------------------------
# Read off the connector LABEL first (it says what the port is for), then the
# connector TYPE as a fallback (it only says what plug it is).
LABEL_SIGNALS = [
    (r'\bDANTE\b|\bAES67\b', 'dante'),
    (r'\bHDBT\b|\bHDBASET\b|\bDTP\b|\bXTP\b', 'hdbaset'),
    (r'\bHDMI\b', 'hdmi'),
    (r'\bDISPLAY\s*PORT\b|\bDP\b', 'displayPort'),
    (r'\bUSB[-\s]?C\b', 'usbC'),
    (r'\bSDI\b', 'sdi'),
    (r'\bVGA\b|\bRGB\b|\bCOMPUTER\b|\bYUV\b|\bCOMPONENT\b|\bCOMPOSITE\b', 'vga'),
    (r'\bMIC\b|\bMIC/LINE\b|\bPHANTOM\b', 'micLine'),
    (r'\bSPEAKER\b|\bSPKR\b|\bAMP\s*OUT\b|\b70V\b|\b100V\b|\bLO-?Z\b', 'speaker'),
    (r'S/?PDIF|\bAES\b|\bOPTICAL\b|\bTOSLINK\b|\bDIGITAL\s*AUDIO\b', 'digitalAudio'),
    (r'\bAUDIO\b|\bLINE\b|\bANALOG\b|\bMONITOR\b', 'analogAudio'),
    (r'\bUSB\b|\bHOST\b|\bDEVICE\b', 'usbData'),
    (r'\bLAN\b|\bETHERNET\b|\bNETWORK\b|\bPOE\b|\bETH\b', 'network'),
    (r'\bIR\b', 'ir'),
    (r'RS-?232|RS-?422|RS-?485|\bSERIAL\b|\bCOM\b', 'serial'),
    (r'\bPOWER\b|\bAC\b|\bDC\b|\bMAINS\b|\bIEC\b', 'power'),
    (r'\bRELAY\b|\bCONTACT\b|\bFLEX\s*I/?O\b|\bDIGITAL\s*I/?O\b', 'other'),
]

TYPE_SIGNALS = [
    (r'F TYPE A', 'hdmi'),
    (r'RJ-?45', 'network'),
    (r'DISPLAYPORT|DP F', 'displayPort'),
    (r'USB', 'usbData'),
    (r'BNC', 'sdi'),
    (r'HD-?15|VGA', 'vga'),
    (r'3\.5MM|RCA|POLE CS|CAPTIVE|XLR|TRS|PHOENIX', 'analogAudio'),
    (r'IEC|POWER', 'power'),
]


def signal_for(label, ctype):
    up = label.upper()
    for pattern, sig in LABEL_SIGNALS:
        if re.search(pattern, up):
            return sig
    up = (ctype or '').upper()
    for pattern, sig in TYPE_SIGNALS:
        if re.search(pattern, up):
            return sig
    return 'other'


# Labels that say their own direction, whatever side of the box they sit on.
OUT_RE = re.compile(r'\bOUT(PUT)?S?\b|\bOUTS\b|\bLOOP\b|\bTHRU\b|\bMON\b')
IN_RE = re.compile(r'\bIN(PUT)?S?\b|\bMIC\b|\bSOURCE\b')
BIDI_RE = re.compile(r'\bLAN\b|\bDANTE\b|\bETHERNET\b|\bNETWORK\b|\bAES67\b|'
                     r'\bUSB[-\s]?C\b|RS-?232|RS-?422|RS-?485|\bPOE\b')


def direction_for(label, x, mid):
    up = label.upper()
    if BIDI_RE.search(up):
        return 'bidirectional'
    if OUT_RE.search(up):
        return 'output'
    if IN_RE.search(up):
        return 'input'
    # The drawing convention: inputs down the left edge, outputs down the right.
    return 'input' if x < mid else 'output'


def slug(text, used):
    base = re.sub(r'[^a-z0-9]+', '_', text.lower()).strip('_') or 'port'
    name = base
    n = 2
    while name in used:
        name = f'{base}_{n}'
        n += 1
    used.add(name)
    return name


def ports_from(xml, page_width):
    """Connectors read off the block drawing, with a flag for how it is
    powered — the drawing shows a POWER inlet or a PoE-fed LAN port, and both
    matter to the rack's load."""
    shapes = text_shapes(xml)
    types = [(x, y, t) for x, y, t in shapes if TYPE_RE.match(t)]
    all_text = ' '.join(t.upper() for _, _, t in shapes)

    power = 'mains'
    if re.search(r'POE|POWER OVER ETHERNET', all_text):
        power = 'poe'
    elif re.search(r'POWER|IEC|AC INPUT|100-240V|12V', all_text):
        power = 'mains'
    elif not types:
        # A passive box: a speaker, a cable, a mounting plate.
        power = 'none'

    if not types:
        return [], power

    labels = [(x, y, t) for x, y, t in shapes
              if not TYPE_RE.match(t) and not NUM_RE.match(t)]
    numbers = [(x, y, t) for x, y, t in shapes if NUM_RE.match(t)]

    xs = [x for x, _, _ in types]
    mid = page_width / 2 if page_width else (min(xs) + max(xs)) / 2

    found = []
    for tx, ty, ttext in types:
        # The label sits directly above its connector type, same column.
        best, gap, ly_of = None, 0.25, None
        for lx, ly, lt in labels:
            if abs(lx - tx) > 0.12:
                continue
            d = ly - ty
            if 0 < d < gap:
                gap, best, ly_of = d, lt, ly
        if best is None:
            continue
        # The port number sits on the label's own line, just outside it.
        # Matching against the TYPE's line instead picks up the neighboring
        # connector's number, which is how one drawing produced two "HDMI 005".
        num = ''
        ngap = 0.30
        for nx, ny, nt in numbers:
            if abs(ny - ly_of) > 0.02:
                continue
            d = abs(nx - tx)
            if 0.01 < d < ngap:
                ngap, num = d, nt
        found.append((tx, ty, best, ttext, num))

    # Top of the box downward, left column then right: reading order.
    found.sort(key=lambda f: (0 if f[0] < mid else 1, -f[1]))

    live = [f for f in found if f[2].upper() != 'DISABLED']

    # A rank of identical unnumbered connectors (twelve MIC/LINE inputs) is
    # numbered here so the ports can be told apart on the diagram — and the
    # FIRST one is numbered too, since "MIC/LINE" above "MIC/LINE 2" reads
    # like a mistake.
    ranks = Counter()
    for x, _y, label, _ctype, num in live:
        if not num:
            ranks[(label, direction_for(label, x, mid))] += 1
    repeated = {k for k, n in ranks.items() if n > 1}

    used = set()
    seen = Counter()
    ports = []
    for x, _y, label, ctype, num in live:
        direction = direction_for(label, x, mid)
        if num:
            full = f'{label} {num}'
        elif (label, direction) in repeated:
            seen[(label, direction)] += 1
            full = f'{label} {seen[(label, direction)]}'
        else:
            full = label
        ports.append({
            'id': slug(full, used),
            'label': full[:24],
            'signal': signal_for(label, ctype),
            'direction': direction,
            'side': 'right' if direction == 'output' else 'left',
        })
    return ports, power


def category_for(path):
    """The stencil folder is the product family: 'Extron Audio Products
    Engineering Drawings' -> 'Audio'."""
    parts = path.replace('\\', '/').split('/')
    for p in parts:
        m = re.match(r'Extron (.+?) Engineering Drawings$', p)
        if m:
            return m.group(1).replace(' Products', '').strip()
    return 'Extron'


def main():
    entries = {}
    stats = Counter()
    skipped = []
    no_masters = []

    for dirpath, _dirs, files in os.walk(ROOT):
        for f in sorted(files):
            if not f.lower().endswith('.vssx'):
                continue
            p = os.path.join(dirpath, f)
            retired = 'retired' in p.lower()
            z = zipfile.ZipFile(p)
            names = [n for n in z.namelist() if MASTER_RE.match(n)]
            if not names:
                no_masters.append(p)
                continue
            page_widths = dict(re.findall(
                r"<Master\s[^>]*?\sNameU='([^']*)'.*?<Cell N='PageWidth' V='([^']*)'",
                z.read('visio/masters/masters.xml').decode('utf8', 'replace')))
            for n in names:
                xml = z.read(n).decode('utf8', 'replace')
                props = shape_props(xml)
                model = props.get('Model', '').strip()
                if not model:
                    stats['no model'] += 1
                    skipped.append((p, n))
                    continue
                shape_name = props.get('Shape Name', '')
                width = float(page_widths.get(shape_name, 0) or 0)
                ports, power_input = ports_from(xml, width)

                entry = {
                    'model': model,
                    'manufacturer': props.get('Make', 'Extron'),
                    'partNumber': props.get('Part #', ''),
                    'category': category_for(p),
                    'rackUnits': 0,
                    'powerInput': power_input,
                    'ports': ports,
                }
                notes = []
                if props.get('Description'):
                    notes.append(props['Description'])
                # Most stencils repeat the description in the Version field;
                # printing it twice is noise, not detail.
                version = props.get('Version', '').strip()
                described = ' '.join(notes).lower()
                if (version
                        and version.lower() not in ('standard model', 'standard version')
                        and version.lower() not in described):
                    notes.append(version)
                if retired:
                    notes.append('Retired product')
                if notes:
                    entry['notes'] = ' — '.join(notes)

                key = model.lower().replace(' ', '').replace('-', '')
                previous = entries.get(key)
                # The same model appears in several stencils (a DTP switcher is
                # in both the DTP and Matrix books). Keep the richest drawing,
                # and never let a Retired copy displace a current one.
                if previous:
                    stats['duplicate'] += 1
                    if retired and 'Retired' in previous.get('notes', ''):
                        pass
                    elif retired:
                        continue
                    elif len(ports) <= len(previous.get('ports', [])):
                        continue
                entries[key] = entry
                stats['kept'] += 1

    out = sorted(entries.values(), key=lambda e: e['model'].lower())
    print(f'entries: {len(out)}  stats: {dict(stats)}')
    print(f'no masters in: {no_masters}')
    withports = sum(1 for e in out if e['ports'])
    print(f'with connectors: {withports}  without: {len(out) - withports}')
    cats = Counter(e['category'] for e in out)
    print('categories:', cats.most_common())

    with open(sys.argv[2] if len(sys.argv) > 2 else 'extracted.json', 'w',
              encoding='utf8') as fh:
        json.dump(out, fh, indent=1)


if __name__ == '__main__':
    main()
