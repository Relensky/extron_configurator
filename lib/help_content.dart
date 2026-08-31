/// ============================================================================
///  THE HELP BOOK
/// ============================================================================
///  Every feature this app has, written down once, in the app, searchable.
///
///  WHY IT IS DART AND NOT A PDF. There is a guide in `documentation/` and it is
///  a good one, and it is also a file somebody has to find, open in another
///  window and search separately - which on a laptop with a drawing open is a
///  thing that does not get done. Somebody stuck on the Vendors pane wants to
///  know what the Vendors pane does, now, without leaving it. So the book lives
///  here: no asset to load, no file to ship alongside the exe, no version of it
///  on somebody's desktop that is eighteen months old.
///
///  WHAT A TOPIC IS. One feature, answered. [title] is what somebody would call
///  it, [where] is how to get to it, [body] is what it does and why it works
///  the way it does, and [keywords] are the words somebody would actually type
///  when they do not know what it is called - "RFQ" for quote requests, "RYG"
///  for the refresh plan, "MSRP" for the pricing tier.
///
///  THE SEARCH IS OVER ALL OF IT. Title, section, where, keywords and body - so
///  a search for "PO" finds the purchase order topics whether or not any of
///  their titles say PO, and a search for a phrase somebody half-remembers off
///  a button finds the topic that button belongs to. See [searchHelp].
///
///  KEEPING IT HONEST. A topic naming a control that no longer exists is worse
///  than no topic, so the keys named in [where] are the ones on screen, and
///  help_test.dart holds the shape: every topic has a section, a where and a
///  body, no two share a title, and the sections are the panes this app really
///  has.
/// ============================================================================
library;

/// One feature, answered.
class HelpTopic {
  /// What somebody would call this - the words on the button or the tab.
  final String title;

  /// Which part of the app it belongs to. Topics are grouped by it, and it is
  /// searched, so "campus" finds everything on the campus report.
  final String section;

  /// How to get to it, said as a path through the app: 'Project tab →
  /// Vendors'. Never a coordinate on a screen, which changes; always the names
  /// of the things that are pressed.
  final String where;

  /// What it does, why it works that way, and what it does NOT do. Written as
  /// prose paragraphs separated by blank lines.
  final String body;

  /// What somebody would type when they do not know what it is called.
  final List<String> keywords;

  const HelpTopic({
    required this.title,
    required this.section,
    required this.where,
    required this.body,
    this.keywords = const [],
  });

  /// Everything about this topic as one lower-cased haystack.
  ///
  /// CACHED OUTSIDE THE CLASS because the book is `const` - a const object
  /// cannot hold a lazily computed field, and the book being const is worth
  /// more than the tidiness: it is checked at compile time and costs nothing
  /// to hold. The search runs on every character somebody types, so building
  /// fifty joined strings per keystroke is the thing being avoided here.
  String get haystack => _haystacks.putIfAbsent(
    title,
    () => [title, section, where, body, ...keywords].join(' ').toLowerCase(),
  );
}

/// One entry per topic, filled on first search and kept. Keyed by title, which
/// help_test.dart holds unique.
final Map<String, String> _haystacks = {};

/// Topics matching [query], best first; everything when the query is blank.
///
/// ============================================================================
///  RANKED, NOT FILTERED
/// ============================================================================
///  A word typed into this box turns up in the body of half the book - "price"
///  is in thirty topics - and a flat list of thirty in file order buries the
///  one called "Pricing tier" somewhere in the middle. So a hit in the TITLE
///  outranks a hit in the keywords, which outranks a hit in the section, which
///  outranks a hit anywhere in the prose. What somebody typed is nearly always
///  the name of the thing they want.
///
///  EVERY WORD HAS TO BE SOMEWHERE. Multi-word queries are AND, not OR: "vendor
///  quote" means both, because a search that returned everything about vendors
///  plus everything about quotes has answered a question nobody asked.
///
///  A WHOLE WORD BEATS A FRAGMENT OF ONE. Matching is substring - it has to be,
///  or "vendor" would miss "vendors" and nobody would type the singular twice -
///  and the cost of that is that "rack" is inside "tracks". So a word that
///  lands on a word BOUNDARY scores above one buried mid-word, which is what
///  puts "Rack elevations" above "Phases and tracks" for somebody who typed
///  rack.
List<HelpTopic> searchHelp(String query, {List<HelpTopic>? within}) {
  final topics = within ?? kHelpTopics;
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return List.unmodifiable(topics);

  final scored = <({HelpTopic topic, int score})>[];
  for (final topic in topics) {
    var score = 0;
    var all = true;
    for (final word in words) {
      if (!topic.haystack.contains(word)) {
        all = false;
        break;
      }
      final title = topic.title.toLowerCase();
      if (title.contains(word)) {
        score += _wholeWord(title, word) ? 10 : 8;
      } else if (topic.keywords.any((k) => k.toLowerCase().contains(word))) {
        score += 4;
      } else if (topic.section.toLowerCase().contains(word)) {
        score += 2;
      } else {
        score += _wholeWord(topic.haystack, word) ? 2 : 1;
      }
    }
    if (all) scored.add((topic: topic, score: score));
  }

  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0
        ? byScore
        : a.topic.title.toLowerCase().compareTo(b.topic.title.toLowerCase());
  });
  return [for (final s in scored) s.topic];
}

/// True when [word] appears in [text] on a word boundary rather than buried
/// inside a longer one - 'rack' in 'rack elevations' but not in 'tracks'.
bool _wholeWord(String text, String word) {
  var from = 0;
  while (true) {
    final at = text.indexOf(word, from);
    if (at < 0) return false;
    // Only the START has to be a boundary. Somebody typing 'vendor' means
    // 'vendors' too, and a rule that demanded both ends would send them back
    // to the box to try the plural - while the start alone is enough to keep
    // 'rack' out of 'tracks', which is the failure this exists for.
    if (at == 0 || !_isWordChar(text.codeUnitAt(at - 1))) return true;
    from = at + 1;
  }
}

bool _isWordChar(int code) =>
    (code >= 48 && code <= 57) || // 0-9
    (code >= 97 && code <= 122) || // a-z
    (code >= 65 && code <= 90); // A-Z

/// The sections, in the order the book presents them — roughly the order
/// somebody meets them: the room first, then the drawings off it, then the
/// money, then the job, then the estate, then the machinery underneath.
List<String> get helpSections {
  final seen = <String>{};
  return [
    for (final t in kHelpTopics)
      if (seen.add(t.section)) t.section,
  ];
}

/// The topics in one section, in book order.
List<HelpTopic> helpSection(String section) => [
  for (final t in kHelpTopics)
    if (t.section == section) t,
];

/// ============================================================================
///  THE BOOK
/// ============================================================================
const List<HelpTopic> kHelpTopics = [
  // ---------------------------------------------------------------------------
  //  START HERE
  // ---------------------------------------------------------------------------
  HelpTopic(
    title: 'What this app is for',
    section: 'Start here',
    where: 'Everywhere',
    keywords: ['overview', 'intro', 'getting started', 'what is this'],
    body:
        'You describe a room once - what is in it, what plugs into what, when '
        'it went in - and the app writes the processor\'s config.json and '
        'draws everything else off the same description.\n\n'
        'From one room you get a control schematic, an AV signal flow, rack '
        'elevations, a floor plan, a cable schedule and a priced estimate. '
        'From a folder of rooms you get a building: a master parts list, '
        'vendor packages, purchase orders, a delivery log and a refresh plan. '
        'From a folder of buildings you get an estate.\n\n'
        'Nothing on any of those is typed twice. A model changed on the '
        'drawing changes the quote, the rack, the cable schedule and the '
        'twenty-year plan, because all five are readings of one description '
        'rather than five documents to keep in step.',
  ),
  HelpTopic(
    title: 'Where the app keeps your rules',
    section: 'Start here',
    where: 'App Config tab, and the Schema, Flow Rules and Catalog tabs',
    keywords: [
      'json',
      'settings',
      'files',
      'ui_schema',
      'av_flow_rules',
      'av_devices',
      'configuration',
    ],
    body:
        'Almost nothing about YOUR rooms is compiled into the program. It is '
        'in plain JSON files beside it, and every one has an editor in the '
        'app:\n\n'
        'ui_schema.json decides how each config key looks on screen - its '
        'label, its description, whether it is a dropdown or a switch. Edited '
        'on the Schema tab.\n\n'
        'av_flow_rules.json decides how a room turns into a drawing: which '
        'box a config key means, what goes between two ends that do not '
        'match. Edited on the Flow Rules tab.\n\n'
        'av_devices.json is the equipment catalog - connectors, rack units, '
        'power draw, price, life. Edited on the Catalog tab.\n\n'
        'base_costs.json and labor_rates.json are what the estimate falls back '
        'to when no model has been chosen yet. Edited from the Cost tab.\n\n'
        'If the app does something you do not want, the fix is usually a rule '
        'or a schema entry rather than a new build.',
  ),
  HelpTopic(
    title: 'Pricing tier - list or education',
    section: 'Start here',
    where: 'App Config tab → Pricing',
    keywords: ['msrp', 'list price', 'education', 'edu', 'tier', 'discount'],
    body:
        'Every price in this app is published at two tiers: MSRP (list) and '
        'the education / institutional price. The tier you pick here is the '
        'one every estimate, every replacement figure and every report is '
        'quoted at.\n\n'
        'A catalog entry or a base cost card with only one of the two figures '
        'filled in falls back to the other rather than reading as free, and '
        'says it fell back. That is deliberate: a missing price is a gap '
        'somebody has to close, and costing it at nothing hides it.',
  ),

  // ---------------------------------------------------------------------------
  //  THE ROOM
  // ---------------------------------------------------------------------------
  HelpTopic(
    title: 'Building a room from a preset',
    section: 'The room',
    where: 'Wizard tab',
    keywords: ['new room', 'preset', 'template', 'start', 'wizard'],
    body:
        'The wizard walks the settings a room actually needs, in the order '
        'somebody thinks about them, and writes the config.json at the end. '
        'Presets are whole starting points - an active learning room, a '
        'standard classroom - that you then edit rather than build from '
        'nothing.\n\n'
        'Everything the wizard writes is editable afterwards on the ordinary '
        'tabs. It is a faster start, never a separate kind of room.',
  ),
  HelpTopic(
    title: 'Opening and converting an older config',
    section: 'The room',
    where: 'Open, from the title bar',
    keywords: ['load', 'legacy', 'key map', 'migrate', 'convert', 'old file'],
    body:
        'A config written against an older key set is translated on load using '
        'key_map.json, and what was translated is shown rather than done '
        'quietly - the Conversion preview lists every key that changed name so '
        'you can see what the app did before saving over anything.\n\n'
        'Keys the app does not recognise are KEPT, not dropped. A room can '
        'carry settings this app has never heard of and still round-trip '
        'through it unharmed.',
  ),
  HelpTopic(
    title: 'Devices in a room, and their drivers',
    section: 'The room',
    where: 'Devices tab',
    keywords: ['driver', 'module', 'python', 'control', 'model'],
    body:
        'Each device in the room has a model and, where something drives it, a '
        'python module. Where the two disagree - a model swapped without the '
        'driver following it - the app says so rather than writing a config '
        'that will not commission.\n\n'
        'Some equipment is never driven by anything: a USB capture stick, a '
        'passive splitter, a wall plate. Those are marked on the CATALOG entry '
        'rather than on each room, so the control-gap report stops nagging '
        'about a thing that can never be fixed.',
  ),
  HelpTopic(
    title: 'Pushing a config to the processor',
    section: 'The room',
    where: 'Title bar → Send',
    keywords: ['sftp', 'upload', 'deploy', 'processor', 'push', 'send'],
    body:
        'The finished config.json goes to the processor over SFTP. The app '
        'writes the file it has just shown you - there is no separate export '
        'step and no second copy that can drift from what is on screen.',
  ),

  // ---------------------------------------------------------------------------
  //  THE DRAWINGS
  // ---------------------------------------------------------------------------
  HelpTopic(
    title: 'Control schematic',
    section: 'The drawings',
    where: 'Schematic tab',
    keywords: ['control', 'diagram', 'processor', 'topology'],
    body:
        'What talks to the processor and how - IP, serial, relay, IR. Drawn '
        'from the config rather than laid out by hand, so a device added on '
        'the Devices tab appears here without anybody redrawing anything.\n\n'
        '"Recreate from config" rebuilds the whole picture from the room as it '
        'stands now, which is what to reach for after a big edit.',
  ),
  HelpTopic(
    title: 'AV signal flow',
    section: 'The drawings',
    where: 'AV Flow tab',
    keywords: ['signal', 'flow', 'hdmi', 'switcher', 'routing', 'diagram'],
    body:
        'What plugs into what, drawn from the switcher input and output '
        'numbers already typed on the config. Where two ends do not match - a '
        'display on the far side of a building, a USB device on the wrong side '
        'of a switcher - the flow rules decide what goes between them, and the '
        'routing report says what it chose and why.\n\n'
        'Rooms with no switcher, and rooms with a USB switcher hanging off the '
        'main one, are both drawn correctly; they are the two shapes the rules '
        'spend most of their effort on.\n\n'
        'The drawing can be edited by hand where the rules get it wrong, and '
        'what you moved survives a redraw.',
  ),
  HelpTopic(
    title: 'Rack elevations',
    section: 'The drawings',
    where: 'Racks tab',
    keywords: ['rack', 'ru', 'elevation', 'shelf', 'blank', 'vent'],
    body:
        'Every racked box on its rails, at the height the catalog says it is. '
        'Boxes can be dragged between rails and between racks.\n\n'
        'A catalog entry can also declare CLEARANCE - rails it wants kept '
        'empty above or below, for an amplifier that vents upwards or a shelf '
        'whose lid opens. The rack shades those rails and still lets you drop '
        'something there: the person in front of the frame knows things the '
        'catalog does not, and a tool that refuses a placement is a tool people '
        'stop recording placements in.',
  ),
  HelpTopic(
    title: 'Floor plan',
    section: 'The drawings',
    where: 'Floor Plan tab',
    keywords: ['plan', 'layout', 'location', 'room drawing', 'annotate'],
    body:
        'A picture of the room with the equipment placed on it. Locations '
        'defined here are what the cable schedule measures between and what '
        'the lifecycle report names a position by, so a box placed on the plan '
        'stops being "Display 2" and starts being "Display 2, north wall".',
  ),
  HelpTopic(
    title: 'Cabling and the cable schedule',
    section: 'The drawings',
    where: 'Cabling tab',
    keywords: ['cable', 'schedule', 'run', 'length', 'pull', 'conduit'],
    body:
        'Every run on the AV flow, with the type it carries and the length it '
        'needs, worked out from the locations on the floor plan. Runs can be '
        'routed by hand where the straight line is wrong.\n\n'
        'The schedule prices itself off the catalog: a made-up lead of the '
        'right length where the catalog has one, and bulk cable where it does '
        'not. Cable colours are yours to set and travel with the drawing.',
  ),

  // ---------------------------------------------------------------------------
  //  THE MONEY
  // ---------------------------------------------------------------------------
  HelpTopic(
    title: 'The cost estimate',
    section: 'The money',
    where: 'Cost tab',
    keywords: ['estimate', 'quote', 'price', 'money', 'total', 'bid'],
    body:
        'What this room costs, built from the boxes on the drawing, the cable '
        'schedule and the labour rates.\n\n'
        'Every line says where its price came from: the catalog\'s figure for '
        'that model, a base cost card figure for its category, or a price '
        'typed on the line itself. A price the app had to guess at is marked '
        'as an estimate rather than mixed in with the ones that are real - a '
        'typical price presented as a quote is how a budget goes wrong '
        'quietly.',
  ),
  HelpTopic(
    title: 'Base costs - the category rate card',
    section: 'The money',
    where: 'Cost tab → Base costs',
    keywords: [
      'base cost',
      'rate card',
      'typical price',
      'category price',
      'fallback',
      'budget',
    ],
    body:
        'One typical unit price per kind of device, at both tiers. What the '
        'estimate falls back to when a room has a switcher on the diagram but '
        'no model chosen yet, and what the refresh plan budgets a position at '
        'when the catalog has no price for its model.\n\n'
        'A card can also record WHICH product its figure was benchmarked on '
        'and when - see "Current models" on the campus report, which is where '
        'that gets set. A figure with a model and a date behind it is one a '
        'finance office can argue with; one without is a number.\n\n'
        '0 means "not set" and is reported as an unpriced line rather than '
        'costed at nothing.',
  ),
  HelpTopic(
    title: 'Labour rates',
    section: 'The money',
    where: 'Cost tab → Labour rates',
    keywords: ['labor', 'labour', 'hours', 'rate', 'install', 'engineer'],
    body:
        'What an hour of each role costs, and how many hours the estimate '
        'assumes per kind of work. A role nobody has priced reports as '
        'unfilled rather than as free.',
  ),
  HelpTopic(
    title: 'Spares',
    section: 'The money',
    where: 'Cost tab → Spares',
    keywords: ['spare', 'attic stock', 'extra', 'shelf'],
    body:
        'Parts bought for the shelf rather than for a position on the drawing. '
        'They keep their place on the quote and on the master parts list, and '
        'they are counted separately everywhere it matters - a spare is not a '
        'room that has been done.',
  ),
  HelpTopic(
    title: 'Swapping a unit for another',
    section: 'The money',
    where: 'Cost tab → the swap control on a line',
    keywords: ['swap', 'substitute', 'change model', 'alternative'],
    body:
        'Quote a different part on a line without redrawing the room. The swap '
        'is recorded, so what was originally specified and what was actually '
        'quoted are both still readable later.\n\n'
        'To change a product everywhere on a whole job at once, use the '
        'project-level swap on the Project tab instead.',
  ),

  // ---------------------------------------------------------------------------
  //  THE JOB
  // ---------------------------------------------------------------------------
  HelpTopic(
    title: 'What a project is',
    section: 'The job',
    where: 'Project tab',
    keywords: ['project', 'building', 'job', 'rollup'],
    body:
        'A building, quoted as one job: a list of rooms, everything they need '
        'merged into one parts list, and the vendors, orders, deliveries, '
        'dates and refresh plan that go with it.\n\n'
        'The panes across the top are readings of the same job. Whichever one '
        'is open, the figure in the header is what the building costs.',
  ),
  HelpTopic(
    title: 'Rooms on a job',
    section: 'The job',
    where: 'Project tab → Rooms',
    keywords: ['rooms', 'add room', 'alternate', 'included', 'line item'],
    body:
        'Which configs are on the job and what each comes to. A room can be '
        'excluded from the rollup without being removed - two versions of one '
        'lecture hall, both priced, one chosen.\n\n'
        'Rooms that have never been through this app can be typed in as LINE '
        'ITEMS: a name, a date, a life and a figure. Most of an estate has '
        'never been drawn, and a refresh plan covering only the rooms that '
        'have is a plan for a fraction of the building.',
  ),
  HelpTopic(
    title: 'The master parts list',
    section: 'The job',
    where: 'Project tab → Equipment',
    keywords: [
      'parts',
      'master list',
      'equipment',
      'bom',
      'bill of materials',
      'filter',
    ],
    body:
        'Every part on the job once, with quantities merged across rooms, '
        'tagged to the vendor that will quote it.\n\n'
        'The chips across the top narrow the list: to one vendor, to the parts '
        'nothing has claimed, to the ones with no price, to the devices '
        'nothing can drive, to spares. The counts on those chips are the job\'s '
        'own to-do list - a building is not ready to go out for quotes while '
        'anything is untagged or unpriced.\n\n'
        'Rows can be selected in bulk to set a lead time or a vendor across '
        'many at once.',
  ),
  HelpTopic(
    title: 'Vendors and the rules that tag parts',
    section: 'The job',
    where: 'Project tab → Vendors',
    keywords: [
      'vendor',
      'supplier',
      'reseller',
      'distributor',
      'rules',
      'manufacturer',
      'category',
      'tag',
    ],
    body:
        'One vendor per company you send quote requests to, each with the '
        'MANUFACTURERS and CATEGORIES it sells.\n\n'
        'A part is tagged by the FIRST vendor whose rules claim it. '
        'Manufacturer rules are checked before category rules, so an Extron '
        'rule beats "AV reseller for speakers" on an Extron speaker. Order '
        'matters: drag a vendor up its list to give it priority.\n\n'
        'Both rule boxes offer a TICK-LIST built from what the job actually '
        'holds, with a count beside each - "Display (18)" against "Screen '
        '(2)". Rules are matched exactly, so typing "Extron Electronics" '
        'against a catalog that says "Extron" writes a rule that claims '
        'nothing and says nothing about it; ticking cannot go wrong that way. '
        'The typed box is still there for a maker or category the job has no '
        'parts in yet.\n\n'
        'The count chip on a vendor card - "19 lines, \$18,400" - opens the '
        'Equipment list already narrowed to exactly those parts.',
  ),
  HelpTopic(
    title: 'Quote requests - where a vendor has got to',
    section: 'The job',
    where: 'Project tab → Vendors, and the Timeline',
    keywords: [
      'rfq',
      'quote request',
      'quote',
      'sent',
      'quoted',
      'ordered',
      'waiting',
      'chase',
    ],
    body:
        'Four states, read off three dates. Not sent, sent, quoted, ordered - '
        'and every vendor card says which, on the row, so a list of six '
        'vendors answers "which of these are we still waiting on" without any '
        'of them being opened.\n\n'
        'Recording a quote takes when it came back, for how much, and the '
        'vendor\'s own quote number - the three things needed to compare six '
        'quotes against each other and against the job\'s own figure. The gap '
        'between what the vendor wants and what the job estimated is shown on '
        'the card, which is the whole reason a quote gets read.\n\n'
        'The quote PDF is attached in the same dialog, at the moment somebody '
        'has it in front of them. Nothing is copied - the project stores where '
        'the file IS, so moving it moves what this opens.\n\n'
        'Recording a quote changes no price on the job. The estimate stays '
        'what the parts say.',
  ),
  HelpTopic(
    title: 'Marking a vendor ordered',
    section: 'The job',
    where: 'Project tab → Vendors → Ordered...',
    keywords: ['order', 'po', 'purchase order', 'raise', 'buy'],
    body:
        'One action that makes three things true: it raises the purchase '
        'order, points it at this vendor, and puts every part this vendor is '
        'quoting onto it.\n\n'
        'That last one is the link back from a PO number to the equipment it '
        'bought. Before it existed the first two got done and the third did '
        'not, which leaves a PO nobody can trace to any equipment and nineteen '
        'parts reading on the timeline as things nobody has bought.\n\n'
        'The parts default to the WHOLE package, because that is what a '
        'purchase order to one vendor almost always is. Ordering only part of '
        'it? Do this, then untick the rest on the PO\'s own list on the '
        'Deliveries pane.\n\n'
        'The signed order is attached here too, at the one moment somebody has '
        'the PDF.',
  ),
  HelpTopic(
    title: 'Purchase orders and the delivery log',
    section: 'The job',
    where: 'Project tab → Deliveries',
    keywords: [
      'po',
      'purchase order',
      'delivery',
      'received',
      'arrived',
      'shipment',
      'log',
      'storage',
    ],
    body:
        'A row per purchase order, what is on it, and how much of that has '
        'landed. Each PO can carry the order document itself - a PDF, a scan, '
        'the vendor\'s acknowledgement as a .msg - and the app opens what it '
        'can draw in-app and hands the rest to the machine.\n\n'
        'Deliveries are logged against a PO or as one-offs. A delivery says '
        'where it went: a dock, an address, or general storage. Gear held '
        'rather than installed is tracked as held, so "we have it, it is just '
        'not in the room yet" is a state the job can be in.\n\n'
        'Every PO number the job mentions ANYWHERE - on a vendor, on a part, '
        'on an earlier delivery - is one click away in the PO boxes rather '
        'than something to retype and mistype. Numbers the job knows but has '
        'no row for are offered when adding one.',
  ),
  HelpTopic(
    title: 'The delivery timeline',
    section: 'The job',
    where: 'Project tab → Timeline',
    keywords: [
      'timeline',
      'schedule',
      'lead time',
      'order by',
      'deadline',
      'late',
      'calendar',
      'graph',
    ],
    body:
        'When each part has to be BOUGHT, worked back from the day the '
        'building has to be finished and how long each part takes to arrive.\n\n'
        'Parts that have to arrive earlier than the rest - screens, mounts, '
        'floor boxes, conduit - carry their own need-by date, which is why an '
        'order date can fall two months before a job whose deadline is in '
        'June.\n\n'
        'Read as a list of DAYS rather than a list of parts: an order date is '
        'a trip to the purchasing office, and eleven parts sharing one is one '
        'trip.\n\n'
        'Above the list, the whole job is drawn on one rail - today, the first '
        'order, each phase\'s on-site day, every order date as a dot, each '
        'vendor\'s quote request, and the delivery deadline. Nothing on it is '
        'a new fact; it is the same schedule seen from far enough away to have '
        'a shape.',
  ),
  HelpTopic(
    title: 'Zooming the date rail',
    section: 'The job',
    where: 'Project tab → Timeline → the arrows on THE DATES card',
    keywords: ['zoom', 'fit', 'multi year', 'rail', 'graph', 'scroll'],
    body:
        'Fitted, the rail shows the whole job. On a three-year refresh that is '
        'about four days per pixel, which makes every date in a fortnight one '
        'dot - so it zooms, as far as thirty-two times, at which point three '
        'years of rail is about six weeks in the frame.\n\n'
        'The readout between the arrows says how much of the job is in front '
        'of you - "3.0 yr", "9 mo", "6 wk" - rather than a percentage, because '
        'a stretch of time is the number somebody wants off a calendar.\n\n'
        'Zooming holds the middle of the frame rather than jumping back to the '
        'start, and the fit button brings the whole job back from wherever you '
        'had got to.',
  ),
  HelpTopic(
    title: 'Phases and tracks',
    section: 'The job',
    where: 'Project tab → Timeline → the phase strip',
    keywords: ['phase', 'track', 'infrastructure', 'sequence', 'stage'],
    body:
        'A job is rarely one delivery. Infrastructure goes in while the walls '
        'are open, weeks before the rack arrives, so phases each carry their '
        'own delivery date and the parts on them are scheduled against it.\n\n'
        'The reading this exists for is whether the infrastructure order going '
        'in months before the tech order actually lines up with when the walls '
        'close.',
  ),
  HelpTopic(
    title: 'The responsibility matrix',
    section: 'The job',
    where: 'Project tab → Responsibility',
    keywords: [
      'responsibility',
      'matrix',
      'furnished by',
      'installed by',
      'scope',
      'contractor',
      'owner',
      'division of work',
    ],
    body:
        'Who furnishes and who installs each line of scope, room by room. The '
        'document that settles "we thought you were pulling that conduit".\n\n'
        'Each party carries its own colour, the same one wherever its name '
        'appears, so one contractor\'s share of the sheet is visible without '
        'reading a cell. A line nobody has been named on reads NOBODY in the '
        'error colour - a blank is the exact thing this sheet exists to '
        'catch.\n\n'
        'Hovering any cell lights the whole line right across the sheet, '
        'frozen room column included. The sheet zooms and fits, and each scope '
        'column can carry a cutsheet that opens in the app.\n\n'
        'It goes out two ways: a spreadsheet for the people who work from it, '
        'and a picture for the people who only have to see it.',
  ),
  HelpTopic(
    title: 'To-dos, notes and reminders on a job',
    section: 'The job',
    where: 'Project tab → To-do and Notes',
    keywords: ['todo', 'to do', 'note', 'reminder', 'ics', 'calendar', 'task'],
    body:
        'Open questions and decisions recorded against the job. Notes are '
        'signed and dated for you, so who said what and when survives the '
        'person who said it moving on.\n\n'
        'Order dates can be exported as an ICS calendar - one all-day event '
        'per order date with an alarm a week before - because the purchase '
        'order is raised by somebody who lives in Outlook and will never open '
        'this app.',
  ),
  HelpTopic(
    title: 'Project history',
    section: 'The job',
    where: 'Project tab → History',
    keywords: ['history', 'audit', 'log', 'who changed', 'undo', 'provenance'],
    body:
        'Every edit to the job, under the thing it was about. "This says '
        'bought - who said so, and when" is asked of the PART, and a single '
        'line on the vendor cannot answer it, so orders, quotes, prices and '
        'dates are all logged against both.',
  ),

  // ---------------------------------------------------------------------------
  //  THE REFRESH PLAN
  // ---------------------------------------------------------------------------
  HelpTopic(
    title: 'How old the gear is, and when it falls due',
    section: 'The refresh plan',
    where: 'Lifecycle tab, and Project tab → Lifecycle',
    keywords: [
      'lifecycle',
      'refresh',
      'ryg',
      'replacement',
      'age',
      'due',
      'red amber green',
      'life',
    ],
    body:
        'Every position in a room, how long it has been in, and the year it '
        'falls due. The install year is year one.\n\n'
        'The bands are the RYG sheet\'s bands: on an eight-year cycle, green '
        'for years one to five and amber for six to eight, then red. Amber is '
        'graded rather than flat, because three years of it are not one '
        'state.\n\n'
        'The life a position is held to comes from three places, most specific '
        'first: the position itself ("this one, sooner"), the catalog entry '
        'for its model ("this product does six"), and the blanket cycle for '
        'anything nobody has said. Each row says which of the three it '
        'used.\n\n'
        'A position with no install date reads UNKNOWN and says so. Jack '
        'fields, patch panels, mounts and poles can be taken off the cycle by '
        'hand - they are still tracked, just not on the plan.',
  ),
  HelpTopic(
    title: 'What a replacement costs',
    section: 'The refresh plan',
    where: 'Lifecycle tab',
    keywords: [
      'replacement cost',
      'budget',
      'refresh cost',
      'typical price',
      'retired',
      'discontinued',
    ],
    body:
        'The catalog\'s price for the model, and failing that the base cost '
        'card\'s figure for its category. A figure off the card is marked as a '
        'typical price rather than mixed in with the ones that are the box\'s '
        'own.\n\n'
        'A RETIRED MODEL IS PRICED AT WHAT REPLACES IT. The drawing says what '
        'is in the room; this figure is what it costs to take that out and put '
        'something in, and for a discontinued product those are two different '
        'numbers - often a third apart, always in the same direction. When the '
        'catalog entry names a successor, that successor\'s price is what the '
        'plan uses, and the row says whose price it is. The chain is followed '
        'all the way: a 2012 model replaced by a 2016 one replaced by a 2024 '
        'one prices at the 2024 one.\n\n'
        'A retired entry that names nothing keeps its own price, because that '
        'is still the best figure anybody has.',
  ),
  HelpTopic(
    title: 'Setting a replacement model on a retired product',
    section: 'The refresh plan',
    where: 'Catalog tab → tick Retired → Replaced by...',
    keywords: [
      'replaced by',
      'successor',
      'retire',
      'discontinued',
      'end of life',
      'eol',
      'catalog',
    ],
    body:
        'Retiring a catalog entry keeps it out of the pickers that specify new '
        'work, and keeps everything it knows - ports, price, rack height - for '
        'the rooms that already have one.\n\n'
        'On its own that answers "do not specify this any more" and leaves '
        '"what does it cost to replace the forty already on the estate" '
        'answered with a discontinued product\'s list price. Naming the '
        'successor fixes it in every reader at once: the room\'s cost page, '
        'the project report and the campus report all price a replacement '
        'through the same ladder.\n\n'
        'The successor is PICKED from the catalog rather than typed, because a '
        'name the catalog does not have is a chain that stops silently at the '
        'price it was trying to get away from.',
  ),
  HelpTopic(
    title: 'The year grid',
    section: 'The refresh plan',
    where: 'Project tab → Lifecycle, and the campus report',
    keywords: ['year', 'grid', 'budget year', 'plan', 'forecast', 'capital'],
    body:
        'A room per row, a year per column, and what falls due in each. This '
        'is the sheet a capital budget is written off.\n\n'
        'A room is rarely one date - the projector went in in 2016 and the '
        'displays in 2019 - so a room appears in every year it owes something '
        'in rather than only in the first.\n\n'
        'The sheet zooms and fits, because it is read both for a figure and '
        'for its shape.',
  ),

  // ---------------------------------------------------------------------------
  //  THE ESTATE
  // ---------------------------------------------------------------------------
  HelpTopic(
    title: 'The campus report',
    section: 'The estate',
    where: 'Campus, from the title bar',
    keywords: [
      'campus',
      'estate',
      'portfolio',
      'multiple buildings',
      'roll up',
    ],
    body:
        'Several buildings on one sheet: add the project files, or point it at '
        'a folder, and every figure is read off the jobs themselves in one '
        'pass over disk.\n\n'
        'A building\'s figure on the calendar is a way INTO that building\'s '
        'own plan. The campus total row is not - it is not any one building.\n\n'
        'The assembly is a document in its own right: it can be named, saved, '
        'reopened, and undone sixty steps deep like everything else in the '
        'app. It goes out as a picture, a spreadsheet or an online copy.',
  ),
  HelpTopic(
    title: 'Current models - what we would buy this year',
    section: 'The estate',
    where: 'Campus → Current models',
    keywords: [
      'current models',
      'standard',
      'benchmark',
      'recommended cost',
      'standard model',
      'projector price',
      'refresh budget',
      'stale',
    ],
    body:
        'A whole refresh plan is built out of one number per kind of thing - '
        'what a projector costs, what a switcher costs - and those numbers had '
        'no provenance at all. Somebody typed them onto the base cost card '
        'once, and an estate was budgeted off them for as long as nobody '
        're-typed them.\n\n'
        'This tab is where that number gets decided, in front of the evidence. '
        'For every kind of thing the estate actually holds it says: how many '
        'there are, which models they are, how many of those the catalog has '
        'already retired, and what the plan presently budgets them at.\n\n'
        'Pick this year\'s model out of the catalog and the comparison is on '
        'screen BEFORE anything is committed: the unit price, forty-one of '
        'them, and the gap against what the plan assumes. That gap is the '
        'reading - a budget short by it is a budget that fails at purchase '
        'order time.\n\n'
        'Accepting it writes the figure, the model and the date onto the base '
        'cost card - the same card the room cost page, the project report and '
        'the campus report already price from - so the decision reaches all '
        'three without any of them knowing this tab exists. A card set on a '
        '2022 projector in 2026 can then be SEEN to be four years stale.',
  ),

  // ---------------------------------------------------------------------------
  //  GETTING WORK OUT
  // ---------------------------------------------------------------------------
  HelpTopic(
    title: 'Exports - spreadsheets, pictures and workbooks',
    section: 'Getting work out',
    where: 'The Hand over / Export control on each tab',
    keywords: [
      'export',
      'xlsx',
      'spreadsheet',
      'picture',
      'png',
      'screenshot',
      'workbook',
      'report',
      'submittal',
      'hand over',
    ],
    body:
        'Most tabs export what they show. Two shapes, for two audiences: a '
        'SPREADSHEET for the people who work from it - a contractor prices a '
        'total, and a price gets typed into a spreadsheet - and a PICTURE for '
        'the people who only have to see it, which goes in a submittal or an '
        'email.\n\n'
        'Pictures are produced from a preview you look at first rather than '
        'captured off the working pane. What is on a pane is an editor, with '
        'buttons on every row, and photographing an editor produces a picture '
        'with delete buttons in it.\n\n'
        'A whole job can go out as one workbook: rooms, parts, vendors, quote '
        'requests, orders, the schedule and the plan, each on its own sheet.',
  ),
  HelpTopic(
    title: 'Quote request packs',
    section: 'Getting work out',
    where: 'Project tab → Vendors → export',
    keywords: ['rfq', 'quote request', 'send to vendor', 'pack', 'xlsx'],
    body:
        'One spreadsheet per vendor, holding exactly the parts that vendor\'s '
        'rules claimed, ready to send. What happens after that - it went out '
        'on the 4th, two came back, one turned into a PO - is tracked back on '
        'the vendor cards.',
  ),
  HelpTopic(
    title: 'Online copy',
    section: 'Getting work out',
    where: 'The Hand over control → Online copy',
    keywords: ['online', 'share', 'link', 'publish', 'web'],
    body:
        'Publishes a read-only copy of a report for somebody who does not have '
        'the app. Exports go to people outside your team, so keep '
        'app-explanatory text out of anything that leaves.',
  ),

  // ---------------------------------------------------------------------------
  //  THE MACHINERY
  // ---------------------------------------------------------------------------
  HelpTopic(
    title: 'The device catalog',
    section: 'The machinery',
    where: 'Catalog tab',
    keywords: [
      'catalog',
      'library',
      'device',
      'av_devices',
      'part number',
      'sku',
      'import',
    ],
    body:
        'Every product the app knows: model, manufacturer, part number, '
        'category, connectors, rack units and clearance, power draw and heat, '
        'both prices, lead time, and how long it lasts.\n\n'
        'Entries can be imported in bulk, merged, retired and given a '
        'successor. A retired entry is never deleted - deleting it would '
        'silently strip the ports and the price from every room that already '
        'used it.\n\n'
        'The category is what the base cost card and the vendor rules both '
        'match on, so it is worth keeping tidy.',
  ),
  HelpTopic(
    title: 'The flow rules builder',
    section: 'The machinery',
    where: 'Flow Rules tab',
    keywords: [
      'flow rules',
      'av_flow_rules',
      'rule',
      'extender',
      'usb switcher',
      'source',
      'destination',
      'auto draw',
    ],
    body:
        'How a room turns into a drawing. A rule says which box a config key '
        'means, what goes between two ends that do not match, and what hangs '
        'off a USB switcher.\n\n'
        'The families are: source boxes, source devices, display outputs, '
        'destination boxes, capture, extenders, USB switchers, the expansion '
        'bus and outlet names. Adding a kind of source the app has never heard '
        'of is a rule, not a build.',
  ),
  HelpTopic(
    title: 'The schema editor',
    section: 'The machinery',
    where: 'Schema tab',
    keywords: [
      'schema',
      'ui_schema',
      'label',
      'field',
      'dropdown',
      'device family',
      'key',
    ],
    body:
        'How each config key looks on screen: its label, its description, '
        'whether it is a dropdown, a switch or free text, and which device '
        'families exist at all.\n\n'
        'If the app calls a field by a name your team does not use, this is '
        'where that is fixed.',
  ),
  HelpTopic(
    title: 'Undo and redo',
    section: 'The machinery',
    where: 'The toolbar, on every document',
    keywords: ['undo', 'redo', 'ctrl z', 'mistake', 'history', 'revert'],
    body:
        'Sixty steps deep on every document the app edits - the room, the job, '
        'the campus assembly, the catalog. Each step is labelled with what it '
        'was, so what you are about to undo is something you can read rather '
        'than guess at.\n\n'
        'Typing is settled into one step rather than one per keystroke; '
        'discrete presses like adding or removing a row are each their own '
        'step.',
  ),
  HelpTopic(
    title: 'Theme, contrast and print mode',
    section: 'The machinery',
    where: 'App Config tab → Appearance',
    keywords: [
      'theme',
      'dark',
      'light',
      'colour',
      'color',
      'contrast',
      'accessibility',
      'print',
      'legible',
    ],
    body:
        'Themes and accents, with every colour on every screen checked against '
        'the surface it is actually drawn on rather than against the one the '
        'scheme assumes. That is why a chip on an error card and the same chip '
        'on a normal card are not always the same ink.\n\n'
        'Print mode drops the drawing onto white for a document that gets '
        'printed or pasted, whatever theme you work in.',
  ),
  HelpTopic(
    title: 'Recovery and autosave',
    section: 'The machinery',
    where: 'Automatic, with a prompt on next launch',
    keywords: ['autosave', 'recover', 'crash', 'backup', 'lost work'],
    body:
        'Work in progress is saved beside the document as you go. If the app '
        'closes without saving, the next launch offers what it found rather '
        'than restoring it silently - the file on disk is the one you chose to '
        'write, and overwriting it without asking is not something a tool gets '
        'to do.',
  ),
];
