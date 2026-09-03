/// ============================================================================
///  THE HELP BOOK
/// ============================================================================
///  Every feature this app has, written down once, in the app, searchable.
///
///  WHY IT IS DART AND NOT A PDF. There is a guide in `documentation/` and it is
///  a good one, and it is also a file somebody has to find, open in another
///  window and search separately - which on a laptop with a drawing open is a
///  thing that does not get done. Somebody stuck on the Packages pane wants to
///  know what the Packages pane does, now, without leaving it. So the book lives
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
  /// Packages'. Never a coordinate on a screen, which changes; always the names
  /// of the things that are pressed.
  final String where;

  /// THE ANSWER IN ONE BREATH, in words somebody who does not build AV
  /// systems already uses.
  ///
  /// ============================================================================
  ///  WHO THE FIRST SENTENCE IS FOR
  /// ============================================================================
  ///  Most of this book is written for the person doing the work, and it is
  ///  dense on purpose: it says why a thing behaves the way it does, because
  ///  that is what stops somebody working around it. That is the right prose
  ///  for a technician and the wrong prose for the department head who has
  ///  been handed the app to look at one number, and for the new starter on
  ///  their second day.
  ///
  ///  So every topic opens with a plain sentence or two: what this is, and why
  ///  anybody would touch it. No jargon that the sentence does not itself
  ///  explain, no model numbers, no reference to another topic. Somebody who
  ///  reads only this should come away able to say what the feature is FOR.
  ///
  ///  The detail is still underneath and still unabridged. This is a way in,
  ///  not a replacement - a summary that quietly replaced the reasoning would
  ///  cost the reader who needs the reasoning.
  final String plain;

  /// What it does, why it works that way, and what it does NOT do. Written as
  /// prose paragraphs separated by blank lines.
  final String body;

  /// What somebody would type when they do not know what it is called.
  final List<String> keywords;

  const HelpTopic({
    required this.title,
    required this.section,
    required this.where,
    required this.plain,
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
    () => [
      title,
      section,
      where,
      plain,
      body,
      ...keywords,
    ].join(' ').toLowerCase(),
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
    plain:
        'It designs the audio-visual system in a room: what equipment goes '
        'in, how it is wired, what it costs, and when it will need '
        'replacing. One room, a whole building, or every building on '
        'campus.',
    keywords: ['overview', 'intro', 'getting started', 'what is this'],
    body:
        'You describe a room once - what is in it, what plugs into what, when '
        'it went in - and the app writes the processor\'s config.json and '
        'draws everything else off the same description.\n\n'
        'From one room you get a control schematic, an AV signal flow, rack '
        'elevations, a floor plan, a cable schedule and a priced estimate. '
        'From a folder of rooms you get a building: a master parts list, '
        'buying packages, purchase orders, a delivery log and a refresh plan. '
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
    plain:
        'Prices, labor rates, supplier names and the equipment list live in '
        'shared files rather than inside each job, so everybody works off '
        'the same numbers. Point them at a shared drive once and the team '
        'stays in step.',
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
        'delivery_locations.json is the docks kit is dropped at and the '
        'rooms gear is held in. Edited from App Config, and offered on every '
        'delivery.\n\n'
        'vendor_list.json is the companies the shop asks to quote. Edited '
        'from App Config, and every new job starts with them on its '
        'Packages tab.\n\n'
        'If the app does something you do not want, the fix is usually a rule '
        'or a schema entry rather than a new build.',
  ),
  HelpTopic(
    title: 'Pricing tier - list or education',
    section: 'Start here',
    where: 'App Config tab → Pricing',
    plain:
        'Switches every price in the app between the manufacturer list '
        'price and the discounted education price. Pick the one your '
        'institution actually pays and every estimate follows.',
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
    plain:
        'Most rooms are the same handful of designs over and over. Pick the '
        'type of room you are building and the app fills in the usual '
        'equipment, wiring and labelling, ready for you to adjust.',
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
    plain:
        'Opens a room file made by an older version of the app and brings '
        'it up to date. Nothing is thrown away, and you see what changed '
        'before you keep it.',
    keywords: ['load', 'legacy', 'key map', 'migrate', 'convert', 'old file'],
    body:
        'A config written against an older key set is translated on load using '
        'key_map.json, and what was translated is shown rather than done '
        'quietly - the Conversion preview lists every key that changed name so '
        'you can see what the app did before saving over anything.\n\n'
        'Keys the app does not recognize are KEPT, not dropped. A room can '
        'carry settings this app has never heard of and still round-trip '
        'through it unharmed.',
  ),
  HelpTopic(
    title: 'Devices in a room, and their drivers',
    section: 'The room',
    where: 'Devices tab',
    plain:
        'Every piece of equipment in the room, and the small piece of '
        'software the control system needs in order to talk to it. '
        'Equipment with no driver is flagged, because it will not work '
        'until somebody supplies one.',
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
    title: 'Building the control side from the drawing',
    section: 'The room',
    where: 'Cost tab, the System tab placeholder, and the missing-modules '
        'banner',
    plain:
        'A room is usually drawn and priced long before anybody sets up the '
        'control system, which used to mean typing every piece of equipment '
        'in a second time. This does it off the drawing instead, in one '
        'press.',
    keywords: [
      'control side',
      'build control',
      'control blocks',
      'prefill',
      'missing modules',
      'second time',
      'retype',
    ],
    body:
        'Somebody walks the space, lists the gear, draws a rack and puts a '
        'number on it. That leaves a full diagram and a priced estimate and '
        'no control setup at all - so building the control side has meant '
        'entering every device again by hand.\n\n'
        'This creates one control block per device on the drawing, in the '
        'right family, with the same defaults the Setup Wizard writes, and '
        'named in order per family - "Projector 1", "Projector 2" - rather '
        'than from whatever was typed on the canvas. The box on the drawing '
        'and the block become one device, and the cables come with it.\n\n'
        'EVERYTHING IS SHOWN BEFORE ANYTHING IS WRITTEN, with two things '
        'called out: equipment no driver claims, which is created with the '
        'driver left blank rather than guessed, so it stays on every '
        'missing-driver list until somebody answers it; and equipment that '
        'fits no device family, which usually means a speaker or a wall plate '
        'that never had a control block - though a projector on that list '
        'means its catalog category is what needs fixing.\n\n'
        'Nothing is destructive. Blocks that already exist are left alone, '
        'and the counts per family are raised rather than reset.',
  ),
  HelpTopic(
    title: 'Pushing a config to the processor',
    section: 'The room',
    where: 'Title bar → Send',
    plain:
        'Sends the finished settings over the network to the control '
        'processor in the room. This is the step that makes the design '
        'real.',
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
    plain:
        'A picture of what controls what: which processor talks to which '
        'piece of equipment, and over what sort of connection. It is the '
        'drawing you hand to whoever has to fix the room later.',
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
    plain:
        'A diagram of how picture and sound travel through the room, from '
        'the laptop or camera to the screens and speakers. Drag the boxes '
        'around and draw the connections between them.',
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
    plain:
        'A front-on drawing of the equipment rack showing what sits on '
        'which shelf. It also warns you when things will not fit or will '
        'run too hot.',
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
    plain:
        'Marks where things physically are in the room: screens, speakers, '
        'wall plates, the rack. Drop them onto the architect drawing, or '
        'onto a blank sheet if there is not one yet.',
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
    plain:
        'Every cable the room needs, how long it is, and where each end '
        'goes. It comes out as a list an installer can pull and label from.',
    keywords: ['cable', 'schedule', 'run', 'length', 'pull', 'conduit'],
    body:
        'Every run on the AV flow, with the type it carries and the length it '
        'needs, worked out from the locations on the floor plan. Runs can be '
        'routed by hand where the straight line is wrong.\n\n'
        'The schedule prices itself off the catalog: a made-up lead of the '
        'right length where the catalog has one, and bulk cable where it does '
        'not. Cable colors are yours to set and travel with the drawing.',
  ),

  // ---------------------------------------------------------------------------
  //  THE MONEY
  // ---------------------------------------------------------------------------
  HelpTopic(
    title: 'The cost estimate',
    section: 'The money',
    where: 'Cost tab',
    plain:
        'What one room comes to: equipment, labor, fees and tax. Change a '
        'price or a quantity and the total follows.',
    keywords: ['estimate', 'quote', 'price', 'money', 'total', 'bid'],
    body:
        'What this room costs, built from the boxes on the drawing, the cable '
        'schedule and the labor rates.\n\n'
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
    plain:
        'A typical price for each kind of equipment, used when a room has, '
        'say, a projector on the drawing but nobody has chosen which '
        'projector yet. It means an early budget still has a real number in '
        'it.',
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
    title: 'Labor rates',
    section: 'The money',
    where: 'Cost tab → Labor rates',
    plain:
        'What an hour of each trade costs, set once and used by every job. '
        'Change a rate here and every estimate in the app follows.',
    keywords: ['labor', 'labor', 'hours', 'rate', 'install', 'engineer'],
    body:
        'What an hour of each role costs, and how many hours the estimate '
        'assumes per kind of work. A role nobody has priced reports as '
        'unfilled rather than as free.',
  ),
  HelpTopic(
    title: 'Spares',
    section: 'The money',
    where: 'Cost tab → Spares',
    plain:
        'Extra units bought alongside the job, so a failure in two years '
        'does not mean the room waits weeks for a replacement. They are '
        'priced separately so the spend is visible rather than buried.',
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
    plain:
        'Quote a different product on a line without redrawing the room. '
        'For the like-for-like substitution you make when the first choice '
        'is unavailable or too expensive.',
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
    plain:
        'A job: one building, its rooms, its budget, and everything that '
        'has to be bought and delivered for it. Rooms are linked in rather '
        'than copied, so editing a room updates the job as well.',
    keywords: ['project', 'building', 'job', 'rollup'],
    body:
        'A building, quoted as one job: a list of rooms, everything they need '
        'merged into one parts list, and the packages, quotes, orders, '
        'deliveries, '
        'dates and refresh plan that go with it.\n\n'
        'The panes across the top are readings of the same job. Whichever one '
        'is open, the figure in the header is what the building costs.',
  ),
  HelpTopic(
    title: 'Rooms on a job',
    section: 'The job',
    where: 'Project tab → Rooms',
    plain:
        'Which rooms are on this job and what each one costs. Rooms nobody '
        'has designed yet can still be listed with a name, a date and a '
        'rough figure, so the budget covers the whole building rather than '
        'the part of it somebody has drawn.',
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
    plain:
        'Everything the whole job has to buy, in one list, with the same '
        'part in three rooms added up into one line. This is what goes out '
        'to suppliers.',
    keywords: [
      'parts',
      'master list',
      'equipment',
      'bom',
      'bill of materials',
      'filter',
    ],
    body:
        'Every part on the job once, with quantities merged across rooms, in '
        'the buying PACKAGE it will be quoted on.\n\n'
        'The Vendor column stays BLANK until that package is awarded. While it '
        'is out, three companies may be quoting the same lines and naming one '
        'of them would be a guess; the moment a bid wins, every part in the '
        'package says who is supplying it.\n\n'
        'The chips across the top narrow the list: to one package, to the '
        'parts nothing has claimed, to the ones with no price, to the devices '
        'nothing can drive, to spares. The counts on those chips are the job\'s '
        'own to-do list - a building is not ready to go out for quotes while '
        'anything is untagged or unpriced.\n\n'
        'Rows can be selected in bulk to set a lead time, or moved onto '
        'another package, many at once.',
  ),
  HelpTopic(
    title: 'Packages and the rules that fill them',
    section: 'The job',
    where: 'Project tab → Packages',
    plain:
        'Splits the shopping list into batches that go to different '
        'suppliers, screens from one and cabling from another. Rules decide '
        'which parts land in which batch, so you are not sorting hundreds '
        'of lines by hand.',
    keywords: [
      'package',
      'lot',
      'split',
      'rules',
      'manufacturer',
      'category',
      'tag',
      'group',
    ],
    body:
        'A PACKAGE is a set of parts the job buys as one lot: what goes out as '
        'one quote request and comes back as one purchase order. Each one '
        'carries the MANUFACTURERS and CATEGORIES it claims.\n\n'
        'A part joins the FIRST package whose rules claim it. Manufacturer '
        'rules are checked before category rules, so an Extron rule beats "the '
        'reseller lot does speakers" on an Extron speaker. Order matters: drag '
        'a package up its list to give it priority.\n\n'
        'Both rule boxes offer a TICK-LIST built from what the job actually '
        'holds, with a count beside each - "Display (18)" against "Screen '
        '(2)". Rules are matched exactly, so typing "Extron Electronics" '
        'against a catalog that says "Extron" writes a rule that claims '
        'nothing and says nothing about it; ticking cannot go wrong that way. '
        'The typed box is still there for a maker or category the job has no '
        'parts in yet.\n\n'
        'Any part can also be pinned to a package by hand from the Equipment '
        'list, which beats every rule.\n\n'
        'The count chip on a package card - "19 lines, \$18,400" - opens the '
        'Equipment list already narrowed to exactly those parts.',
  ),
  HelpTopic(
    title: 'Vendors - the companies you ask',
    section: 'The job',
    where: 'Project tab → Packages, below the packages',
    plain:
        'The suppliers on this job. Each one can be invited to quote on one '
        'or more of the batches above.',
    keywords: [
      'vendor',
      'supplier',
      'reseller',
      'distributor',
      'company',
      'contact',
      'directory',
    ],
    body:
        'A vendor is a company: a name, who the request goes to, and anything '
        'worth knowing about dealing with them.\n\n'
        'That is ALL it is. A vendor claims no parts and holds no rules - what '
        'it is being asked to price is a property of the PACKAGE that invited '
        'it. The same company can be bidding three packages at once and have '
        'won none of them, which is the ordinary state of a job halfway '
        'through pricing.\n\n'
        'The line at the end of each row says where the company stands: '
        '"bidding 2, won 1". A vendor that lost every bid is still worth '
        'keeping a phone number for.\n\n'
        'Deleting a company takes its bids off every package and hands back '
        'any award it held. The purchase orders it won are LEFT ALONE - they '
        'record something that happened.',
  ),
  HelpTopic(
    title: 'Sending one package to several vendors',
    section: 'The job',
    where: 'Project tab → Packages → Invite a vendor',
    plain:
        'Sends the same request for a price to several suppliers at once, '
        'so what comes back can be compared like for like.',
    keywords: [
      'rfq',
      'quote request',
      'invite',
      'bid',
      'bidder',
      'send',
      'multiple vendors',
      'competitive',
      'tender',
    ],
    body:
        'Open a package and INVITE as many vendors as you want prices from. '
        'Each gets an identical copy of the request - the same parts, the same '
        'terms, the same due date - because three vendors pricing three '
        'slightly different requests come back with three numbers nobody can '
        'compare.\n\n'
        'Sent is ONE action for the whole package, because that is how it '
        'happens: the file is written once and emailed to four companies in '
        'one sitting. A vendor invited a week later gets a send date of their '
        'own, so a quote that arrived after the decision is explainable.\n\n'
        'OUR OWN ESTIMATE is left OFF the sheet once more than one vendor is '
        'bidding. Handing every bidder the figure the job holds anchors all of '
        'them to it and collapses the spread that makes running a competition '
        'worth anything. A single-source package still shows it, because there '
        'the argument is whether the line is right. The switch on the card '
        'overrides either way.\n\n'
        'Exporting the quote requests writes one file per bidder, named for '
        'the job, the package and the company, so a folder of them can be read '
        'without opening any.',
  ),
  HelpTopic(
    title: 'Comparing the quotes that come back',
    section: 'The job',
    where: 'Project tab → Packages, and the Timeline',
    plain:
        'Puts the quotes side by side, line by line, so you can see who is '
        'cheaper on what, and where a quote has quietly left something out.',
    keywords: [
      'quote',
      'compare',
      'comparison',
      'quoted',
      'price',
      'declined',
      'no bid',
      'waiting',
      'chase',
      'lowest',
    ],
    body:
        'Every vendor asked is a row on the package card, cheapest first, '
        'against the figure the job holds for those lines. Four columns, '
        'because four things decide an award and were never on one screen '
        'together: WHO, HOW MUCH, HOW FAR OFF our number, and WHEN they can '
        'deliver. A quote four hundred cheaper that lands three weeks after '
        'the deadline is not a cheaper quote.\n\n'
        'The vendors who have NOT answered are on the table too, at the '
        'bottom. Leaving them off would make a comparison of two look complete '
        'when four were asked - the state most worth seeing before awarding, '
        'because a phone call can still fix it.\n\n'
        'A vendor who wrote back to say no is marked DECLINED. That is an '
        'answer, not silence: without it the package never reads as fully '
        'quoted and somebody chases a company that already replied.\n\n'
        'Recording a quote takes the date, the amount, the vendor\'s own quote '
        'number, what they promised, and the exclusions - "excludes freight" '
        'is what makes two prices four hundred apart actually the same price. '
        'The quote PDF is attached in the same dialog, at the moment somebody '
        'has it in front of them. Nothing is copied: the project stores where '
        'the file IS, so moving it moves what this opens.\n\n'
        'Recording a quote changes no price on the job. The estimate stays '
        'what the parts say.\n\n'
        'The stage chip on a closed card says where the round has got to - '
        'Draft, Out, "2 of 4 in", Quoted, Awarded - so a list of six packages '
        'answers "which of these are we still waiting on" without any of them '
        'being opened. The Timeline says the same thing, with the prices side '
        'by side and each quote one press away.',
  ),
  HelpTopic(
    title: 'Awarding a package',
    section: 'The job',
    where: 'Project tab → Packages → Award...',
    plain:
        'Records which supplier won a batch. From that moment every part in '
        'it says who is supplying it.',
    keywords: [
      'award',
      'order',
      'po',
      'purchase order',
      'raise',
      'buy',
      'winner',
      'chosen',
    ],
    body:
        'Pick the winning bid, and one action makes four things true: it '
        'raises the purchase order, points it at that vendor, puts every part '
        'in the package onto it, and finally gives those parts a supplier at '
        'all.\n\n'
        'The third one is the link back from a PO number to the equipment it '
        'bought. Before it existed the first two got done and the third did '
        'not, which leaves a PO nobody can trace to any equipment and nineteen '
        'parts reading on the timeline as things nobody has bought.\n\n'
        'THE LOSING QUOTES STAY ON THE PACKAGE. That is the point of running a '
        'competition: six months later, "why did we not take the cheapest" has '
        'to be answerable, and the card says which bid was lowest even when it '
        'did not win. Awarding above the lowest is allowed and is written into '
        'the history at the moment it is done.\n\n'
        'The parts default to the WHOLE package, because that is what a '
        'purchase order almost always is. Awarding only HALF of one to a '
        'different vendor? Move those lines onto a package of their own first, '
        'then award each - one part belongs to one package, one PO and one '
        'delivery, and every color, filter and delivery link on the job rests '
        'on that.\n\n'
        'The signed order is attached here too, at the one moment somebody has '
        'the PDF. Un-awarding hands the package back to the competition and '
        'LEAVES the PO, the parts and every bid exactly as they were.',
  ),
  HelpTopic(
    title: 'Purchase orders and the delivery log',
    section: 'The job',
    where: 'Project tab → Deliveries',
    plain:
        'Tracks what has been ordered, what has actually turned up, and '
        'where it is being kept until it goes into the room.',
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
        'Every PO number the job mentions ANYWHERE - on a package, on a part, '
        'on an earlier delivery - is one click away in the PO boxes rather '
        'than something to retype and mistype. Numbers the job knows but has '
        'no row for are offered when adding one. Picking a part that has '
        'already gone out on a PO fills its number in for you, off the order '
        'record; type over it when the packing slip disagrees.\n\n'
        'A whole load is logged in one pass. "Log several" ticks off everything '
        'that came together, with the place it went and the day it landed said '
        'once for all of them - and each row still keeps the PO that bought '
        'that part.\n\n'
        'Kit that MOVES is moved in one pass too. Tick the rows that came off '
        'the dock together, press "Move these", and they all go to the same '
        'place on the same day - each one keeping a signed note of where it '
        'moved from and to. See "Saved delivery locations".',
  ),
  HelpTopic(
    title: 'Saved delivery locations',
    section: 'The job',
    where: 'App Config tab -> Delivery locations, and every delivery log',
    plain:
        'The loading docks and store rooms you receive equipment at, typed '
        'in once and then picked from a list. It stops one store room being '
        'spelled four different ways across a year of deliveries.',
    keywords: [
      'delivery location',
      'storage',
      'dock',
      'warehouse',
      'address',
      'stores',
      'held',
      'move',
    ],
    body:
        'The docks kit is dropped at and the rooms gear waits in, set up '
        'once and then one click away on every delivery. A loading dock is a '
        'fact about the estate rather than about one job, and retyping '
        '"MLIB basement, rack 3" per delivery is how one shelf becomes four '
        'spellings that no filter can put back together.\n\n'
        'Each place carries a name, what it is used for - deliveries, '
        'storage, or both - an address, and notes on the room itself. The '
        'NAME is what gets written onto a delivery; the address is looked up '
        'here rather than retyped onto every row.\n\n'
        'They live in delivery_locations.json. Point the path at a shared '
        'drive and the whole shop logs deliveries against the same names, '
        'which is what makes "everything at Central Stores" a question a job '
        'can answer.\n\n'
        'It never restricts anything. A delivery can still be logged to a '
        'place that is not on the list, because the delivery worth writing '
        'down carefully is usually the one that went somewhere new.\n\n'
        'To move several lots at once, tick them in the delivery log and '
        'press "Move these". Every row moved keeps a signed note saying where '
        'it came from and where it went, so the log can still answer "where '
        'was it in March" after somebody has moved it twice.',
  ),
  HelpTopic(
    title: 'The default vendor list',
    section: 'The job',
    where: 'App Config tab -> Default vendors, and Project tab -> Packages',
    plain:
        'Your usual suppliers, kept in one place, so every new job starts '
        'with them already listed instead of being typed in again.',
    keywords: [
      'vendor',
      'supplier',
      'default',
      'directory',
      'company',
      'rep',
      'quote',
      'packages',
      'shared',
    ],
    body:
        'The companies this shop asks to quote, set up once and then on every '
        'job without being retyped. Who the department buys from is a fact '
        'about the department rather than about one building.\n\n'
        'Each company carries a name, who a request goes to, and anything '
        'worth knowing about them - the account number, the terms, what they '
        'are slow on.\n\n'
        'They live in vendor_list.json. Point the path at a shared drive and '
        'everybody starts from one directory, which is what stops the same '
        'supplier being spelled three ways across three quote comparisons.\n\n'
        'A NEW JOB ARRIVES WITH THEM on its Packages tab. A job started before '
        'a company was added can take it from "Add saved vendors" beside Add '
        'vendor on the same tab, which only ever offers what the job has not '
        'got. It opens the list and you TICK the ones you want: a shop with '
        'nineteen suppliers on the share is not asking eleven of them to '
        'quote a two-room refresh, and adding all of them so nine can be '
        'deleted is not a shortcut. "Tick all" is there for the job that has '
        'never been seeded.\n\n'
        'What lands on a job is a COPY. Renaming a vendor there, or dropping '
        'the ones this job is not using, changes nothing on the share - and '
        'changing the share does not rewrite a job that has already been '
        'quoted.',
  ),
  HelpTopic(
    title: 'The delivery timeline',
    section: 'The job',
    where: 'Project tab → Timeline',
    plain:
        'A calendar view of when equipment is due to arrive and when the '
        'work is booked, so a clash shows up before it becomes a problem on '
        'site.',
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
        'package\'s quote round, and the delivery deadline. Nothing on it is '
        'a new fact; it is the same schedule seen from far enough away to have '
        'a shape.',
  ),
  HelpTopic(
    title: 'Zooming the date rail',
    section: 'The job',
    where: 'Project tab → Timeline → the arrows on THE DATES card',
    plain:
        'Changes how much time the timeline shows at once, from a few weeks '
        'to the whole job.',
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
    plain:
        'Splits a long job into stages, and into strands of work that run '
        'alongside each other, so the timeline reads as a plan rather than '
        'as one very long bar.',
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
    plain:
        'Who is doing what: which parts your team supplies and installs, '
        'and which the contractor or the department handles. It settles on '
        'paper the arguments that otherwise happen on site.',
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
        'Each party carries its own color, the same one wherever its name '
        'appears, so one contractor\'s share of the sheet is visible without '
        'reading a cell. A line nobody has been named on reads NOBODY in the '
        'error color - a blank is the exact thing this sheet exists to '
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
    plain:
        'Loose ends recorded against the job itself rather than in somebody '
        'notebook, so they survive that person being on leave.',
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
    plain:
        'A log of what was changed on this job, when, and under whose '
        'login.',
    keywords: ['history', 'audit', 'log', 'who changed', 'undo', 'provenance'],
    body:
        'Every edit to the job, under the thing it was about. "This says '
        'bought - who said so, and when" is asked of the PART, and a single '
        'line on the package cannot answer it, so orders, quotes, prices and '
        'dates are all logged against both.',
  ),

  // ---------------------------------------------------------------------------
  //  THE REFRESH PLAN
  // ---------------------------------------------------------------------------
  HelpTopic(
    title: 'How old the gear is, and when it falls due',
    section: 'The refresh plan',
    where: 'Lifecycle tab, and Project tab → Lifecycle',
    plain:
        'How old everything in a room is, and the year it will need '
        'replacing, colored green through amber to red. This is the picture '
        'a refresh budget gets written from.',
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
    plain:
        'What it would cost to replace a piece of equipment today. Where '
        'the exact product is no longer sold, the figure used is the price '
        'of whatever replaced it.',
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
    plain:
        'When a product stops being sold, record what replaces it. Every '
        'room still holding the old one is then costed at a price you can '
        'actually buy at.',
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
    title: 'What is in a room nobody has drawn',
    section: 'The refresh plan',
    where: 'Project tab -> Rooms or Lifecycle -> the box icon on a line item',
    plain:
        'For rooms nobody has designed in the app, this shows what is '
        'actually installed today, read off the control systems that run '
        'them. You can correct it by hand wherever the reading is wrong.',
    keywords: [
      'survey',
      'inventory',
      'what is in',
      'gve',
      'line item',
      'installed',
      'equipment',
      'poll',
    ],
    body:
        'A line item is a date, a life and a figure, and the first question '
        'anybody asks about a red row is the one it could not answer: what is '
        'actually in there? The room type in its notes - "2 Projector" - is '
        'what the estate sheet PRICED it against, which is a different '
        'sentence from what a technician would find on the wall.\n\n'
        'A survey of the control systems answers it. The row says what the '
        'room is made of - "in the room: 2 Projector, 1 Switcher, 1 Camera" - '
        'and the box icon opens the models, with what each would cost to buy '
        'today. Prices go down the same ladder a drawn room boxes do: the '
        'catalog price for the model, following a retired part to whatever '
        'replaced it; then the base cost card typical figure for what the box '
        'does, marked est.; then nothing at all, and the room says how many '
        'lines it could not price rather than counting them as free.\n\n'
        'TWO FIGURES, AND THEY ARE NOT THE SAME FIGURE. The survey total is '
        'what the boxes currently on the wall cost to buy - no labor, no '
        'cabling. The plan cost is a REFRESH: a new room, gear, cabling, '
        'mounting and labor. The report shows both and says which is which, '
        'and the difference between them is not labor.\n\n'
        'THE SURVEY DOES NOT AGE. It records models, not install dates, so a '
        'line item with eleven surveyed boxes is still ONE thing falling due '
        'on the year grid, at the estate own figure. It is an inventory '
        'behind a number, not a parts list anybody can re-total.\n\n'
        'IT IS EDITABLE, because a poll is a machine reading of a room and a '
        'machine gets rooms wrong. Correct a model, what it does, or how many '
        'there are, and Save. The correction is written to the job history, '
        'so if a later import overwrites it the overwrite is visible rather '
        'than silent.',
  ),
  HelpTopic(
    title: 'Turning line items into rooms',
    section: 'The refresh plan',
    where: 'Project tab -> Rooms -> the icons on a line item, and "Attach '
        'rooms already drawn"',
    plain:
        'A room that is only a rough estimate becomes a properly designed '
        'room here, either built fresh from a room type or linked to a '
        'design somebody has already drawn.',
    keywords: [
      'line item',
      'build room',
      'swap',
      'attach',
      'drawn',
      'estimate',
      'replace',
      'config',
    ],
    body:
        'A refresh plan starts as four hundred estimates and becomes, one room '
        'at a time over three years, four hundred drawn rooms. Two ways '
        'across, both on the line.\n\n'
        'BUILD A ROOM FROM THE LINE, for the room nobody has drawn yet - which '
        'on a refresh plan is nearly all of them. The room type the line was '
        'priced against is already known, so the new-room dialog opens on that '
        'preset instead of on a list of twenty-seven. Once the room is drawn, '
        'the survey is offered on top of it: the type keeps the drawing, the '
        'cabling and the jack numbering, and the survey supplies the MODELS. '
        'Matched by what a box does, never by name or position. A surveyed box '
        'with no position on that room type is reported and NOT added - an '
        'unwired box on a diagram is worse than one that is not there - and a '
        'position the poll never saw keeps the type model, because a poll '
        'cannot see a screen.\n\n'
        'ATTACH THE ROOMS ALREADY DRAWN, for the folder of configs that exists '
        'eighteen months in. It scans the job folder and matches each config '
        'to a line on the ROOM CODE THE CONFIG STATES - not its file name, '
        'which is the one fact about a file nobody maintains - then shows the '
        'list before swapping any of them. Two files claiming one room are '
        'reported and skipped rather than guessed between: picking either ends '
        'with a budget pointing at somebody working copy. Swap on the line is '
        'still there for the one you know.\n\n'
        'EITHER WAY THE ESTIMATE ONLY LEAVES THE PLAN IF THE ROOM WENT ON. A '
        'line item is the only record of its room, and losing it to a '
        'half-finished conversion would take the room off the budget '
        'altogether.',
  ),
  HelpTopic(
    title: 'What the estate is priced on',
    section: 'The refresh plan',
    where: 'Catalog tab -> Priced on...',
    plain:
        'The typical price used for each kind of equipment, and the actual '
        'product each of those prices is based on. Worth checking once a '
        'year so the budget is not built on something you can no longer '
        'buy.',
    keywords: [
      'base cost',
      'benchmark',
      'standard model',
      'priced on',
      'stale',
      'retired',
      'budget year',
      'catalog',
    ],
    body:
        'Every figure the project and campus reports fall back to comes off '
        'one line of the base cost card, and each of those lines can name the '
        'MODEL it was benchmarked on and the day it was set. That is what '
        'turns "about 4,200" into a number a finance office can argue '
        'with.\n\n'
        'Setting one category at a time off the campus report is right when '
        'somebody is reading that report and has an opinion about projectors. '
        'This is the other shape of the same question, and the shape it '
        'usually has: the start of a budget year, a price list just imported, '
        'eighteen categories, and one thing to find out - is anything here '
        'still benchmarked on a product we cannot buy? The button carries the '
        'count of lines worth looking at.\n\n'
        'WHAT IT PROPOSES IS NOT A GUESS. A benchmark the catalog has retired '
        'follows its own successor. A line with nothing set takes the dearest '
        'current model in its category - dearest rather than cheapest, because '
        'a base cost is what a room done properly comes to, and benchmarking '
        'an estate on the cheapest thing in the aisle is how a budget comes in '
        'short in the one direction nobody checks.\n\n'
        'A LINE ALREADY ON A CURRENT MODEL IS LEFT ALONE. Re-pricing it '
        'because a price list moved is a decision, and it stays one: press the '
        'line and pick. Every proposal is shown before any of it is written, '
        'because setting eighteen categories re-prices four hundred rooms.',
  ),
  HelpTopic(
    title: 'The year grid',
    section: 'The refresh plan',
    where: 'Project tab → Lifecycle, and the campus report',
    plain:
        'A row per room and a column per year, showing what falls due when '
        'and how much to put in each budget year.',
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
    plain:
        'Every building replacement plan added together, so the whole '
        'estate spend can be seen and argued over in one place.',
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
    plain:
        'For each kind of equipment, how many the estate holds and what it '
        'would cost to replace them all with this year model. Choosing one '
        'sets the price the whole plan is built on.',
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
    plain:
        'Gets the work out of the app: a spreadsheet somebody can edit and '
        'total, or a picture they can paste into a report.',
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
        'A whole job can go out as one workbook: rooms, parts, packages, the '
        'quote comparison, orders, the schedule and the plan, each on its own '
        'sheet.',
  ),
  HelpTopic(
    title: 'Quote request packs',
    section: 'Getting work out',
    where: 'Project tab → Packages → export',
    plain:
        'A tidy bundle to send a supplier: what you want priced, with the '
        'drawings and notes they need in order to price it.',
    keywords: ['rfq', 'quote request', 'send to vendor', 'pack', 'xlsx'],
    body:
        'One spreadsheet per BIDDER, holding exactly the parts that package\'s '
        'rules claimed, ready to send. A package with three vendors on it '
        'produces three files, identical but for the name at the top; one with '
        'nobody invited yet produces a single unaddressed draft to read before '
        'deciding who to send it to.\n\n'
        'The files are named for the job, the package and the company, so a '
        'folder of them can be read without opening any - and so the second '
        'copy does not overwrite the first.\n\n'
        'What happens after that - it went out on the 4th to three of them, '
        'two came back, one won - is tracked back on the package cards.',
  ),
  HelpTopic(
    title: 'Online copy',
    section: 'Getting work out',
    where: 'The Hand over control → Online copy',
    plain:
        'Keeps a copy of a room or a job somewhere shared, so somebody else '
        'can pick it up or carry on with it.',
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
    plain:
        'The list of every product the app knows about: what sockets it '
        'has, how much rack space it takes, what power it draws and what it '
        'costs.',
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
        'The category is what the base cost card and the package rules both '
        'match on, so it is worth keeping tidy.',
  ),
  HelpTopic(
    title: 'The flow rules builder',
    section: 'The machinery',
    where: 'Flow Rules tab',
    plain:
        'Sets the habits the app follows when it wires a room for you: '
        'which source goes where, and what a typical room includes.',
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
    plain:
        'Edits the questions the setup wizard asks and the settings a room '
        'is allowed to hold. For whoever maintains the app own vocabulary.',
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
    title: 'Product manuals, in the app',
    section: 'The machinery',
    where: 'Anywhere a document is attached: Devices, Deliveries, Plans, '
        'Responsibilities and the quote pages',
    plain:
        'Opens a PDF - a product manual, a quote, a delivery note, an '
        'architect drawing - in a window inside the app, so looking something '
        'up does not mean leaving what you were doing.',
    keywords: [
      'pdf',
      'manual',
      'datasheet',
      'document',
      'viewer',
      'attachment',
      'drawing',
      'quote',
    ],
    body:
        'Documents are attached to the thing they belong to rather than kept '
        'in a folder somebody has to know about: the manual against the '
        'device, the acknowledgement against the purchase order, the '
        'architect sheet against the building.\n\n'
        'What the app can draw itself - PDFs and the ordinary image formats - '
        'opens in a window here, with the page you were on remembered. '
        'Anything else is handed to the machine own opener, because a viewer '
        'that half-renders a drawing is worse than the program that was '
        'written to.\n\n'
        'The file is a REFERENCE, not a copy. It stays where it is on disk, '
        'so a manual replaced with a newer revision is newer everywhere it is '
        'attached, and moving the folder it lives in is what breaks the link '
        'rather than editing the document.',
  ),
  HelpTopic(
    title: 'Undo and redo',
    section: 'The machinery',
    where: 'The toolbar, on every document',
    plain:
        'Takes back the last thing you did, and puts it back again if you '
        'change your mind.',
    keywords: ['undo', 'redo', 'ctrl z', 'mistake', 'history', 'revert'],
    body:
        'Sixty steps deep on every document the app edits - the room, the job, '
        'the campus assembly, the catalog. Each step is labeled with what it '
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
    plain:
        'Light or dark, higher contrast for a bright room, and a plain mode '
        'that survives being printed or put through a projector.',
    keywords: [
      'theme',
      'dark',
      'light',
      'color',
      'color',
      'contrast',
      'accessibility',
      'print',
      'legible',
    ],
    body:
        'Themes and accents, with every color on every screen checked against '
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
    plain:
        'The app keeps a live working copy as you go, so a crash or a power '
        'cut does not cost you the afternoon.',
    keywords: ['autosave', 'recover', 'crash', 'backup', 'lost work'],
    body:
        'Work in progress is saved beside the document as you go. If the app '
        'closes without saving, the next launch offers what it found rather '
        'than restoring it silently - the file on disk is the one you chose to '
        'write, and overwriting it without asking is not something a tool gets '
        'to do.',
  ),
];
