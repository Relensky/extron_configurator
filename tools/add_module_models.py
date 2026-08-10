"""Adds catalog entries for every model the python control modules claim to
drive but the catalog does not describe.

    python tools/add_module_models.py <modules dir> av_devices.json \
        [--builtins builtins.txt] [--msrp msrp.json] [--report report.txt] \
        [--dry-run]

WHY
---
Two lists have to agree and were drifting apart. The modules in `device/`
declare, in DEVICE_INFO["models"] and self.Models, exactly which models the
processor can drive. The catalog (av_devices.json) describes what a model IS:
its connectors, rack height and price. A model in the first and not the second
can be selected on the Devices tab and then draws as a generic box with made-up
ports and no price — which is how a room ends up quoted without its projector.

This walks the modules, works out which declared models the app cannot already
resolve (the catalog file OR the built-in table in av_device_library.dart), and
writes an entry for each: manufacturer from the module's filename prefix,
category and connectors from its DEVICE_INFO "device_type", and the part number
and MSRP where a price list row corroborates the model name.

WHAT IT WILL NOT DO
-------------------
Invent a price. Non-Extron models are not in the Extron price list, so they go
in unpriced and the estimate reports them as such — or falls back to the base
cost for their category, which is what that card is for.
"""
import io
import json
import os
import re
import sys
import ast
import glob

# Module filename prefix -> manufacturer. The convention is the shop's own and
# is stable across the whole device folder.
MAKERS = {
    'apc': 'APC', 'avr': 'AVer', 'dali': 'Extron', 'dyds': 'Da-Lite',
    'epsn': 'Epson', 'extr': 'Extron', 'hcam': 'HoverCam', 'igen': 'iGen',
    'infc': 'InFocus', 'krmr': 'Kramer', 'nec': 'NEC', 'pana': 'Panasonic',
    'poly': 'Poly', 'ptz': 'PTZOptics', 'shrp': 'Sharp', 'shur': 'Shure',
    'smsg': 'Samsung', 'sony': 'Sony', 'vadd': 'Vaddio',
}

# DEVICE_INFO device_type -> the catalog category. These are the words the base
# cost card uses, so an unpriced entry still costs off the right category.
CATEGORIES = {
    'dsp': 'DSP', 'camera': 'Camera', 'doccam': 'Camera',
    'projector': 'Projector', 'vp': 'Projector', 'display': 'Display',
    'tdisplay': 'Display', 'switcher': 'Switcher', 'matrix': 'Switcher',
    'scaler': 'Switcher', 'controller': 'Control processor',
    'sm': 'Recorder / streamer', 'streaming': 'Recorder / streamer',
    'vtc': 'USB interface', 'cs': 'Wireless presentation',
    'power': 'Power controller', 'other': '',
    'via': 'Wireless presentation',
}

# Sides follow the convention of the file these entries are joining: the
# drawings-derived catalog puts every signal connector on the left or the
# right and nothing on the edges, so a bidirectional LAN sits on the left with
# the other non-outputs. (The app's built-in table uses the bottom edge for
# LAN; mixing the two would leave one catalog with two conventions.)
PORTS = {
    'Projector': [
        ('in_hdmi_1', 'HDMI 1', 'hdmi', 'input', 'left'),
        ('in_hdmi_2', 'HDMI 2', 'hdmi', 'input', 'left'),
        ('in_hdbt_1', 'HDBaseT', 'hdbaset', 'input', 'left'),
        ('in_vga_1', 'COMPUTER', 'vga', 'input', 'left'),
        ('in_aud_1', 'AUDIO IN', 'analogAudio', 'input', 'left'),
        ('lan_1', 'LAN', 'network', 'bidirectional', 'left'),
        ('in_ctrl_1', 'RS-232', 'serial', 'input', 'left'),
    ],
    'Display': [
        ('in_hdmi_1', 'HDMI 1', 'hdmi', 'input', 'left'),
        ('in_hdmi_2', 'HDMI 2', 'hdmi', 'input', 'left'),
        ('in_hdmi_3', 'HDMI 3', 'hdmi', 'input', 'left'),
        ('out_aud_1', 'AUDIO OUT', 'analogAudio', 'output', 'right'),
        ('lan_1', 'LAN', 'network', 'bidirectional', 'left'),
        ('in_ctrl_1', 'RS-232', 'serial', 'input', 'left'),
    ],
    'Camera': [
        ('out_hdmi_1', 'HDMI OUT', 'hdmi', 'output', 'right'),
        ('out_usb_1', 'USB', 'usbData', 'output', 'right'),
        ('out_sdi_1', 'SDI OUT', 'sdi', 'output', 'right'),
        ('lan_1', 'LAN', 'network', 'bidirectional', 'left'),
    ],
    'DSP': (
        [('in_mic_%d' % i, 'MIC/LINE %d' % i, 'micLine', 'input', 'left')
         for i in range(1, 7)]
        + [('out_aud_%d' % i, 'OUT %d' % i, 'analogAudio', 'output', 'right')
           for i in range(1, 5)]
        + [('lan_1', 'LAN', 'network', 'bidirectional', 'left')]),
    'Switcher': (
        [('in_hdmi_%d' % i, 'HDMI IN %d' % i, 'hdmi', 'input', 'left')
         for i in range(1, 5)]
        + [('out_hdmi_1', 'HDMI OUT', 'hdmi', 'output', 'right'),
           ('out_dtp_1', 'DTP OUT', 'hdbaset', 'output', 'right'),
           ('in_aud_1', 'AUDIO IN', 'analogAudio', 'input', 'left'),
           ('out_aud_1', 'AUDIO OUT', 'analogAudio', 'output', 'right'),
           ('lan_1', 'LAN', 'network', 'bidirectional', 'left')]),
    'Control processor': [
        ('lan_1', 'LAN', 'network', 'bidirectional', 'left'),
        ('out_ctrl_1', 'RS-232 1', 'serial', 'output', 'right'),
        ('out_ctrl_2', 'RS-232 2', 'serial', 'output', 'right'),
        ('out_ir_1', 'IR 1', 'ir', 'output', 'right'),
    ],
    'Recorder / streamer': [
        ('in_hdmi_1', 'HDMI IN', 'hdmi', 'input', 'left'),
        ('in_aud_1', 'AUDIO IN', 'analogAudio', 'input', 'left'),
        ('out_hdmi_1', 'HDMI LOOP', 'hdmi', 'output', 'right'),
        ('lan_1', 'LAN', 'network', 'bidirectional', 'left'),
    ],
    'USB interface': [
        ('in_hdmi_1', 'HDMI IN', 'hdmi', 'input', 'left'),
        ('out_hdmi_1', 'HDMI OUT', 'hdmi', 'output', 'right'),
        ('out_usb_1', 'USB OUT', 'usbData', 'output', 'right'),
        ('lan_1', 'LAN', 'network', 'bidirectional', 'left'),
    ],
    'Wireless presentation': [
        ('out_hdmi_1', 'HDMI OUT', 'hdmi', 'output', 'right'),
        ('out_aud_1', 'AUDIO OUT', 'analogAudio', 'output', 'right'),
        ('lan_1', 'LAN', 'network', 'bidirectional', 'left'),
    ],
    'Power controller': (
        [('out_pwr_%d' % i, 'OUTLET %d' % i, 'power', 'output', 'right')
         for i in range(1, 9)]
        + [('lan_1', 'LAN', 'network', 'bidirectional', 'left')]),
}

DEFAULT_PORTS = [
    ('in_1', 'IN 1', 'hdmi', 'input', 'left'),
    ('out_1', 'OUT 1', 'hdmi', 'output', 'right'),
    ('lan_1', 'LAN', 'network', 'bidirectional', 'left'),
]

# Rack heights the app's built-in table already knows. Everything else goes in
# as 0 — "not rack mounted" — because a module says nothing about how tall a
# box is and a guessed height would silently mis-plan a rack.
RACK_UNITS = {'DSP': 1, 'Switcher': 1, 'Control processor': 1,
              'Recorder / streamer': 1, 'Power controller': 1}


def flat(s):
    return re.sub(r'[^a-z0-9]', '', s.lower())


def _balanced(src, start):
    depth = 0
    for j in range(start, len(src)):
        if src[j] == '{':
            depth += 1
        elif src[j] == '}':
            depth -= 1
            if depth == 0:
                return src[start:j + 1]
    return None


def read_module(path):
    """(device_type, {models}) declared by one module."""
    src = io.open(path, encoding='utf-8', errors='replace').read()
    device_type, models = '', set()

    m = re.search(r'DEVICE_INFO\s*=\s*\{', src)
    if m:
        blob = _balanced(src, src.index('{', m.start()))
        if blob:
            try:
                info = ast.literal_eval(blob)
                device_type = str(info.get('device_type', '') or '')
                for x in info.get('models', []) or []:
                    models.add(str(x).strip())
            except Exception:
                pass

    for mm in re.finditer(r'self\.Models\s*=\s*\{', src):
        blob = _balanced(src, src.index('{', mm.start()))
        if not blob:
            continue
        for k in re.findall(r"['\"]([^'\"]{2,60})['\"]\s*:", blob):
            models.add(k.strip())
    return device_type, models


def maker_for(filename):
    return MAKERS.get(filename.split('_', 1)[0].lower(), '')


def type_from_filename(filename):
    """The device type baked into the module's name.

    The convention is <maker>_<type>_<Model>..., and it is the only thing to go
    on for the older modules that carry no DEVICE_INFO block. Getting this
    right matters: the category is what an unpriced entry falls back to on the
    base cost card, so a blank one is an entry that can never be costed.
    """
    parts = filename.split('_')
    return parts[1].lower() if len(parts) > 1 else ''


def main():
    argv = sys.argv[1:]
    args, opts, i = [], {}, 0
    while i < len(argv):
        a = argv[i]
        if a.startswith('--'):
            name = a[2:]
            if i + 1 < len(argv) and not argv[i + 1].startswith('--'):
                opts[name] = argv[i + 1]
                i += 1
            else:
                opts[name] = 'true'
        else:
            args.append(a)
        i += 1
    if len(args) < 2:
        sys.exit(__doc__)
    modules_dir, catalog_path = args[0], args[1]

    # --- what the modules claim -------------------------------------------
    declared = {}   # model -> (device_type, {module files})
    for f in sorted(glob.glob(os.path.join(modules_dir, '*.py'))):
        device_type, models = read_module(f)
        base = os.path.basename(f)
        for model in models:
            entry = declared.setdefault(model, [device_type, set()])
            entry[1].add(base)
            if not entry[0]:
                entry[0] = device_type

    # --- what the app can already resolve ---------------------------------
    with io.open(catalog_path, encoding='utf-8') as fh:
        catalog = json.load(fh)
    known = {flat(d['model']) for d in catalog['devices']}
    builtins_path = opts.get('builtins', '')
    if builtins_path and os.path.exists(builtins_path):
        for line in io.open(builtins_path, encoding='utf-8'):
            if line.strip():
                known.add(flat(line.strip()))

    # --- prices, matched on model name ------------------------------------
    prices = {}
    if opts.get('msrp') and os.path.exists(opts['msrp']):
        with io.open(opts['msrp'], encoding='utf-8') as fh:
            for part, row in json.load(fh).items():
                prices.setdefault(flat(row['desc'])[:80], (part, row['msrp']))

    def price_for(model):
        """A price list row whose description STARTS with this model name."""
        key = flat(model)
        if len(key) < 5:
            return None
        best = None
        for desc, (part, msrp) in prices.items():
            if desc.startswith(key):
                # Shortest matching description wins: it is the least likely
                # to be a different, longer model that merely starts the same.
                if best is None or len(desc) < best[0]:
                    best = (len(desc), part, msrp)
        return None if best is None else (best[1], best[2])

    added, skipped_known, unnamed = [], 0, 0
    for model in sorted(declared):
        device_type, files = declared[model]
        if flat(model) in known:
            skipped_known += 1
            continue
        # "Controller", "Toggle" and friends: a name that generic is a driver
        # placeholder, not a product anybody orders.
        if len(model) < 4 or model.lower() in ('controller', 'device'):
            unnamed += 1
            continue

        first_file = sorted(files)[0]
        maker = maker_for(first_file)
        category = CATEGORIES.get(device_type.lower(), '')
        if not category:
            category = CATEGORIES.get(type_from_filename(first_file), '')
        ports = PORTS.get(category, DEFAULT_PORTS)
        found = price_for(model) if maker == 'Extron' else None

        entry = {
            'model': model,
            'manufacturer': maker,
            'category': category,
            'rackUnits': RACK_UNITS.get(category, 0),
            'ports': [
                {'id': p[0], 'label': p[1], 'signal': p[2],
                 'direction': p[3], 'side': p[4]} for p in ports
            ] + [{'id': 'in_power', 'label': 'POWER', 'signal': 'power',
                  'direction': 'input', 'side': 'bottom'}],
            'notes': 'Driven by %s' % ', '.join(sorted(files)),
        }
        if found:
            entry['partNumber'], entry['price'] = found[0], found[1]
        catalog['devices'].append(entry)
        added.append((model, maker, category, found[1] if found else 0))

    catalog['devices'].sort(key=lambda d: (d.get('manufacturer', ''),
                                           d.get('model', '')))
    priced = sum(1 for a in added if a[3])
    print('modules declare %d models; %d already known; %d placeholders '
          'skipped; %d added (%d with an MSRP)'
          % (len(declared), skipped_known, unnamed, len(added), priced))

    if 'dry-run' not in opts:
        with io.open(catalog_path, 'w', encoding='utf-8') as fh:
            fh.write(json.dumps(catalog, indent=1, ensure_ascii=False))
        print('written to %s' % catalog_path)

    if opts.get('report'):
        with io.open(opts['report'], 'w', encoding='utf-8') as fh:
            fh.write('Added %d catalog entries from the control modules\n\n'
                     % len(added))
            for model, maker, category, price in added:
                fh.write('  %-34s %-12s %-22s %s\n'
                         % (model, maker, category,
                            ('$%.2f' % price) if price else 'no price'))
        print('report written to %s' % opts['report'])


if __name__ == '__main__':
    main()
