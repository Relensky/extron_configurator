/// The app's version and what changed in it, shown in Help.
///
/// [kAppVersion] must match `version:` in pubspec.yaml - the updater compares
/// releases by that number, and changelog_test.dart holds the two together.
///
/// VERSIONS BEFORE 0.2.0 WERE NUMBERED AFTERWARDS, from the git history: every
/// one of those builds still carried pubspec.yaml's original `0.1.0`, so the
/// 0.1.x numbers below name a run of work rather than a build anybody
/// installed. Each entry's date range is the real record of when it happened.
library;

const String kAppVersion = '0.5.3+13';

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

/// Newest first.
const List<ChangelogEntry> kChangelog = [
  ChangelogEntry(
    version: '0.5.3',
    date: 'September 24, 2026',
    title: 'File menu text in full, and Settings fills the window',
    changes: [
      'File menu lines no longer lose their last word on Windows (Open '
          'Project... could show as just "Open"). A menu line never wraps now '
          'and has a little room to spare.',
      'The processor transfer windows say Upload Config and Download Config '
          'too, in the title and on the button, to match the File menu.',
      'Settings fills the whole window under the title bar, and scrolls with '
          'the mouse wheel or the scrollbar wherever the pointer is. The gear, '
          'its X or Esc still close it.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.2',
    date: 'September 24, 2026',
    title: 'Clearer File menu, and the estimate PDF is back on Export',
    changes: [
      'The Export button on the Cost tab lists the estimate as PDF, Excel, '
          'text and clipboard again. They were missing whenever you switched '
          'to the Cost tab from another page.',
      'The File menu says what each item does: New Room, New Project, New '
          'Campus, Open Room..., Open Project..., Open Campus.... Open Recent '
          'shows each file\'s name with its full folder under it.',
      'Download and Upload in the File menu are now Download Config and '
          'Upload Config.',
      'Opening a room picks its deployment processor automatically when the '
          'processors list has exactly one for it - matched on the building '
          'code and room number (AGYM 129), or failing that the file name. '
          'Two processors with the same name are never guessed between.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.1',
    date: 'September 24, 2026',
    title: 'A File menu, Settings as a window, and Export in the corner',
    changes: [
      'A File menu (the three lines in the top-left corner): New and Open for '
          'a room, a project or a campus, Open Recent opening to the side, '
          'and Download from / Upload to the processor.',
      'Settings opens as a window over the page you were on. Clicking the '
          'gear again, its X, or Esc closes it and puts you back. The gear is '
          'the far-right button, with Help just left of it, and the '
          'screenshot beside the light/dark toggle.',
      'Save is in the right-hand corner of the second row, beside Convert.',
      'Export floats in the lower right and lists what is open - the room, '
          'the project, the campus - each once. The workbook is no longer '
          'offered twice (the Project tab\'s and AV Flow\'s own workbook '
          'buttons are gone, and on the Cost tab the estimate is listed once).',
      'Two tests that failed on Linux/macOS pass everywhere now. The older '
          'Panasonic PT-VMZ driver copy no longer claims the same models as '
          'pana_vp_VMZx, which the app was already using for them.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.0',
    date: 'September 24, 2026',
    title: 'Editing together, a tidier toolbar, budgets and Google Sheets',
    changes: [
      'Several people can have the same room, project or catalog open from a '
          'shared folder. Everybody else who has it open shows on the banner '
          'with their Windows user name (a pencil means they have unsaved '
          'changes). When one of them saves, a "<name> saved - Merge" button '
          'brings their changes in; anything you both changed is listed for '
          'you to pick. Save merges first too, so the second person to save '
          'never erases the first. Can be turned off in App Config.',
      'The files stay JSON - that is what makes the merge work on any shared '
          'or synced folder. config.json is exported exactly as before.',
      'Title bar: Save is now at the far left, with Undo, Redo and History '
          'beside it. Export, the light/dark toggle, Settings and Help are at '
          'the far right.',
      'One Export menu replaces the workbook, publish and per-tab export '
          'buttons, and on the Cost tab it also holds the estimate as PDF, '
          'Excel, text or clipboard. The Cost tab\'s own Screenshot, Save AV '
          'Setup and Export buttons moved into the toolbar\'s Screenshot, '
          'Save and Export menus.',
      'Upload workbook to Google Sheets (Export menu): straight into your '
          'Google Drive as a Sheet once a Google client is set in App Config, '
          'otherwise it saves the .xlsx and opens Google Sheets to upload it.',
      'Catalog spec sheets: set a shared Spec Sheet Folder, attach a sheet to '
          'any device (filed as <maker>/<model>.pdf) and open it from the '
          'catalog. Sheets named after the model are found automatically.',
      'Project budget: set a total budget on the Project tab and add planned, '
          'committed and spent lines as the job goes, with remaining and the '
          'rooms estimate shown beside it.',
      'Keyboard: Ctrl+S saves, Ctrl+Shift+S is Save All, Ctrl+Alt+S is Save '
          'As.',
      'Updates install in one click: the update notice and App Config both '
          'have Close and Update, which closes the app, installs and opens it '
          'again (you are still asked about unsaved work first). Options... '
          'on the notice is the old step that also offers shortcuts.',
    ],
  ),
  ChangelogEntry(
    version: '0.4.3',
    date: 'September 23, 2026',
    title: 'The update notice installs again, and Windows 11 in the log',
    changes: [
      'Updates: pressing Update on the update notice now goes on to the '
          '"Close and Update" step. Before, the click itself made the '
          'notice disappear for two minutes, so an update could only be '
          'installed from App Config.',
      'The log, and logs copied or exported from the log viewer, name '
          'Windows 11 correctly, with its release and build (for example '
          '"Windows 11 Enterprise 25H2 (build 26200.6899)"). Windows tells '
          'apps that every Windows 11 machine is Windows 10, so the log said '
          'Windows 10.',
    ],
  ),
  ChangelogEntry(
    version: '0.4.2',
    date: 'September 23, 2026',
    title: 'A log viewer, and help that can fill the window',
    changes: [
      'App Config - View logs opens the log viewer: '
          'the recent log files, newest first with this session\'s marked, '
          'and a search and Problems only to '
          'find the part that matters. The expand button makes it fill the '
          'window.',
      'Copy puts this file, what is shown, or all recent logs on the '
          'clipboard, ready to paste into a ticket, an email or a Teams '
          'message. Export saves the same as a .txt file to attach. Both '
          'start with the app, its version, the computer and the user, so '
          'whoever gets it knows where it came from.',

      'Help has an expand button beside the close button: it makes the help '
          'book fill the window instead of stopping at a fixed size, for '
          'reading a long topic or the changelog without scrolling a narrow '
          'column. Press it again to go back. The choice is remembered until '
          'the app closes.',
    ],
  ),
  ChangelogEntry(
    version: '0.4.1',
    date: 'September 22, 2026',
    title: 'Estimate PDF options, shipping and search',
    changes: [
      'The estimate PDF title can be changed on the Cost tab - "CTS '
          'Estimate", "Audio Visual Estimate" or anything else. Left blank it '
          'still says Estimate.',
      'PDF subtitle, beside the title, changes the line printed under it. '
          'Left blank it shows the room name, as before.',
      'PDF wording lets you rename the other fixed words on the PDF - the '
          'section headings, Project, Date, Prepared by, Shipping, Subtotal '
          'and Total. Reset all puts them back.',
      'Add text or list sections to the Cost tab, each with its own title. '
          'They print on the PDF above the pricing or below the totals, and '
          'can be moved up and down. They are in the Excel and text exports '
          'too, in the same place.',
      'The Scope of Work and Estimate Notes are now in the Excel and text '
          'exports of the estimate, as well as on the PDF. Each room tab of '
          'the project workbook carries the scope, notes and custom sections '
          'of that room too.',
      'The accent color chosen for the estimate PDF now colors the title and '
          'header bands of every Excel report too. Light colors get dark text '
          'so the bands stay readable.',
      'Pick from logo, under the accent colors in App Config, opens your logo '
          'so you can click any spot on it to use that color, or choose from '
          'its main colors.',
      'Shipping per item: turn on Shipping on the Equipment card and every '
          'table - equipment, rack hardware, cabling and other items - gets a '
          'shipping-per-unit box, for a display or lectern that ships at its '
          'own price. '
          'It shows as its own line in the totals, on the PDF and in the '
          'exports. Tax shipping decides whether tax is charged on it.',
      'Labor now shows crew hours and total hours on the Cost tab, the PDF, '
          'the Excel and text exports and the project totals.',
      'Search boxes have an X to clear them - the catalog, the pickers for '
          'devices, parts, processors and rates, and the building search.',
      'Catalog search: when a match is hidden by the category, "My entries '
          'only" or retired filter, the list says so and offers Show all '
          'matches.',
      'Narrow windows: the catalog form wraps instead of pushing Education '
          'price off the edge, the Cost tab and every page scroll sideways '
          'with a scrollbar instead of cutting content off, and the tax and '
          'totals boxes rearrange to fit.',
    ],
  ),
  ChangelogEntry(
    version: '0.4.0',
    date: 'September 21, 2026',
    title: 'Desktop and Start menu shortcuts',
    changes: [
      'When you press Update, the "Update to version …?" notice now offers to '
          'add a Desktop shortcut and a Start menu shortcut. Each box only '
          'appears when the app does not have that shortcut yet, and both '
          'start unticked - nothing is added unless you tick it.',
      'App Config - App Updates has the same thing as buttons under '
          'Shortcuts, so a shortcut can be added at any time without waiting '
          'for an update. Once a shortcut is there the button says so.',
      'Any shortcut that opens this copy of the app counts, whatever it is '
          'called. New ones are named Room Config Builder and go in your own '
          'Desktop and Start menu, so they need no administrator permission. '
          'A shortcut that cannot be made never stops the update.',
    ],
  ),
  ChangelogEntry(
    version: '0.3.2',
    date: 'September 18, 2026',
    title: 'Safer saving, and no convert notice for converted rooms',
    changes: [
      'Opening a room that is already in the current format no longer says '
          'it needs converting, or puts a count of 0 on the Convert button. '
          'Notes about the file - a key the default template does not have, '
          'a module to set by hand, a device count that looks too low - were '
          'being counted as changes.',
      'Those notes can still be read: when a file has notes but nothing to '
          'convert, the Convert button opens them without showing a count.',
      'Saving can no longer leave a room file empty. The file used to be '
          'emptied before the new copy was written, so if the app closed in '
          'that moment the room was left at 0 bytes and would not open. Rooms, '
          'their AV flow, schematic and cost files, projects, campuses, App '
          'Config and the price, labor, vendor and delivery lists are now '
          'written to a new file first and swapped in once it is complete.',
      'A room file that will not open now says why instead of doing '
          'nothing. An empty file names the _previous.json backup beside it, '
          'which holds the room as it was before the last save.',
    ],
  ),
  ChangelogEntry(
    version: '0.3.1',
    date: 'September 18, 2026',
    title: 'Estimate PDF logo corner and accent color',
    changes: [
      'The logo on the estimate PDF can print in the top left or top right '
          'corner - App Config - Estimate PDF - Logo corner. With the logo on '
          'the left, the Estimate title and the building and room number move '
          'to the right. Right is still the default.',
      'The estimate PDF\'s accent color - the headings, rules and total band '
          '- can be changed in App Config - Estimate PDF. Pick one of the '
          'swatches, any color off the color wheel, or Default for the navy '
          'it has always printed in.',
      'The theme accent and secondary color pickers in App Config have a '
          'color wheel swatch too, for any color that is not on the grid.',
    ],
  ),
  ChangelogEntry(
    version: '0.3.0',
    date: 'September 17, 2026',
    title: 'Estimate notes, the release folder and the laptop plates',
    changes: [
      'A new estimate starts with the standard qualifications in Estimate '
          'Notes: that equipment costs are preliminary and may vary with final '
          'product selection, availability, shipping and tax; what the '
          'miscellaneous materials allowance covers; and that work beyond the '
          'scope described may cost more. Edit or delete them like any other '
          'text - they are only ever put in when the box is empty.',
      'Every page of the estimate PDF is now footed with "Estimate for" and '
          'the building and room number, so a page read on its own says which '
          'room it belongs to. Who prepared it is still printed on the first '
          'page beside the date.',
      'An estimate-only room no longer draws the laptop plates on the AV '
          'flow. Every room template carries a number in input_hdmi and '
          'input_usb whether or not the room has been designed yet, so in a '
          'room being priced those numbers said nothing.',
      'Converting an estimate to a programmed room no longer draws a second '
          'laptop beside one already on the AV flow. A laptop added by hand '
          'out of the catalog is recognized as the room\'s laptop whatever it '
          'was named.',
      'The release folder the app watches for updates can be set in App '
          'Config - App Updates: type or paste a path, or press Browse, then '
          'Save. The line under the box says whether the folder can be seen '
          'from this computer, the choice is remembered and survives an '
          'update, and Use default folder puts it back.',
    ],
  ),
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
      'Estimate-only rooms start empty: no template devices, and no PC, '
          'document camera or receivers added to the AV flow automatically.',
      'Add from catalog on the Cost tab asks where equipment goes: the AV '
          'flow and room config, the AV flow only, or the estimate only.',
      'The control schematic waits until the room has a processor, and '
          'offers to add one from the catalog.',
      'Crashes are written to the error log with a crash dump, and a session '
          'that did not close normally is noted the next time the app starts.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.10',
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
      'The Epson BrightLink driver is counted in the module tally.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.9',
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
      'Bulk deliveries, saved delivery locations and a default vendor list. '
          'The equipment page shows what has been delivered, and a project '
          'can list where its deliveries go.',
      'Quote requests can go to several vendors at once.',
      'Speaker output routing fixed; timeline overlap fixed.',
      'Screenshot tool works at any window size.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.8',
    date: 'August 25 - 31, 2026',
    title: 'Undo, purchase orders and campuses',
    changes: [
      'Multi-level undo and redo, including pricing.',
      'Purchase order tracking.',
      'Read Excel files, and a sync folder for Excel and Google Sheets.',
      'Campus view, manual edit mode for campus projects, and a base list of '
          'rooms.',
      'Rooms can be added to the cost projection by hand and converted to '
          'real rooms, and to the timeline before they exist.',
      'Screenshot annotation, zoom on image previews, and fit to screen.',
      'Lifecycle target, sorting, export and price editing by double-click.',
      'Cable colors, color picking for responsible parties, and contrast '
          'fixes.',
      'New start screen layout.',
      'Beginner guide, and a PDF version of the guide.',
      'Laptops can be flagged as never controlled.',
      'Chapters in exported PDFs, and error handling through the app.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.7',
    date: 'August 21 - 24, 2026',
    title: 'Projects, room types and the lifecycle rail',
    changes: [
      'Projects: rooms on a job, deadlines, pricing, to-dos, plans and a '
          'project workbook.',
      'Lifecycle rail and spares.',
      'Room types that stamp in a room\'s usual equipment, locations and '
          'cabling.',
      'Animation on the signal flow.',
      'Room history and sign-in data.',
      'Manufacturer search, "never in config", and replacing rack parts.',
      'New app icon, banner and navigation rail, and a new project and room '
          'setup screen.',
      'Opening a project folder can pick a file inside it.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.6',
    date: 'August 17 - 20, 2026',
    title: 'Presets, automatic routing and the schema editors',
    changes: [
      'Room presets, with defaults for modules and devices.',
      'Automatic routing and connection lines on the AV flow, drawn so '
          'overlapping runs separate rather than sitting on each other.',
      'Snap to grid, grid lines that do not export, and a blank background '
          'page for drawing floor plans on.',
      'Editors for the UI schema and the signal flow rules.',
      'Clear buttons for the schematic and the AV flow.',
      'The schematic view works with AV LAN and IDF drop-downs.',
      'USB in the AV flow, with the DMP, AV Bridge and document camera '
          'defaulting to the PC.',
      'Device merging by item type, with the model renamed to match and a '
          'banner when a device is swapped.',
      'Presenter mode and the annex in the schema, a relay port, and cable '
          'length spares.',
      'Updated config builder guide.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.5',
    date: 'August 8 - 13, 2026',
    title: 'Pricing, floor plans and racks',
    changes: [
      'Cost estimates with catalog pricing, MSRP and labor rates.',
      'Devices can be left off the cost estimate.',
      'A retired list, and catalog items taken from the diagrams.',
      'Floor plans and cabling, with movable labels and bendable lines.',
      'Rack builder and rack editor.',
      'AV signal flow drawings with curved lines, a color picker, a legend '
          'and a report.',
      'Undo for the drawings.',
      'Correct keys per device type in the configurator.',
      'Module stubs kept identical, and module settings and defaults.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.4',
    date: 'August 1 - 3, 2026',
    title: 'Saving, undo and edits as you type',
    changes: [
      'A Save button, and undo from the backup file.',
      'Edits apply as you type and are written to the file when Save is '
          'pressed.',
      'Per-device mute in the schema.',
      'New room configs include the environment block, and system keys are '
          'pruned or restored when device counts change.',
      'Export writes the JSON as well.',
      'Colors cleared for edited text on headers, and the config dictionary '
          'updated.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.3',
    date: 'July 23 - 31, 2026',
    title: 'Reporting, reboot commands and the encrypted password',
    changes: [
      'The processor password is encrypted, and autofill changed to match.',
      'Reboot commands, and an environment setting for the processor type.',
      'Changes to the report and to how items are written to the config.',
      'SFTP searching is space-agnostic, and the snackbar on open was fixed.',
      'Fixed a timer after a successful upload that could break the app, and '
          'a bug with new timers and an existing environment.',
      'Schema changes for VGA and for new config items; the group is left '
          'off scalers and switchers.',
      'A Python file that checks the documentation against the module files.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.2',
    date: 'July 14 - 17, 2026',
    title: 'Module documents, device info and the schematic',
    changes: [
      'Control schematic view and an exported report, with more schematic '
          'options and the button moved.',
      'Module documentation with a built-in PDF viewer and annotations.',
      'More model detail on the device info fields, and modules and '
          'documents assigned to the configurator builder.',
      'Excel export by column, with GUI fields tied to the touch panel - '
          'removing one removes the panel entry.',
      'A Deny button on the startup prompt, and a toggle for deleting '
          'without being asked.',
      'New app icon, and changes to how the schematic lines are drawn.',
      'Fixed the screenshot tool and a drop-down that did not load.',
    ],
  ),
  ChangelogEntry(
    version: '0.1.1',
    date: 'July 7 - 13, 2026',
    title: 'Schema-driven configs',
    changes: [
      'The whole app is driven by the UI schema, with key mapping for older '
          'configs, so devices and settings are set from the JSON rather than '
          'from anything hard-coded.',
      'The backup is named from the room in the file, and is written after '
          'key mapping so the name matches what the file actually contains.',
      'Model naming and key matching reworked, with more red flags for '
          'possible typos and a count of unneeded legacy keys.',
      'Auris theme, a secondary color, a color picker and a text size '
          'option.',
      'File settings moved into app data, with search, a New file button and '
          'a changed save location.',
      'Connection settings on the menu, and a toggle to set files to their '
          'default values.',
      'Fixed autosave, the building name, and the file paths for modules and '
          'buildings.',
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
      'Module function names and the parser.',
    ],
  ),
];
