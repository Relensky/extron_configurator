/// The app's version and what changed in it, shown in Help.
///
/// [kAppVersion] must match `version:` in pubspec.yaml - the updater compares
/// releases by that number, and changelog_test.dart holds the two together.
library;

const String kAppVersion = '0.2.0+2';

/// [kAppVersion] without the build number, for display.
String get kAppVersionShort => kAppVersion.split('+').first;

class ChangelogEntry {
  final String version;

  /// When it happened, as the reader would say it.
  final String date;
  final String title;
  final List<String> changes;

  const ChangelogEntry({
    required this.version,
    required this.date,
    required this.title,
    required this.changes,
  });
}

/// Newest first. Builds before 0.2.0 all carried 0.1.0, so their entries are
/// grouped by date.
const List<ChangelogEntry> kChangelog = [
  ChangelogEntry(
    version: '0.2.0',
    date: 'September 17, 2026',
    title: 'Estimates',
    changes: [
      'New rooms can be created as "estimate only". The Wizard, Devices, '
          'System and Raw JSON tabs stay hidden until the room is converted '
          'to a programmed room; the cost estimate, schematic, AV flow and '
          'racks work as normal. Rooms saved as "AV only" open as estimates.',
      'Convert to programmed room, on the Cost tab, brings the hidden tabs '
          'back and can build the control blocks from the drawing.',
      'The building and room number of an estimate are set on the Cost tab.',
      'Scope of Work and Estimate Notes sections on the Cost tab, saved with '
          'the room.',
      'Export the estimate as a PDF, with your logo in the top right corner '
          'and who prepared it.',
      'App Config has an Estimate PDF section for the logo, your name and a '
          'contact line.',
      'Help shows the app version and this list of changes.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.0',
    date: 'September 8 - 17, 2026',
    title: 'Updates, timers and the responsibility matrix',
    changes: [
      'The app checks the release folder for a newer version and installs it '
          'when you ask.',
      'Warm-up and cool-down timers in the module editor and on the '
          'schematic, and how long the room takes to come up.',
      'AV flow rules fixed for USB devices and speakers.',
      'Fixed a tab that could hang.',
      'Responsibility matrix drop-downs, zeroing out and numbering.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.0',
    date: 'September 1 - 7, 2026',
    title: 'Module editor, lifecycle charts and deliveries',
    changes: [
      'Module editor, with the file path of each module.',
      'Open Recent menu for rooms, projects and campuses.',
      'Current models on the room and project lifecycle plans.',
      'Lifecycle charts with hover readouts, and strips that fit narrow '
          'windows.',
      'The in-app help book, rewritten in plain language.',
      'Manual editing of surveyed rooms, and a manual room equipment dialog.',
      'Campus information added to the refresh plan files.',
      'Bulk deliveries, saved delivery locations and a default vendor list.',
      'Quote requests can go to several vendors at once.',
      'Speaker output routing fixed; timeline overlap fixed.',
      'Screenshot tool works at any window size.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.0',
    date: 'August 25 - 31, 2026',
    title: 'Undo, purchase orders and campuses',
    changes: [
      'Multi-level undo and redo, including pricing.',
      'Purchase order tracking.',
      'Read Excel files, and a sync folder for Excel and Google Sheets.',
      'Campus view, manual edit mode for campus projects, and a base list of '
          'rooms.',
      'Rooms can be added to the cost projection by hand, and converted to '
          'real rooms.',
      'Screenshot annotation, zoom on image previews, and fit to screen.',
      'Lifecycle target, sorting, export and price editing by double-click.',
      'Cable colors, color picking for responsible parties, and contrast '
          'fixes.',
      'New start screen layout.',
      'Beginner guide, and a PDF version of the guide.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.0',
    date: 'August 17 - 24, 2026',
    title: 'Projects and room types',
    changes: [
      'Projects: rooms on a job, deadlines, pricing, to-dos, plans and a '
          'project workbook.',
      'Lifecycle rail and spares.',
      'Room types that stamp in a room\'s usual equipment, locations and '
          'cabling.',
      'Automatic routing and connection lines on the AV flow, with '
          'animation.',
      'Editors for the UI schema and the signal flow rules.',
      'Snap to grid and grid lines on the drawings.',
      'Room history, manufacturer search and replacing rack parts.',
      'New app icon, banner and navigation rail.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.0',
    date: 'August 8 - 13, 2026',
    title: 'Pricing, floor plans and racks',
    changes: [
      'Cost estimates with catalog pricing, MSRP and labor rates.',
      'Devices can be left off the cost estimate.',
      'Floor plans and cabling, with movable labels and bendable lines.',
      'Rack builder and rack editor.',
      'AV signal flow drawings with curved lines, a legend and a report.',
      'Undo for the drawings.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.0',
    date: 'July 7 - August 3, 2026',
    title: 'Schema-driven configs',
    changes: [
      'The whole app is driven by the UI schema, with key mapping for older '
          'configs.',
      'Control schematic and exported report.',
      'Module documentation with a built-in PDF viewer and annotations.',
      'Auris theme, secondary color and text size.',
      'Encrypted processor password and SFTP fixes.',
      'Save button, undo from backup, and edits applied as you type.',
      'Reboot commands, environment settings and per-device mute.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.0',
    date: 'May 25 - 27, 2026',
    title: 'First release',
    changes: [
      'Edit a room config with a picker for every field.',
      'Download and upload configs over SFTP.',
      'System settings, light mode and saving.',
    ],
  ),
];
