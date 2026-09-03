"""Puts the GVE survey's equipment list onto the RYG plan's line items.

WHY A LINE ITEM NEEDED ONE
--------------------------
The RYG import gave every room on the estate a date, a life and a figure off
the master refresh sheet, and nothing else. That is enough to age a room and
enough to budget it, and it is not enough to answer the first question anybody
asks about a red row - "what is actually IN there?" The line said `2 Projector`
in its notes, which is the room TYPE it was priced against, not the room.

The GVE control system has been polled for every room it manages, and that poll
is a real inventory: the projectors, the switcher, the touch panel, the camera,
by model. Joining the two gives each line item the boxes behind its figure.

WHAT THIS DOES NOT DO. It does not touch `replacementCost`. The RYG figure is
what it costs to REFRESH the room - new gear, cabling, labor, the lot - and the
equipment list is what is in there NOW, most of it a decade old. Pricing the
old list at today's catalog and calling it the refresh cost would replace a
figure somebody costed with one nobody did. The app shows both and says which
is which; see [ManualRoom.equipment].

WHAT A DEVICE IS WORTH is decided in the app, not here, so a change of pricing
tier or a corrected base-cost card reaches these rooms without a re-import.
Each line carries the model and the ROLE it plays - the base-cost card's own
words - and the app prices the model off the catalog first and the role off the
card second, the same ladder a drawn room's boxes go down.

Usage:  python tools/import_gve_equipment.py <GveSystemData.json> ["RYG campus"]
        python tools/import_gve_equipment.py <GveSystemData.json> --dry-run
"""
import argparse
import collections
import json
import os
import re
import sys

# ---------------------------------------------------------------------------
#  WHAT A SURVEYED DEVICE DOES, IN THE BASE-COST CARD'S WORDS
# ---------------------------------------------------------------------------
#  GVE files a device under its own device type. The card is written in this
#  app's words - see kCategoryAliases and categoryForConfigKey in
#  lib/base_costs.dart - and these are the same words, so a room full of models
#  the catalog has never heard of still prices off the card.
#
#  A type mapped to None is one the card has no honest line for. A document
#  camera is not any of the eighteen categories, and a VCR is not being
#  refreshed by anybody. Those report as unpriced rather than being costed at a
#  category they merely resemble - a screen controller quoted at a screen's
#  price is four figures of nonsense with nothing on the line to say so.
ROLE_BY_DEVICE_TYPE = {
    'Controller': 'Control processor',
    'Video Projector': 'Projector',
    'Camera': 'Camera',
    'Touch Display': 'Touch panel',
    'Scaler': 'Switcher',
    'Matrix Switcher': 'Switcher',
    'Switcher': 'Switcher',
    'Display': 'Display',
    'Audio Processor': 'DSP',
    'Collaboration Systems': 'Wireless presentation',
    'Streaming Media': 'Recorder / streamer',
    'Document Camera': None,
    'DVDCombo': None,
    'DVD': None,
    'VCR': None,
    'Blu Ray': None,
    'eBUS': None,
    'NBP': None,
    'Video Conference': None,
    'Other': None,
}

# ---------------------------------------------------------------------------
#  THE FAMILIES 'Other' HIDES
# ---------------------------------------------------------------------------
#  Every rack PDU and every power-control interface on the estate is filed
#  under 'Other', and between them they are a couple of hundred boxes on the
#  plan. They are not ambiguous - an AP79xx is a switched rack PDU and nothing
#  else - so they are named here rather than left unpriced.
#
#  Kept deliberately short. Anything that needs a model-by-model argument
#  belongs in the device catalog, where the app can read it.
ROLE_BY_MODEL = (
    (re.compile(r'ap79\d\d', re.I), 'Power controller'),
    (re.compile(r'^ipl t pcs', re.I), 'Power controller'),
)

# ---------------------------------------------------------------------------
#  THE CATALOG CATEGORIES THAT NAME A ROLE OUTRIGHT
# ---------------------------------------------------------------------------
#  The survey's device type is normally the role: it is what the system that
#  controls the room says the box is for. But the poll files things under a
#  type that is plainly wrong often enough to matter - twenty-three Da-Lite
#  screen controllers come back as 'Controller', which prices a relay box at a
#  control processor's figure and puts a processor in twenty-three rooms that
#  have not got one.
#
#  Where the CATALOG identifies the model and files it under a category that is
#  a role rather than a product family, the catalog wins and the disagreement
#  is reported. A model is a fact about the box; a device type is a field
#  somebody filled in.
#
#  Only these categories qualify. The families deliberately left out - 'Control
#  Systems' (processors AND touch panels), 'DTP Systems' (transmitters AND
#  matrices), 'XTP Systems', 'Audio', 'Streaming', 'Architectural', 'Fox
#  Systems', 'AV / Misc' - say what aisle a part was imported from, not what it
#  does, and would overrule a correct device type with a shrug. The words are
#  the base-cost card's own; see kCategoryAliases in lib/base_costs.dart, which
#  is where the two-way ones are translated.
ROLE_CATALOG_CATEGORIES = {
    'camera': 'Camera',
    'display': 'Display',
    'dsp': 'DSP',
    'matrix': 'Switcher',
    'power controller': 'Power controller',
    'projector': 'Projector',
    'recorder / streamer': 'Recorder / streamer',
    'screen': 'Screen',
    'switcher': 'Switcher',
    'usb': 'USB interface',
    'usb interface': 'USB interface',
    'wireless presentation': 'Wireless presentation',
}


def catalog_role(entry):
    """The role the catalog gives this model, or '' when it names only a family."""
    if not entry:
        return ''
    return ROLE_CATALOG_CATEGORIES.get(
        (entry.get('category') or '').strip().lower(), ''
    )


def norm(text):
    """Model and part numbers compared the way people mean them."""
    return re.sub(r'[^a-z0-9]', '', (text or '').lower())


def room_key(name):
    """A room number compared across two systems that punctuate it differently."""
    return re.sub(r'\s+', ' ', (name or '').strip()).upper()


# ---------------------------------------------------------------------------
#  THE CATALOG, INDEXED
# ---------------------------------------------------------------------------
def load_catalog(path):
    devices = json.load(open(path, encoding='utf-8'))['devices']
    by_model, by_part = {}, {}
    for entry in devices:
        by_model.setdefault(norm(entry.get('model')), entry)
        if entry.get('partNumber'):
            by_part.setdefault(norm(entry['partNumber']), entry)
    return by_model, by_part


def polled_model(device):
    """The model the poll actually ASSERTS, or '' when it asserts none.

    `ModelName` is the device's own reported model and is trusted outright.
    `ResolvedModelName` is the poll's own GUESS at matching that device
    against its library, and it is wrong often enough to be dangerous: an
    IPCP Pro S1 xi control processor comes back resolved as a Kramer VIA, an
    IPCP Pro 355MQ xi as a Panasonic projector. Eighteen of the estate's
    control processors resolve to something they are visibly not.

    So the guess is used only where there is nothing to be wrong about -
    where the device reported no model of its own, which is most of the
    displays and projectors and every one of them is right. One field wins
    outright rather than the two being raced against the catalog, because
    racing them is exactly how a processor became a VIA: the real model was
    not in the catalog, the wrong guess was, and the wrong one won.
    """
    own = (device.get('ModelName') or '').strip()
    if own:
        return own
    return (device.get('ResolvedModelName') or '').strip()


def catalog_match(device, by_model, by_part):
    """The catalog entry for a surveyed device, or None.

    THE PART NUMBER FIRST, because it is the one field that cannot be spelled
    two ways. Then the model the poll asserts, then that model with the
    manufacturer stripped off the front - GVE writes 'Sharp LC-80LE661U' and
    the catalog writes 'LC-80LE661U', and they are the same box.

    NO MATCH IS A FINE ANSWER. A model the catalog has never carried is still
    the right model; it just gets priced off the base-cost card by role
    instead of off a catalog price. See [role_of].
    """
    part = norm(device.get('PartNumber'))
    if part and part in by_part:
        return by_part[part]
    raw = polled_model(device)
    if not raw:
        return None
    if norm(raw) in by_model:
        return by_model[norm(raw)]
    words = raw.split()
    for cut in (1, 2):
        if len(words) > cut and norm(' '.join(words[cut:])) in by_model:
            return by_model[norm(' '.join(words[cut:]))]
    return None


def installed_model(device, entry):
    """What to call the box on the line.

    The catalog's spelling when the catalog knows it, so the app can price it
    off the catalog without matching prose a second time. Otherwise the poll's
    own spelling, which is all anybody has - and is still the answer to "what
    is in there", even when it is a projector nobody sells any more.
    """
    if entry:
        return entry['model']
    raw = polled_model(device)
    if raw:
        return raw
    # A device with no model at all is still a device in the room. Its polled
    # name is a person's label for it ('IPCP Pro 350 Arts105') and reads far
    # better than a blank.
    return (device.get('DeviceName') or '').strip()


def role_of(device, entry):
    """What the device DOES, for the base-cost card: (role, conflict).

    The survey's device type is normally the answer: it is the role, stated by
    the system that controls the room.

    THE MODEL OVERRULES IT when the two disagree and the catalog is sure. A
    model is a fact about the box; a device type is a field somebody filled
    in, and the poll files twenty-three Da-Lite screen controllers under
    'Controller'. Where the catalog identifies the model and files it under a
    category that names a ROLE - see [ROLE_CATALOG_CATEGORIES] - the catalog
    wins and the disagreement comes back in `conflict` so every one of them is
    printed rather than quietly applied.

    Where the catalog names only a FAMILY it is the fallback and not the
    referee, because 'DTP Systems' holds transmitters next to matrix switchers
    and 'Control Systems' holds processors next to touch panels. Overruling a
    correct device type with one of those would be a shrug, at scale.

    `conflict` is (surveyed role, catalog role) or None.
    """
    device_type = (device.get('DeviceType') or '').strip()
    surveyed = ROLE_BY_DEVICE_TYPE.get(device_type, '')
    from_catalog = catalog_role(entry)

    if surveyed:
        if from_catalog and from_catalog != surveyed:
            return from_catalog, (surveyed, from_catalog)
        return surveyed, None

    if device_type in ROLE_BY_DEVICE_TYPE:
        # A type the card has no line for. The catalog answers for it when it
        # can, and a handful of well-known families answer for themselves.
        if from_catalog:
            return from_catalog, None
        for pattern, role in ROLE_BY_MODEL:
            for raw in (polled_model(device), device.get('DeviceName') or ''):
                if raw.strip() and pattern.search(raw):
                    return role, None
    if entry and entry.get('category'):
        return entry['category'], None
    return '', None


# ---------------------------------------------------------------------------
#  WHICH SURVEYED ROOM IS THIS LINE ITEM
# ---------------------------------------------------------------------------
def build_room_index(rooms):
    """Every name a surveyed room answers to, pointing at the room.

    ONE POLL, SEVERAL ROOMS. A divisible lecture hall is one control system and
    the poll names it for both halves - 'FAEC 111 117'. Each half is its own
    line on the plan, so both names have to reach the same device list, and the
    match is recorded as shared so nobody adds the two halves together.
    """
    exact, alias = {}, {}
    for room in rooms:
        key = room_key(room.get('RoomName'))
        if not key:
            continue
        exact[key] = room
        # 'FAEC 111 117' - a building code and two or more room numbers.
        parts = key.split()
        if len(parts) > 2 and all(re.fullmatch(r'\d+[A-Z]?', p) for p in parts[1:]):
            for number in parts[1:]:
                alias.setdefault(f'{parts[0]} {number}', room)
    return exact, alias


def find_room(name, exact, alias):
    """The surveyed room for a line item: (room, how) or (None, '')."""
    key = room_key(name)
    if key in exact:
        return exact[key], 'exact'
    if key in alias:
        return alias[key], 'shared'
    # 'SCI 126a/b' on the plan, 'SCI 126A' in the poll. Take the first number
    # off a slashed pair and try it on its own.
    head = key.split('/')[0].strip()
    if head != key and head in exact:
        return exact[head], 'shared'
    # A lettered half of a room the poll knows only by its base number:
    # 'CLSA 100A' against 'CLSA 100'.
    stripped = re.sub(r'(\d+)[A-Z]$', r'\1', key)
    if stripped != key and stripped in exact:
        return exact[stripped], 'shared'
    return None, ''


# ---------------------------------------------------------------------------
#  ONE ROOM'S LIST
# ---------------------------------------------------------------------------
def equipment_for(room, by_model, by_part, conflicts=None):
    """The surveyed room as line-item equipment: model, role, how many.

    Rolled up by model, because a room with two identical projectors is a
    quantity of two and not two rows a reader has to notice are the same. The
    order is the order the poll returned, which puts the controller and the
    switcher at the top - the way somebody reading a rack would list it.

    Every place the model overruled the survey's device type is appended to
    [conflicts], so a re-import can print the lot instead of correcting
    twenty-three rooms without saying so.
    """
    order, rolled = [], {}
    for device in room.get('Devices', []):
        if (device.get('Status') or '').strip().lower() == 'inactive':
            continue
        entry = catalog_match(device, by_model, by_part)
        model = installed_model(device, entry)
        if not model:
            continue
        role, conflict = role_of(device, entry)
        if conflict is not None and conflicts is not None:
            conflicts.append((room.get('RoomName'), model, conflict[0], conflict[1]))
        key = (norm(model), role)
        if key not in rolled:
            rolled[key] = {'model': model, 'category': role, 'quantity': 0}
            order.append(key)
        rolled[key]['quantity'] += 1
    out = []
    for key in order:
        item = rolled[key]
        line = {'model': item['model']}
        if item['category']:
            line['category'] = item['category']
        line['quantity'] = item['quantity']
        out.append(line)
    return out


# A note this script wrote on an earlier run, so re-running replaces it instead
# of stacking a second copy on the end of the notes.
SURVEY_NOTE = re.compile(r'\s*·\s*GVE survey[^·]*')


def note_with_survey(notes, gve_name, how):
    """The line's notes, saying where a NON-obvious list came from.

    A room whose poll is its own name needs no annotation - the list is the
    room. A room reading someone else's poll, or a shared one, does: the two
    halves of FAEC 111 117 both show ten boxes and there are ten between them.
    """
    text = SURVEY_NOTE.sub('', notes or '').strip()
    if how == 'exact':
        return text
    tail = f'GVE survey {gve_name} (shared)'
    return f'{text}  ·  {tail}' if text else tail


def what_changed(room_name, before, after):
    """What this run says that the plan does not already say.

    A re-import is usually a no-op, and the times it is not are the times
    somebody needs to look: a poll that has been corrected, a catalog entry
    that has been added, a room that has been rebuilt. Every difference is
    reported as a line rather than left in a diff nobody runs.

    Matched by ROLE, not by position, so one box changing model does not read
    as the whole room having been replaced.
    """
    def index(items):
        out = {}
        for item in items or []:
            key = (item.get('category') or '', norm(item.get('model')))
            out[key] = item
        return out

    was, now = index(before), index(after)
    if was == now:
        return []

    def say(item):
        role = item.get('category') or 'no role'
        count = item.get('quantity', 1)
        tail = f' x{count}' if count != 1 else ''
        return f"{item.get('model')}{tail} ({role})"

    lines = []
    for key in was:
        if key not in now:
            lines.append((room_name, say(was[key]), 'gone'))
        elif was[key].get('quantity', 1) != now[key].get('quantity', 1):
            lines.append((room_name, say(was[key]), say(now[key])))
    for key in now:
        if key not in was:
            lines.append((room_name, 'nothing', say(now[key])))
    return lines


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('gve', help='GveSystemData.json from the extron_debugger poll')
    ap.add_argument('plan', nargs='?', default='RYG campus',
                    help='folder of *_project.json files (default: "RYG campus")')
    ap.add_argument('--catalog', default='av_devices.json')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args(argv)

    rooms = json.load(open(args.gve, encoding='utf-8'))['data']['Rooms']
    by_model, by_part = load_catalog(args.catalog)
    exact, alias = build_room_index(rooms)

    files = sorted(f for f in os.listdir(args.plan) if f.endswith('_project.json'))
    if not files:
        print(f'No project files under {args.plan}', file=sys.stderr)
        return 1

    matched = missed = 0
    devices = unpriced_roles = 0
    misses = []
    by_role = collections.Counter()
    no_catalog = collections.Counter()
    # Where the model overruled the poll's device type, and where this run
    # disagrees with what is already on the plan. Both are printed: a re-import
    # that silently corrects twenty-three rooms is a re-import nobody can check.
    conflicts = []
    corrections = []

    for name in files:
        path = os.path.join(args.plan, name)
        project = json.load(open(path, encoding='utf-8'))
        changed = False
        for line in project.get('manualRooms', []):
            room, how = find_room(line.get('name'), exact, alias)
            if room is None:
                missed += 1
                misses.append(line.get('name'))
                # A re-run after a room LEFT the poll takes the stale list off
                # rather than leaving last month's inventory on the plan.
                if line.pop('equipment', None) is not None:
                    changed = True
                note = note_with_survey(line.get('notes'), '', 'exact')
                if note != (line.get('notes') or ''):
                    line['notes'] = note
                    changed = True
                continue
            matched += 1
            items = equipment_for(room, by_model, by_part, conflicts)
            corrections.extend(
                what_changed(line.get('name'), line.get('equipment'), items)
            )
            devices += sum(i['quantity'] for i in items)
            for item in items:
                role = item.get('category', '')
                by_role[role or '(no role)'] += item['quantity']
                if not role:
                    unpriced_roles += item['quantity']
                if norm(item['model']) not in by_model:
                    no_catalog[item['model']] += item['quantity']
            if items:
                line['equipment'] = items
            else:
                line.pop('equipment', None)
            note = note_with_survey(line.get('notes'), room.get('RoomName'), how)
            if note != (line.get('notes') or ''):
                line['notes'] = note
            changed = True
        if changed and not args.dry_run:
            with open(path, 'w', encoding='utf-8') as handle:
                json.dump(project, handle, indent=4, ensure_ascii=False)
                handle.write('\n')

    print(f'Line items with a surveyed room  : {matched}')
    print(f'Line items the poll has never seen: {missed}')
    print(f'Devices written                  : {devices}')
    print(f'Devices with no role for the card: {unpriced_roles}')
    print()
    print('By role:')
    for role, count in by_role.most_common():
        print(f'  {count:>5}  {role}')
    print()
    print(f'Models the catalog has never heard of: {len(no_catalog)} '
          f'({sum(no_catalog.values())} boxes) - priced off the card by role')
    for model, count in no_catalog.most_common(20):
        print(f'  {count:>5}  {model}')
    if conflicts:
        print()
        print(f'The model overruled the device type the poll filed it under, '
              f'in {len(conflicts)} place(s):')
        rolled = collections.Counter(
            (model, was, now) for _room, model, was, now in conflicts
        )
        for (model, was, now), count in rolled.most_common():
            print(f'  {count:>5}  {model}: filed as {was}, priced as {now}')

    if corrections:
        print()
        print(f'CHANGED against what was already on the plan '
              f'({len(corrections)} line(s)):')
        for room_name, before, after in corrections:
            print(f'  {room_name}: {before}  ->  {after}')

    if misses:
        print()
        print(f'No surveyed room for: {", ".join(sorted(misses))}')
    if args.dry_run:
        print('\n(dry run - nothing written)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
