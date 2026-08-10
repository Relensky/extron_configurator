"""Turns the extracted stencil data into av_devices.json.

Adds the power inlet every entry is meant to carry, keeps the rack heights the
app's built-in table already knows (the drawings do not record them), and
writes an import report of what came in and what is still missing.
"""
import json
import os
import re
import sys

extracted, out_path, report_path = sys.argv[1], sys.argv[2], sys.argv[3]

# Rack heights the app's built-in catalog already carried. The engineering
# drawings are logical block diagrams — they say nothing about how tall the box
# is — so anything known is preserved here rather than being reset to "not
# recorded". DTP CrossPoint 108 is 3U (asked for explicitly).
KNOWN_RACK_UNITS = {
    'DTP CrossPoint 108 4K IPCP MA 70': 3,
    'DTP CrossPoint 84 4K IPCP MA 70': 2,
    'IN1804': 1,
    'SW4 HD 4K PLUS': 1,
    'DMP 64 Plus C AT': 1,
    'DMP 128 Plus C AT': 1,
    'MediaPort 200': 1,
    'ShareLink Pro 2000': 1,
}

POWER_PORT = {
    'id': 'in_power',
    'signal': 'power',
    'direction': 'input',
    'side': 'bottom',
}


def norm(model):
    return re.sub(r'[\s_\-]+', '', model.strip().lower())


devices = json.load(open(extracted, encoding='utf8'))

no_ports = []
no_part = []
by_category = {}

for d in devices:
    power = d.pop('powerInput', 'mains')
    if power != 'mains':
        d['powerInput'] = power

    # Every device carries its inlet, so nothing drops out of the rack load
    # for want of somebody remembering to add one.
    if power != 'none':
        d['ports'] = [p for p in d['ports']
                      if not (p['signal'] == 'power'
                              and p['direction'] != 'output')]
        d['ports'].append(dict(
            POWER_PORT,
            label='POWER (PoE)' if power == 'poe' else 'POWER'))

    ru = KNOWN_RACK_UNITS.get(d['model'])
    if ru:
        d['rackUnits'] = ru

    signal_ports = [p for p in d['ports'] if p['signal'] != 'power']
    if not signal_ports:
        no_ports.append(d['model'])
    if not d.get('partNumber'):
        no_part.append(d['model'])
    by_category.setdefault(d['category'], []).append(d)

doc = {
    '__readme': (
        'AV device catalog for the Room Config Builder: connectors, rack '
        'height, estimated power draw, heat output and unit price per model. '
        'Imported from the Extron engineering drawing stencils in '
        'drawings_library/. Edited on the Device Editor tab; entries here '
        'override the app’s built-in models. Rack heights, watts, BTU '
        'and prices are NOT in the drawings and have to be filled in — '
        'the reports count what is still missing rather than treating a blank '
        'as zero.'),
    'devices': devices,
}
with open(out_path, 'w', encoding='utf8') as fh:
    json.dump(doc, fh, indent=1, ensure_ascii=False)

lines = [
    '# Device catalog import report',
    '',
    f'Imported **{len(devices)} models** from the Extron engineering drawing',
    'stencils in `drawings_library/` into `av_devices.json`.',
    '',
    '## By product family',
    '',
    '| Family | Models |',
    '|---|---|',
]
for cat in sorted(by_category, key=lambda c: -len(by_category[c])):
    lines.append(f'| {cat} | {len(by_category[cat])} |')

lines += [
    '',
    '## What the drawings do not carry',
    '',
    'The stencils are logical block diagrams. They give the model, part',
    'number, description and connector set — and nothing about size, power or',
    'price. Those four are left at 0 ("not recorded") rather than guessed, and',
    'every report counts what is still blank instead of totalling it as zero:',
    '',
    '- **Rack units** — recorded for '
    f'{len(KNOWN_RACK_UNITS)} models the app already knew; blank for the rest.',
    '- **Power draw (W)** and **heat (BTU/hr)** — blank for all of them.',
    '- **Unit price** — blank for all of them.',
    '',
    f'- **{len(no_ports)} models have no signal connectors** in their drawing:',
    '  speakers, cables, mounting plates and blanks, which is correct, plus a',
    '  few whose drawing the reader could not pair up. They can still be',
    '  priced and counted; they just cannot be cabled until connectors are',
    '  added.',
]
if no_part:
    lines.append(f'- **{len(no_part)} models have no part number** in the '
                 'stencil.')

# --- which imported models the control system can actually drive -----------
module_dir = sys.argv[4] if len(sys.argv) > 4 else 'device'
claimed = {}
if os.path.isdir(module_dir):
    for f in sorted(os.listdir(module_dir)):
        if not f.endswith('.py'):
            continue
        src = open(os.path.join(module_dir, f), encoding='utf8',
                   errors='replace').read()
        info = re.search(r'DEVICE_INFO\s*=\s*\{', src)
        if info:
            block = re.search(r'"models"\s*:\s*\[(.*?)\]',
                              src[info.start():info.start() + 3000], re.S)
            if block:
                for a, b in re.findall(r'"([^"]+)"|\'([^\']+)\'', block.group(1)):
                    claimed.setdefault((a or b).strip().lower(), f)
        for blk in re.finditer(r'self\.Models\s*=\s*\{(.*?)\n\s*\}', src, re.S):
            for name in re.findall(r"['\"]([^'\"]{2,60})['\"]\s*:", blk.group(1)):
                claimed.setdefault(name.strip().lower(), f)

driven = [d for d in devices if d['model'].strip().lower() in claimed]
undriven = [d for d in devices if d['model'].strip().lower() not in claimed]

lines += [
    '',
    '## Missing a Python control module',
    '',
    f'**{len(undriven)} of the {len(devices)} imported models have no Python',
    f'driver** in `{module_dir}/`; {len(driven)} do. That is expected rather',
    'than broken — most of the catalog is passive gear, cable and',
    'architectural product that was never going to have a driver — but it is',
    'the list to check before commissioning, because every entry on it is a',
    'box the processor cannot touch.',
    '',
    'This is deliberately NOT written into `av_devices.json`. Which models',
    'have a driver changes every time a module is added to the library, and a',
    'copy in the catalog would be wrong the first time that happened. The app',
    'resolves it live instead:',
    '',
    '- the **Pack List** carries a `Control module` column, naming the module',
    '  or saying `none`;',
    '- a **Devices Without a Control Module** section lists the room\'s',
    '  undriven devices, and drops out entirely when there are none.',
    '',
    'Models that DO have a driver:',
    '',
]
for d in driven:
    lines.append(f'- `{d["model"]}` — {claimed[d["model"].strip().lower()]}')

with open(report_path, 'w', encoding='utf8') as fh:
    fh.write('\n'.join(lines) + '\n')

print(f'wrote {out_path}: {len(devices)} devices')
print(f'no signal connectors: {len(no_ports)}, no part number: {len(no_part)}')
