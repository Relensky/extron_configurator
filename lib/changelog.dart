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

const String kAppVersion = '0.5.155+165';

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
    version: '0.5.155',
    date: 'October 19, 2026',
    title: 'Several screens at once',
    changes: [
      'Projection calculator: a throw distance entered in Throws - the projector\'s own or the room\'s - opens in the distance box already locked, so the screen size is worked from it. Unlock the box to try another.',
      'Floor plan: a selected projector has a Projection calculator button right after the screen it is paired with.',
      'Projection calculator: the units picked are remembered for next time, after the app is closed and opened again.',
      'Floor plan: Screen by size has How many. One click drops that many screens in a row, numbered Screen 1, Screen 2 and on after any already on the sheet, as one Undo step.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.154',
    date: 'October 19, 2026',
    title: 'Projector settings kept per projector',
    changes: [
      'Projection calculator: Save as the projector\'s throw distance also keeps that projector\'s settings - zoom, aspect, screen size, distance, lens shift, mounting and the units - so it opens again as it was. Apply keeps them too.',
      'Projection calculator: opened from the floor plan, the title is a drop-down of the room\'s projectors. Picking another keeps this one\'s settings and opens that one as it was saved.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.153',
    date: 'October 19, 2026',
    title: 'Room walls, locked-in calculations and worked-out reach',
    changes: [
      'Cost tab: each part on the Optional upgrades card shows its manufacturer, part number, model and category under its name, even while the options are left out of the room total.',
      'Projection calculator: opened on a projector or screen, Save keeps what was entered with that device, and it opens the same way next time, after the project is closed and opened again.',
      'Projection calculator and floor plan: Lock in records who approved a projector, screen or display, and when. While locked in, its angle, reach and size cannot be changed in the calculator or on the floor plan, and its bar says who approved it. Unlock asks first and takes the approval off.',
      'Floor plan: a selected screen has a Diagonal slider in inches. The screen, its viewing angle and its reach redraw as it is dragged, to try sizes in the room, and one Undo puts it back.',
      'Floor plan: Room walls, once the sheet has a scale. Click two opposite corners of the room, then type its width along the front wall, its depth and its ceiling height in feet and inches, and say which side of the sheet the front wall is on. The walls are drawn with their lengths, the front wall named, and the square footage and ceiling under them; the button shows the room size and area.',
      'Floor plan: a selected device shows how far it is from the front, back, left and right walls, and says so in red when it is outside them.',
      'Projection calculator: opened from a floor plan with walls, the ceiling is the room\'s. It shows the screen\'s drop from the ceiling, and warns when the image runs above the ceiling, when the lens cannot sit below the ceiling even with its shift, and when the throw is longer than the room is deep.',
      'Floor plan: the reach of a screen, display or projector is worked out, not set by hand. A screen or display reaches six image heights, the farthest seat that can still read it, and follows its size. A projector reaches its paired screen, or its own throw distance, or the room\'s. The bar shows the reach; the Reach slider is only on cameras, mics and the like.',
      'Floor plan: Screen by size also takes the image measured on the wall as width x height, such as 11\'8" x 6\'5".',
    ],
  ),
  ChangelogEntry(
    version: '0.5.152',
    date: 'October 19, 2026',
    title: 'Screens by size and calculator locks',
    changes: [
      'Floor plan: Add device has Screen by size, for a room whose screen model is not known. Pick the diagonal - type it or choose 100" to 165" - and the aspect, and the image is drawn to that size. Any selected screen also has a Size button to set it the same way.',
      'Projection calculator: each box has a lock. A locked box cannot be typed in, and picking a projector spec or dragging the projector leaves it as it is.',
      'Projection calculator: in feet, the distance, screen size, image bottom and ceiling take feet and inches together - type 11\'8", 11\' 8", 11.5 or 140".',
    ],
  ),
  ChangelogEntry(
    version: '0.5.151',
    date: 'October 19, 2026',
    title: 'Power outlets, the AV Flow key and projector throws',
    changes: [
      'AV Flow: Power outlets lists every device in the room, not only the few that already had a power inlet. A device without one gets a POWER inlet when an outlet is set to feed it.',
      'AV Flow: Power outlets shows where each device is and lets you set its location on the same row. Fill in order can take everything in one location - the rack, the ceiling - and Add location makes a new one without leaving the window.',
      'AV Flow: the key lines every signal up on the same edge, AV cabling and network included, and no longer prints Network twice.',
      'Floor plan: a projector can be set to Auto from screen, and new ones start that way. Its reach is the distance to its paired screen and its angle is the one that fills the screen, kept within the lens zoom from the catalog. The bar says when the projector is too close or too far for its lens to fill the screen. Turned off, it keeps the beam it was showing.',
      'Floor plan: a projection screen starts at the size its catalog entry gives (such as 120"), not a fixed 8 ft, once the sheet has a scale.',
      'Cabling: runs to a device with no location are left off the sheet instead of going to a Not placed yet box. A line above the sheet says how many were left off and which devices need a location; it is not part of the export.',
      'AV Flow: each box with a location says where it is on a line of its own at the top, under the name and model.',
      'AV Flow: with Edit on, drag the key anywhere on the drawing. Its pencil adds a note printed under the key, or puts the key back under the drawing.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.150',
    date: 'October 19, 2026',
    title: 'AV Flow toolbar groups and fewer crossing lines',
    changes: [
      'AV Flow: the toolbar buttons are in groups - Edit, Add and connect, Layout and view, Save and export - each with a name you can click to fold it away. The page title and device search sit on their own line above.',
      'AV Flow: Tidy layout also orders each column so as few cables cross as it can, moving each box level with what it is cabled to. Boxes with no cables keep their order.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.149',
    date: 'October 19, 2026',
    title: 'Labor tab layout',
    changes: [
      'Projects: on the Labor tab, an expanded room lists its crews and fees from the left edge instead of the middle.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.148',
    date: 'October 19, 2026',
    title: 'Removing a device from the AV Flow only',
    changes: [
      'AV Flow: the device edit window has a Remove from AV Flow only button. It takes the box and its cables off the drawing without adding it to the Cost page.',
      'AV Flow: in the device edit window, Rack U, Watts and BTU/hr line up with Name and Model.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.147',
    date: 'October 19, 2026',
    title: 'Finding devices, projector throws and locking',
    changes: [
      'AV Flow: a Find a device box in the toolbar. Type to search by name or model, or open the list and pick one, and the view jumps to that box and rings it for a few seconds.',
      'AV Flow: with Edit on, clicking a cable scrolls the cable list below the drawing to its row and highlights it. Clicking a row selects that cable on the drawing.',
      'Floor plan: each projector can keep its own throw distance. Click a projector to see its throw and set it; one without its own uses the room\'s.',
      'Floor plan: with more than one projector on the sheet, the Throws button lists every projector with its throw distance, plus the room\'s, to set them together.',
      'Projection calculator: opened on a projector, it starts from that projector\'s throw distance and saves back to it. The Throw distance box now lines up with the Aspect box.',
      'Floor plan: a Lock button on a selected device holds it in place. A locked device cannot be dragged, nudged with the arrow keys or removed with a right-click until it is unlocked, and shows a small lock on the sheet.',
      'AV Flow: moving one end of a cable now asks for the device first, from a list you can type into, then shows only that device\'s inputs or outputs to pick from.',
      'AV Flow: USB-C and USB connect without the adapter warning. A run between different plugs is listed as the cable it needs, such as USB-C to USB-A, in the cable list, the cable window, the cable schedule and the cable counts.',
      'AV Flow: a Dante port connects to a network switch port without the signal warning.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.146',
    date: 'October 17, 2026',
    title: 'Labor charges',
    changes: [
      'Cost tab: the tag button on any line can charge it to one of the room crews - lumber, conduit or parts a contractor or department needs. Lines you do not tag stay where they are.',
      'Charged lines move to a Labor charges section of their own, listed with the crew they go with and totaled before the room total. A switch counts them in the room total or leaves them out, like the optional upgrades.',
      'Projects: a With labor charges chip counts every room charges in the project total or leaves them out, beside a Labor charges total.',
      'Labor tab: fees charged with labor are listed per room and added up by job type and by who provides the labor, with labor and fees together.',
      'Estimate PDF, workbook and Google Sheet: each room has a Labor Charges section and a Labor charges line in its totals. The project Labor tab lists every fee charged with labor, and the Summary shows the labor charges total.',
      'Labor tab: the room list can also be sorted by labor amount, biggest first. In-kind labor and charged fees count.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.145',
    date: 'October 17, 2026',
    title: 'Buildings and departments',
    changes: [
      'Projects: the Buildings field has a drop-down listing every building on the job, with its room count and total. Untick a building to leave it off the project page: the totals, rooms, equipment, labor and funding all follow. Every building is ticked when a project opens, and a chip at the top shows what is hidden with a button to show everything again.',
      'Exports and quote requests always cover the whole job, whatever buildings the page is showing.',
      'Priorities and funding: each room and line item has a Department. Under the budget figures, two tables break the budget down by building and by department: rooms, money set aside, share of the budget and what the rooms come to.',
      'Workbook and Google Sheet: the Summary tab lists the budget by building and by department.',
      'Labor tab: sort the rooms by project order, room name or priority. The job type and who-provides-it breakdowns are now above the room list, on the page and on the workbook tab.',
      'Labor tab: totals are worked out once per change rather than on every redraw.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.144',
    date: 'October 17, 2026',
    title: 'Project labor breakdown',
    changes: [
      'Projects: a new Labor tab lists every room with its labor cost, hours and the labor rates it is costed from. Open a room to see each crew line: job type, whether the rate is off the rate card or its own, techs, hours, rate, cost and who provides it.',
      'Labor tab: a breakdown by job type (department / contractor) with the rate, the rooms using it, hours and cost, and a breakdown by who provides it - paid by the job, our staff in kind, or another department.',
      'Projects: the Labor figure at the top of the page now opens the Labor tab.',
      'Workbook and Google Sheet: a new Labor tab with labor by room, by job type, by who provides it, and every labor line room by room.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.143',
    date: 'October 17, 2026',
    title: 'No more hangs on save',
    changes: [
      'Fixed: saving a project with its online copy froze the app. The whole job for the hidden Project data tab was read from the share one file at a time on the window, twice per save. It is now read in the background, a few files at a time, packed once for both the workbook and the Google Sheet, and compressed off the window.',
      'Backups before a save, and your own copies after it, run off the window.',
      'Opening a room reads its drawing, cost, rack and floor plan files in the background, and tidies an older room\'s loose files there too.',
      'Opening a project checks its rooms in the background, all at once.',
      'Team mode reads the saved file in the background after every save and open, and when combining.',
      'Reading the published workbook back after a save happens in the background.',
      'First-Time Setup checks its folders in the background.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.142',
    date: 'October 16, 2026',
    title: 'A project is never saved empty',
    changes: [
      'Fixed: closing a project while it was saving with an online copy could save an empty project over the real file. The save now finishes only for the project it started on, and a project closed meanwhile is not written anywhere.',
      'The online copy never writes its project copy over the project file itself, for a job published into its own folder.',
      'A project with no name and no rooms is never saved over a project file that has rooms.',
      'Every project save first keeps a copy of the file as it was, in a project_backups folder beside it (the last 20).',
      'Your own backups: every project you open or save is also copied into your own app data, in the backups folder (the last 60 of each). They are kept apart from the recovery copies, which are cleared on save, and an empty project is never kept.',
      'Rooms: every save first keeps a copy of the whole room - the config and its drawing, cost and rack files - in room_files, backups (the last 10), and every room you open or save is copied into your own app data too (the last 30). A room closed or switched while it is saving is not written, and an empty room is never saved over one that has its setup.',
      'Campuses: every save keeps a copy in campus_backups beside it (the last 20) and in your own app data. Saving a campus also backs up each project it points to before writing it, and never rewrites an empty project.',
      'The project workbook and the Google Sheet carry the whole job in a hidden Project data tab: the project file and every room\'s files. File, Open, Restore Project from Workbook puts the job back from a workbook or a Google Sheet downloaded as Excel. The project file there now is copied aside first, and room files already there are kept unless you ask to replace them.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.141',
    date: 'October 16, 2026',
    title: 'Tie in sequence, power outlets, no-spares jobs',
    changes: [
      'AV Flow: Tie in sequence ties one set of boxes named in order to another - 12 decoders to 12 displays, 12 PCs to 12 encoders - or a run of one box\'s connectors, such as a power strip\'s outlets or a switcher\'s inputs. Pick the output and the input (HDMI 1 or HDMI 2, say), pair by the number in the names or in order, and pick the starting outlet or input. The list shows each run, with a tick, and what it would replace; one Undo takes them all off.',
      'AV Flow: Power outlets lists a power strip\'s outlets, each with a drop-down of every box with a power inlet, plus Fill in order for a set named in sequence. A box moved to a new outlet comes off its old one.',
      'AV Flow: Auto-route by name has a More ties button that opens Tie in sequence.',
      'Project page, Spares: No spares on this job turns off the No spare warnings for the project. The same switch turns them back on.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.140',
    date: 'October 16, 2026',
    title: 'Devices stay on the quote; route by name',
    changes: [
      'AV Flow: Recreate from config keeps the boxes you added by hand and the cables on them. It used to clear them, which took them off the Cost page too.',
      'AV Flow: removing a box from the drawing keeps it on the Cost page as a quoted line. Placing it back takes the line off again, so it is never quoted twice.',
      'AV Flow: Place undrawn lists every device not on the drawing - config devices and Cost page equipment - with a tick each, and places the ticked ones.',
      'AV Flow: Auto-route by name cables boxes whose names end the same, such as NAV Decoder Station 1 and Station 1, output to input on video. You see the list, with a tick each, before anything is drawn.',
      'NAV endpoints and the NAVigator are cabled to the network switch whichever way the switch or the NAV boxes go on the drawing: Add device, the Cost page, Place undrawn or the Devices panel.',
      'Cost page: Place on the AV Flow, on the menu of an equipment line that is not drawn, draws it without a config block. A line not in the catalog is drawn as a plain box.',
      'Cost page: adding a part always offers all three choices - estimate only, estimate and AV flow, or estimate, AV flow and room config - for equipment, rack hardware and other items. Cable is estimate only.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.139',
    date: 'October 16, 2026',
    title: 'Edit shape, magnifier zoom',
    changes: [
      'AV Flow: Edit shape (in a device\'s Edit dialog) puts handles on the box\'s right edge, bottom edge and corner, so you can drag it wider or taller. The side connectors spread out to fill a taller box. Reset size puts it back; Done hides the handles.',
      'AV Flow magnifier: - and + beside it change how big the lens shows the drawing (25% to 400%), and the size button makes the lens small, medium, large or extra large. Near the edge of the page the lens moves to the other side of the pointer.',
      'Catalog: the Netgear M4250-40G8F-PoE+ has ports 1-20 on the left, 21-40 on the right and power on the bottom.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.138',
    date: 'October 16, 2026',
    title: 'NAV endpoints on the switch in order',
    changes: [
      'AV Flow: in a room with a NAVigator, NAV endpoints are cabled to the network switch on its next free ports in order - encoders first, then decoders, then the NAVigator. It happens when they are added, and with Add all cables from config.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.137',
    date: 'October 16, 2026',
    title: 'Add many connectors, more categories',
    changes: [
      'Device Editor and the AV Flow device dialog: Add several adds a run of connectors at once - say 48 - with one type, direction (input, output or both) and location (left, right, top or bottom), numbered from where you choose.',
      'New category: Network switch (no module), for switches with no control module behind them. It is offered as equipment but not tied to a config section or a base cost.',
      'Device Editor: Add or remove categories (at the bottom of the category menu) adds your own categories. They are saved with the catalog, so everyone using it sees them.',
      'Team chat: clicking anywhere off a picture you opened closes it, the same as the close button.',
      'Cost page: on a line whose part is already in the catalog, the catalog button now says Update (part) in the device catalog instead of Add this line. When that entry has no price, it says so, and the dialog asks for a list price before it saves, instead of saying the catalog already has an entry.',
      'Cost page: Other items is above Rack hardware.',
      'Cost page: the Optional upgrades card, above Equipment, also shows when only a labor crew is optional.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.136',
    date: 'October 16, 2026',
    title: 'Cost page tidy-up',
    changes: [
      'Optional upgrades card: Options in their own section shows only while Room total with options is on. Left out of the total, options are always listed apart, so the switch did nothing. Options listed in their own sections are marked optional on the PDF.',
      'Cost page: the Optional upgrades card is at the top, above Equipment.',
      'Cost page: the row buttons line up on every table - the tag button, then replace, then the catalog, then the catalog price, then delete. On Other items and the cable lines the tag button moved into that column, and on cabling the base-cost button moved left of it.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.135',
    date: 'October 16, 2026',
    title: 'Cables from config, quantities across rooms',
    changes: [
      'AV Flow and the Cost page Cabling card: Add all cables from config draws every run the config describes, including ones deleted by hand. Boxes deleted by hand stay off. One press of Undo.',
      'Compare and copy: a part both rooms have in different numbers gets Copy quantity, and Copy all quantities does every one. A part typed on the Cost page takes the count; a drawn one in the open room is set the way the Qty box sets it, and in another room the count is quoted.',
      'Quantity minus and a lower typed count now take the units off even when they are cabled or in the config: their cables come off, and a config device comes out of the room config with the count brought down. Taking a room from three projectors to two leaves two.',
      'Optional upgrade can be ticked on every line, drawn ones included, and on labor. Other items rows have the tag button too, with In kind and Furnished by. Remove options not bought takes a drawn optional part off the AV Flow and an optional crew off the labor.',
      'Cost page: an Estimate only switch at the top. On, it hides the Wizard, Devices, System and Raw JSON tabs and deletes nothing - the room config, AV Flow, Floor Plan, Schematic, Cabling, Racks and Photos all stay. Off converts it back to a programmed room.',
      'Other items: each line has Replace with another model, like the equipment, and can take any part in the catalog - mounts included.',
      'Project page: each room row shows its In kind value and its Options price. The totals strip at the top adds In kind and Options, and the Budget card shows the options, the in-kind value, a Rooms estimate with options switch, and the full list of in-kind items room by room.',
      'Project page: Deliveries and Quotes have swapped icons, and Equipment has its own.',
      'With a room open, the room close button stays beside the project close X on the Project tab, so the room can be closed from there.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.134',
    date: 'October 16, 2026',
    title: 'Drawn parts swap across rooms, priority buys by line',
    changes: [
      'Compare and copy, Replace a part: a part drawn on the other room\'s AV Flow, such as a camera or a Via Go, can be replaced now. Its box takes the new model in place and keeps its cables and spot. It was greyed out before.',
      'Project rooms whose priority buys only some categories, like P5 buying only projectors: each line has a Bought for priority tick on its tag button, and anything you add to the room is ticked for you. Lines left as existing show a box icon. Rooms whose priority buys everything have no tick.',
      'The project add-on for a priority, such as the P5 mount, is listed under Other items. Remove it to take it off that room only, or change its model, description or part and it becomes a line of that room, still bought for the priority.',
      'Cost page: Other items is above Cabling.',
      'Project page: the Packages tab is called Quotes.',
      'Optional upgrades: tick Optional upgrade on the tag button of any part added on the Cost page. An Optional upgrades card shows what the options come to and the room total with and without them, with switches for Room total with options and Options in their own section. The estimate PDF follows the switches and prints both totals.',
      'Optional upgrades, project page: With options beside the project total counts every room\'s options, and shows the total the other way. Each room with options has a button on its row to leave its options off the project total.',
      'Optional upgrades: Remove options not bought takes them off the room once it has gone out to buy without them.',
      'Equipment typed on the Cost page is left off as existing when the priority does not buy its category, the same as drawn equipment.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.133',
    date: 'October 16, 2026',
    title: 'Replace parts across rooms, sort the room menu',
    changes: [
      'Team chat: switching between light and dark mode with the chat open no longer trips over the chat button.',
      'Compare and copy: with Replace existing items on, a part only one room has gets a Replace a part menu. Pick a different part in the other room, such as its projector, and the copy takes that one off and puts this one on in its place. The confirm window lists what is taken off.',
      'Room menu in the title bar: Sort A to Z and Sort by priority at the bottom. By priority lists P1 rooms first, then P2 and on, with rooms that have no priority last. Your choice is remembered.',
      'AV Flow, Copy from a room: each copied device can be added as a new box, left out, or put in place of one this room has. A replaced box keeps its spot, cables, rack place and floor plan icon, and takes the model and part number from the other room. Replace matching types pairs them all by type in one press.',
      'Copy from a room, floor plans: each piece of gear placed on the copied sheets has a tick box. A sheet this room already has keeps its drawing and gets the ticked gear it does not have yet, instead of being skipped.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.132',
    date: 'October 16, 2026',
    title: 'Readable reaction counts',
    changes: [
      'Team chat: the number on an emoji reaction is now light or dark to suit the chip behind it, so it no longer shows as dark text in dark mode.',
      'Drawings: a dashed line or cable label with a broken length is now skipped instead of being drawn forever.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.131',
    date: 'October 16, 2026',
    title: 'In kind: what we give from stock and labor',
    changes: [
      'Cost page: equipment, rack hardware, cabling and other items marked "In kind - from our stock" (the old Used from stock) are listed at what they are worth and left out of the total, the same as before.',
      'Labor: each crew has an in-kind button. "In kind - our staff" leaves its hours off the total and lists them at the rate as in kind; "By another department" does the same under that name.',
      'Totals: an In kind block under the total lists what is given by who - our stock, our labor, the owner, another department - with the in-kind value and the project value with it added.',
      'Estimate PDF, spreadsheet and text: an In kind table lists each line given, who gives it and its value, with the in-kind value and project value with in kind beside the totals. In-kind lines say In kind rather than By others. The project workbook\'s building total adds the in-kind value of every room.',
      'Add equipment, cable, rack hardware or other items: tick "In kind - from our stock" to add a part from the shelf. Typed by name, it does not need to be in the catalog, and Value each sets what it is worth.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.130',
    date: 'October 16, 2026',
    title: 'Copy from other rooms, fewer combine nags, catalog combine details',
    changes: [
      'Cost items, Copy from another room: the room list was blank on jobs whose rooms each sit in their own folder, like the BSS test project. Rooms are named by their folder there now.',
      'Cost items, Copy from another room: Room file picks a room\'s config.json straight off disk, with no project needed. The project list starts with Open project file, then the open project and your recent projects; rooms you opened lately are listed first, with a clock.',
      'Compare and copy: the window stays open after a copy, so you can copy one way and then the other before closing it. Both rooms are priced again after each copy.',
      'Compare and copy: Replace existing items lets you tick a part both rooms have; copying takes the other room\'s line off and puts this one on in its place. A part drawn on the room\'s diagram cannot be replaced from here.',
      'Room menu in the title bar: each room shows its priority on the job as P1, P2 and so on, and the button shows the open room\'s.',
      'Opening a job no longer rewrites it just because prices moved. Each PC re-priced every room at its own catalog prices and saved the totals into the shared job, so everyone else was asked to combine "room snapshots" for rooms nobody had touched. Rooms whose files changed are still noted and saved.',
      'Combine: a save that only differs in those room totals no longer asks you to combine, and the totals are left off the combine list and the combine history.',
      'AV Flow, Copy from a room: copies another room\'s AV flow, racks, floor plan sheets (with their drawings) and cabling sheet into this one, alongside what it has. Pick the room the same way as for cost items, then tick the parts. Jacks are renumbered for this room, and Undo takes the copy back off.',
      'Copy from a room: a device or rack part the other room uses that is not in your catalog is listed first. Add each to the catalog, with the connectors drawn in that room and a category you can change, or leave it out of the copy with its cables and rack place.',
      'Combine, catalog: before taking another person\'s catalog save, a window lists each model they added or changed and every field, with your value and theirs. Each field taken goes in the combine history.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.129',
    date: 'October 15, 2026',
    title: 'Working-on tags: clear your own, a warning for others\', messages and history',
    changes: [
      'Working on tags: a tag someone else put on you, you can take off yourself - every tag on the team page has an x, and the person button in the title bar unticks you.',
      'Working on tags: anyone can take anyone\'s tag off, but taking someone else off warns first. They get a direct message from you, and it is kept in their tag history.',
      'Working on tags: putting someone on a room, or taking them off it, sends them a direct message from you.',
      'Team page, Working on: History lists every change to your tags - who put you on what, and who took you off. Clear my tags now takes off the tags on you as well as the ones you placed (anyone you placed is told).',
    ],
  ),
  ChangelogEntry(
    version: '0.5.128',
    date: 'October 15, 2026',
    title: 'Sideways scrolling from the keyboard',
    changes: [
      'Save Room as Preset: the estate sheet name and jack prefix boxes line up.',
      'History, People: lists everybody who changed the job, its rooms or the campus. It counted the job\'s own log only, so people who worked in the rooms - like ngeiger and zpearse on the 600k refresh - were missing. Press a name to see their changes on the Changes tab, from every log. People is there when only a room is open too.',
      'Procurement log: the sideways scrollbar sits on the bottom edge of the window at all times. Before, it sat under the last row, or partway up the page. The last rows still scroll clear of the Screenshot and Export buttons.',
      'Scrolling sideways: Left and Right scroll a table or page that is wider than the window when nothing is selected - the one under the pointer. In a text box they still move the cursor, and on a drawing with something selected they still move it. They are under Nothing selected in App Config, Keyboard shortcuts.',
      'Scrolling sideways: Shift and the mouse wheel scroll pages and tables sideways, and now have a test to keep it that way.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.127',
    date: 'October 15, 2026',
    title: 'Save a whole room as a preset',
    changes: [
      'File menu: Save Room as Preset saves the whole room as a room type - the AV flow, racks, floor plan sheets, cabling sheet layout, cost page, control schematic layout and the switcher inputs and outputs. The window sets its name, description, estate sheet name and jack prefix, and a tick for each part says what goes in.',
      'Room presets: a room made from one gets all of it. The cost page comes in whole when the room has none, keeping the room\'s own tax rate; a room with its own cost page gets only the preset\'s lines. Floor plan sheets come without their drawing images, which stay with the room they came from.',
      'App Config, Shared lists: the room and cost presets on the shared folder are listed, with what each holds and who saved it, a button to open each folder, and a delete button.',
      'Cost, Other items: a line off the catalog shows the catalog\'s price behind its unit price box and in Extended, the same as the equipment rows. It read blank and \$0.00 before while the total still charged it. A price typed is this room\'s price for the line.',
      'Catalog: an entry can have no connectors. Deleting its POWER connector sets Power to None, so saving no longer puts it back; a part added to the catalog from Other items starts with none.',
      'Add equipment, cable, rack hardware and other items: All catalog items searches the whole catalog, says where each part goes, and files what you pick by its category - Equipment, Rack hardware, Cabling or Other items.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.126',
    date: 'October 15, 2026',
    title: 'Pick what to copy between rooms, and catalog autosave',
    changes: [
      'App Config, Autosave and recovery: Save the catalog automatically saves the device catalog on the same clock when it has changes. It merges with what others have saved, the same as Save, and waits while a changed entry has no category. Off until turned on.',
      'Text boxes: Up and Down move a line in boxes on the Cost page, such as Scope of Work and Estimate Notes. They did nothing there before.',
      'Compare: tick the parts to copy, and copy either way - into this room, or into the other room, which is written to its cost file. A part the other room already has cannot be ticked, and Tick all picks every missing part.',
      'Compare: devices drawn on a room\'s diagram - projectors, switchers, speakers - and its counted cable runs can now be copied. They go onto the other room\'s quote as added lines, under the same catalog model, quantity and room price.',
      'Cost items: Copy from another room opens the comparison ready to tick. Copying and applying a cost preset now list what is being added by category, add without replacing anything, skip what the room already has, and Undo removes them.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.125',
    date: 'October 15, 2026',
    title: 'Compare room costs, cost presets and text-box keys',
    changes: [
      'Catalog: saving a catalog entry that has no category asks for one, and says what each category limits the entry to - which lists offer it and how it is priced. Save without keeps it blank; Cancel stops the save.',
      'Catalog: the Category box says under it what the chosen category limits the entry to, and each category in the picker says the same when you hover over it.',
      'Keyboard shortcuts: a new In a text box section in App Config - Tab and Shift+Tab move between boxes, Up and Down move a line, and Home and End jump to the top and bottom of the box. Each can be changed like the other shortcuts.',
      'Narrow windows: the sideways scrollbar on the Cost page, and on any page wider than the window, now sits on the bottom edge instead of partway up the page.',
      'Add equipment: devices filed under AV / Misc that have connectors - DTP extenders, speakers, network switches and the like - now show up in the search. Only AV / Misc entries with no connectors are treated as Other items.',
      'Cost: equipment added while the table is sorted by manufacturer goes into its manufacturer\'s group in alphabetical order, not at the bottom of the table.',
      'Cost image and PDF: prices print as money - the currency sign, commas and cents - so 11948 prints as \$11,948.00. Labor rates now show the currency sign too.',
      'Cost: Compare puts this room beside another room from this project or any other - parts matched by part number, with what only one room has, quantities and prices that differ, and the section and grand totals side by side. "Differences only" hides the parts that match.',
      'Cost: Cost items copies another room\'s added equipment, rack hardware, cable, other items, labor and fees into this room, with the prices typed on them. They can also be saved as a cost preset in the cost_presets folder under the Root Folder and applied to any room. Applying adds to what the room has - a fee it already has by name is skipped - and Undo takes it all back off.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.124',
    date: 'October 14, 2026',
    title: 'Team chat\'s X stays on top',
    changes: [
      'Team chat: the X that closes the chat now stays above other pop-ups, the way the chat window does - a dialog opened while the chat was up used to cover it.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.123',
    date: 'October 14, 2026',
    title: 'Shared folders by default, and a 0% tax warning',
    changes: [
      'App Config: a blank Root Folder now means the shared Configurator_Files folder on the file server when it can be reached, else the app\'s own folder.',
      'App Config: a blank Class Schedule now reads the file from the Calendar folder on the file server when it can be reached, else from the Root Folder.',
      'Find maintenance windows: At least has Other length... for any length to the minute, and Day from and to have Other time... for any clock time, not just the whole hours on the list.',
      'Tax rate: the box is outlined in red when the rate is 0%, on the Project tab, the room\'s cost page and the default in App Config.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.122',
    date: 'October 14, 2026',
    title: 'The chat count stands out',
    changes: [
      'Team chat: the unread count on the chat button is the color opposite your accent color, with black or white numbers, whichever reads. Before it was a solid white pill that never changed, and hard to see on a light accent.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.121',
    date: 'October 14, 2026',
    title: 'Paths wait for you to finish typing',
    changes: [
      'App Config, Files and folders and Data files: a path is used once you stop typing for a moment, or press Enter, or click out of the box - not on every letter typed or deleted. Before, each keystroke went off to read a half-typed folder on the share, and the box was rebuilt under the cursor. A spinner shows in the box until the folder has been read.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.120',
    date: 'October 14, 2026',
    title: 'One tax rate for everyone on a job',
    changes: [
      'The tax rate is shared through the files. A job with no tax rate of its own takes the default of whoever opens or saves it with one, so the same job prices the same on every PC. Before, each person\'s own default was used, the totals came out different on each PC, and the job kept reporting its rooms as changed and asking to combine. A job set to 0% on purpose keeps 0%.',
      'A room that follows the base rate keeps the rate it was last saved at. Somebody with no default tax rate set prices it at that rate instead of 0.',
      'A new project made on a PC with no default tax rate is left unset rather than set to 0%, so a colleague\'s rate can fill it in.',
      'Combine: a tax rate in somebody else\'s save is its own choice at the top of the window - use theirs or keep yours - and says plainly that using theirs overwrites your tax rate. Where you both changed it, the choice says the same.',
      'Cost page, Edit in catalog: the List price and Education price boxes line up, and so do Category and Rack U. A helper line under one box used to push the other out of line.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.119',
    date: 'October 14, 2026',
    title: 'Room photos, and a pull before every publish',
    changes: [
      'New Photos tab for a room. Add photos and they are copied into a photos folder in the room\'s own folder, so they go wherever the room goes. They show as a grid; click one to see it large, zoom in, and use the Left and Right arrow keys to step through. Photos copied into the folder by hand show up too. HEIC photos from a phone are listed and open in the Windows viewer.',
      'Online copy: Publish pulls the Google Sheet first and always asks before writing over it. If anything was typed into it, you see the changes first. If it could not be read (signed out, offline), it says so and asks before overwriting anyway. Before, a Sheet that could not be read was published over without a word.',
      'Online copy on save: if the Google Sheet cannot be read first, the save leaves it alone and reports it as not updated, instead of writing over edits it could not check.',
      'Lists on every page leave room at the bottom for the floating chat button, so you can scroll past the last row and click it - the line lists in the Schematic and AV Flow edit panels included.',
      'AV Flow: the moving arrows on a clicked line show in the magnifier too, at the magnifier\'s zoom.',
      'Schematic: zooms out much further. It used to stop once the drawing and a fixed margin around it filled the window, so a small schematic could barely be zoomed out at all.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.118',
    date: 'October 14, 2026',
    title: 'Bundles find their module',
    changes: [
      'Bundles and kits find their python module. A catalog model that is a driver\'s model with words added on the end - "ShareLink Pro 2000 Miracast & ShareNext US", "IN1808 IPCP SA LL", "SMP 351 - 80 GB SSD" - now counts as that model. Adding one to the room config from the Cost page puts it in the right device family with the module filled in, instead of saying no device family fits.',
      'Cost page: a new "Tie to a Python module..." choice on an equipment line. Pick the driver that talks to the product and the model is added to that driver\'s list of models, then the line is added to the room config. Every room after that finds the module for it. The "no device family fits" message offers the same thing.',
      'Combine: the window names who saved and on which PC ("jsmith on PC-9") instead of "Someone else". Opening a job saves the room check straight away, and that save never said whose it was.',
      'Combine: a job\'s rooms are shown by their name and id - "BSS 103" (room10) - instead of Room1, Room10.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.117',
    date: 'October 14, 2026',
    title: 'The magnifier works',
    changes: [
      'AV Flow: the magnifier works. Turning it on used to shrink the drawing area to nothing, the lens never heard where the pointer was, and in the installed app the picture it draws from was never taken. Now the square lens follows the pointer over the drawing, full size and sharp, with its minimap in the corner.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.116',
    date: 'October 14, 2026',
    title: 'Calmer highlights, a zoom bar, a magnifier that works, tidy schematic',
    changes: [
      'AV Flow: a zoom bar over the drawing - zoom out, the zoom percentage, zoom in, fit the whole drawing on screen and actual size - like the screenshot tool. The mouse wheel now zooms all the way out too, and zooming after Fit to view behaves.',
      'AV Flow: the magnifier is a square that follows the pointer and shows that part of the drawing full size and sharp, with a minimap in its corner showing where in the room you are. It no longer turns the screen black.',
      'Schematic: Tidy layout spaces everything out evenly - the processor in the middle and the devices round it in a full circle, grouped by how they connect. With more than 16 devices they are laid out as a table under the processor instead. One Undo puts it back.',
      'Cost: the device names editor for a line of config devices says what kind each one is - Switcher device 1, Power device 2 - instead of SWITCHERDEVICE_1.',
      'Project: Refresh re-reads the rooms in the background, keeping the figures on screen until the new ones are in, instead of freezing the window while thirty rooms are read off the share.',
      'Rooms: locked, ready-to-approve and approved rooms are outlined again, in muted colors with a faint wash, instead of a solid fill. The outline eases in over a moment when the state changes and then stays still - no pulsing or glow. The colors still lean toward your accent color and read on light and dark themes.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.115',
    date: 'October 14, 2026',
    title: 'Tidy layout, zoom out with a magnifier, cables not drawn',
    changes: [
      'Rooms: locked, ready-to-approve and approved rooms are now a solid tinted row with a colored stripe down the left - no outline, no pulsing. The colors lean toward your accent color while staying four different colors, and the room button at the top becomes a solid pill in the color.',
      'AV Flow: Tidy layout (always on the toolbar) lays the drawing out again so nothing overlaps - sources on the left, switching and processing in the middle, displays and projectors on the right. With more than six displays or projectors they are drawn as a table instead of one tall column. One press of Undo puts it back.',
      'AV Flow: zoom out as far as you like, and Fit to view now fits any room however small that makes it. Turn on Magnifier and a lens follows the pointer showing that part of the drawing full size.',
      'Cost: the cabling table has a Not drawn column for cable the job needs that is not a run on the diagram. Add cable puts its count there, and Spares are now their own count on top of it.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.114',
    date: 'October 13, 2026',
    title: 'Room colors you can see, smoother syncing',
    changes: [
      'Rooms: the lock and review colors are checked against what they sit on - the page, the menu or the title bar - and darkened or lightened until they stand out, in light and dark mode and with any accent color. Once a room\'s outline has pulsed it settles to a quiet line and a light wash instead of glowing.',
      'Speed: when someone else saves the room or project you have open, the copy on the share is now read in the background instead of holding up the window, and History reads the other rooms\' and jobs\' logs in the background too.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.113',
    date: 'October 13, 2026',
    title: 'Locked rooms stand out',
    changes: [
      'Rooms: a room you are working on shows the same lock as one someone else has, in green instead of red, and says "Locked by you". The lock and editing badges are larger.',
      'Rooms: the room list on the Project page, the room drop-down, the room button at the top and the Priorities list outline each room in its state - red when someone else has it locked, green when you do, amber when it is ready to approve, blue when it is approved and ready to order. The outline pulses a few times when the state changes, then stays lit.',
      'Save: when someone else has the open room locked, a red lock and the word Locked sit beside the Save button. Pressing it asks whether to take them off the room, as Save does.',
      'Profile: your picture is much larger in Your profile, and your avatar in the top-right corner grows while the pointer is on it.',
      'Team chat: the hovering chat button is now your accent color, and its unread count is shown in the inverse colors.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.112',
    date: 'October 13, 2026',
    title: 'Hovering chat button shows up',
    changes: [
      'Team chat: the hovering chat button in the bottom-right corner now appears once the team chat has connected. In 0.5.111 it never showed.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.111',
    date: 'October 13, 2026',
    title: 'Hovering chat, combine details, typed cable lengths',
    changes: [
      'Team chat: the chat button now hovers in the bottom-right corner of the page, as in the CTS Dashboard, and fades back when the pointer is away. The chat icon at the top right is gone.',
      'Rooms: the editing and locked badges on a person\'s picture are larger, and the Priorities list on the Project page shows who is working on each room.',
      'Working together: a save made while another copy was checking the file (still being written, or held by the share) no longer loses its "saved the room - Combine" message. The check tries the file again for a few seconds instead of skipping that save.',
      'AV Flow and Cost: a cable length can be typed in feet as well as picked from the list - on the cable dialog, the Cable lengths list and the cost sheet\'s Add cable.',
      'AV Flow: a newly added device no longer lands on top of another; it moves down until it is clear.',
      'Combine: the message, the button and the review window now name the room, project and campus (for example "jsmith saved BSS 103 on Bessey Hall"), and the window lists the file and when the save was noticed. Changes are grouped under what they belong to; open any line for its file, its place in the file and the whole value before and after. Rooms on a job are named by their folder rather than "room10".',
      'History: What has been changed now also shows other people\'s changes to every other room on the job (Other rooms) and, for a job on a campus, every other job there and its rooms (Campus). Each line says the job and room it was made in, and opening it shows the file it is kept in.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.110',
    date: 'October 12, 2026',
    title: 'Cost estimate readable in portrait',
    changes: [
      'Cost estimate: on a narrow or portrait window the page now scrolls sideways (scroll bar along the bottom) instead of squeezing the Device and Model columns until they cannot be read.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.109',
    date: 'October 11, 2026',
    title: 'Chat opens on the newest message; favorite threads; who is working on what',
    changes: [
      'Team chat: every channel and thread now opens on its newest message - the chat used to stop partway up a long thread.',
      'Team chat: star a channel, room thread, project or direct message (the star beside its name at the top, or Add to favorites in its ... menu) and it moves to a new Favorites section at the top of the list. Star it again to put it back.',
      'Team page: a Working on list shows what everyone is tagged on - tickets and rooms - and which app each tag was made in (Dashboard, Builder or Instructor). Tags you placed have an x, and Clear the tags I placed takes them all off at once.',
      'Team: an app whose online note could not be replaced on the share (another PC had it open) no longer looks offline to everyone else; it writes the note in place instead.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.108',
    date: 'October 11, 2026',
    title: 'Typed quantities that go down, and part of a line from stock',
    changes: [
      'Cost estimate: typing a lower Qty on a drawn line now takes the extra units off the diagram, like the minus button, once you press Enter or click away. Cabled units and units in the room config stay, and the quote keeps the number you typed.',
      'Cost estimate: part of a line can come from stock (or anyone else) and the rest be bought. On the furnished button of a line pick "Only some of them..." and type how many - only the bought ones are added to the total, and the quote notes how many are furnished.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.107',
    date: 'October 10, 2026',
    title: 'Crop on the screenshot tool',
    changes: [
      'Screenshots: the annotation editor has a Crop tool (beside the hand). Draw a box round the part to keep and press Apply crop - Copy and Save PNG then take only that part. The box shows its size in pixels while it is drawn, the marks stay editable, and Reset crop brings the whole picture back.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.106',
    date: 'October 10, 2026',
    title: 'Settings the same in every CTS app, and light or dark at first start',
    changes: [
      'Application Configuration: Application updates (shortcuts, checking for a new version, the release folder) is now always the first card and Application logs the second, as in every CTS app; the rest follow in alphabetical order.',
      'Application logs: View logs, Open log folder and "Show log times in" - read the logs in this computer\'s time zone, UTC or a fixed offset - with the log folder setting under them.',
      'First-Time Setup asks light or dark as well as the accent color, starting on whatever Windows is set to.',
      'Log viewer: opens at the newest line straight away, even on a very long log.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.105',
    date: 'October 10, 2026',
    title: 'Team chat sections fold, and room threads reopen in a click',
    changes: [
      'Team chat: each section of the chat list (Channels, Room threads, Projects, Direct messages, Online now) folds to its heading with a click. The Room Config Builder remembers its own folds, apart from the other CTS apps. A folded section still shows the thread you have open, and its heading counts what is unread in it.',
      'Team chat: under Room threads, "Reopen a room thread" lists every room thread that is closed or was never opened here - click one to bring it back. With more than six there is a box to find a room.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.104',
    date: 'October 10, 2026',
    title: 'No more save prompts for untouched rooms, and faster job loading',
    changes: [
      'Rooms: opening a room no longer marks it as changed when nothing was. A box on the AV Flow titled differently from its device in the config takes the config name as the room opens, and that used to count as an unsaved edit - so switching away asked to save. It happened on 14 of the 30 rooms on the 600k refresh job.',
      'Projects: opening a job reads six rooms at a time instead of one after another, so a big job on the shared folder loads several times faster.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.103',
    date: 'October 10, 2026',
    title: 'Tabs back to how they were, and quicker room switching',
    changes: [
      'Tabs: pages are no longer kept loaded after you leave them. It used about twice the memory and did not speed up switching rooms, so each tab is built fresh when you open it again, as before. A new tab now zooms in slightly as it fades in.',
      'Rooms: switching rooms shows the new room as soon as it is loaded. Checking the job for rooms changed on other computers carries on in the background instead of holding up the switch.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.102',
    date: 'October 9, 2026',
    title: 'No more freezing when opening a room',
    changes: [
      'Opening a room on a project no longer freezes the window while the shared folder is slow. Checking the job\'s other rooms for changes used to happen one file at a time with the window stopped - half a minute on a 30-room job tonight. It now checks them all at once in the background, and the window keeps drawing.',
      'Typing no longer waits on the shared folder: the title bar and banner checked it on every keystroke (whether there was a save to undo, whether the campus sheet was there).',
      'Combining saves no longer holds up the save after it - the combine history is written in the background - and a big combine puts at most 25 lines on the room\'s own history, with the rest under History > Combines, so it cannot push out older entries.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.101',
    date: 'October 9, 2026',
    title: 'Raw JSON header on narrow windows',
    changes: [
      'Raw JSON: on a narrow window the "Applied" status moves under the page title instead of running off the edge.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.100',
    date: 'October 9, 2026',
    title: 'Who is on each room, and zooming tabs',
    changes: [
      'Project: each room on the Rooms list shows who is on it, as their picture with a small badge - editing it now, working on it (a lock when it is locked for you), ready to approve, or approved and ready to order - with the words beside it. The room menu in the title bar shows the same pictures.',
      'Rooms: the review marks are now called Ready to approve and Approved - ready to order.',
      'Tabs: changing tabs zooms - the new page grows in over the old one, which grows on and fades away.',
      'Tabs: the Schema editor stays ready once visited too, and measures the new template if the template setting was changed while you were away from it.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.99',
    date: 'October 9, 2026',
    title: 'Raw JSON and the catalog stay ready too',
    changes: [
      'Tabs: Raw JSON and the device catalog now stay ready once visited. Anything typed in Raw JSON is still applied the moment you switch tabs, and catalog edits still reach the rest of the app straight away. The catalog stays ready when another room is opened.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.98',
    date: 'October 9, 2026',
    title: 'Wizard, Devices and System stay ready too',
    changes: [
      'Tabs: the Wizard, Devices and System pages now stay ready once visited, like the drawing and cost pages. If the room was changed on another tab while you were away from one, it is rebuilt when you come back, so its fields always show the room as it is.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.97',
    date: 'October 9, 2026',
    title: 'Faster tab switching, and quiet while away',
    changes: [
      'Tabs: the AV Flow, Floor Plan, Cabling, Racks, Schematic, Cost, Lifecycle and Project pages stay ready once visited, so going back to one is instant and keeps its scroll and selection. They are rebuilt fresh when another room is opened.',
      'Tabs: each page fades in as it is shown.',
      'While the PC is locked or the window is minimized, the app stops checking the shared folder for chat, "working on" tags and other people\'s saves, and stops all animations. It still shows as open to colleagues, and catches up the moment you are back.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.96',
    date: 'October 9, 2026',
    title: 'Room locks, reviews, and choosing what to combine',
    changes: [
      'Rooms: while someone else is tagged as working on a room, it is locked - Save asks whether to take them off the room first, and saves only once they are off. Tag yourself on the room to save alongside them.',
      'Rooms: mark a room Ready for review, then Review complete once it has been checked, from the review button beside "working on" in the title bar or on the room\'s row on the Project page. Marking it ready again starts a new review.',
      'Rooms: the room menu in the title bar and the Rooms list on the Project page show an icon for someone working on a room (a lock when it is locked for you), ready for review, and review complete. Hover an icon for who and when.',
      'Combining saves: each change from the other person\'s save has its own box. Untick any you do not want - your copy keeps what it had there. Approve all and Approve none tick or clear the lot.',
      'History: a new Combines tab lists every combine per room, per project or per campus, with the time, who combined whose save, and each line approved or left out when expanded. A copy of the file is kept, timestamped, before each combine.',
      'History: the combine log is saved with a backup and timestamped copies. The Combines tab says whether the backup matches the log, and Combine them merges the two when they differ.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.95',
    date: 'October 9, 2026',
    title: 'Add-on counts per room, and a tidier funding card',
    changes: [
      'Cost: a priority add-on, like a projector mount, takes the quantity set on a room\'s Cost tab - the plus or a number typed in the box - so a room with two projectors can buy two mounts. Clear the box to go back to the priority\'s count. The project total follows.',
      'Project: on Priorities and funding, the budget figures and each priority\'s rooms fold away, and the rooms sort by name, budget or room total. Each room shows its total beside its budget, red when it comes to more, and each priority shows the rooms\' total under its budget. A room\'s name opens it on its Cost tab.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.94',
    date: 'October 9, 2026',
    title: 'Project note readable in every theme',
    changes: [
      'Cost: the project note at the top of a room\'s Cost tab has its colors measured against the theme in use, so its text and buttons read in Classic and Auris, light and dark, whatever accent is picked. Purchased - quote the whole room is a solid button that stands out from the note.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.93',
    date: 'October 9, 2026',
    title: 'Easier to read project note',
    changes: [
      'Cost: the buttons on the project note at the top of a room\'s Cost tab - Show the whole room, and Purchased - quote the whole room - are drawn in the note\'s own dark ink, so they read clearly against it.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.92',
    date: 'October 9, 2026',
    title: 'Rooms priced the way the project buys them',
    changes: [
      'Cost: a room opened from a project whose priority buys only part of a room - "Replaces only Projector" - is priced the way the project buys it, with a note saying so and how many lines are left off as existing. Show the whole room switches to everything in the room and back.',
      'Cost and projects: Purchased - quote the whole room breaks a room off from its priority, so a requote prices the complete room rather than only the projector it already has. Back to what the priority buys puts it back. The project\'s quote follows it too.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.91',
    date: 'October 9, 2026',
    title: 'Room to work on the floor plan',
    changes: [
      'Floor plan: zooms out as far as it takes to see a large sheet whole - the old limit stopped short once the sheet filled the window.',
      'Floor plan: each group of the toolbar folds away to its name, and the button by the Floor Plan title folds the whole toolbar, for room to work on the sheet.',
      'Floor plan: a screen or display\'s color now colors its working area, and Throws and angles sets a color for each of its contrast ranges (7:1, 15:1, 50:1, 80:1).',
      'Floor plan: a screen or display\'s Reach sets how far back its working area is drawn. Six image heights is where it starts.',
      'Floor plan: clicking a slider\'s number opens it as shown - 12\' 5" rather than 12.42 - and leaving it unchanged changes nothing.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.90',
    date: 'October 9, 2026',
    title: 'Room light that adds up',
    changes: [
      'Floor plan and projection calculator: room light on a screen is now worked out from how much light the screen sends back, not its gain. A gain screen used to bounce back more room light as well as more picture, so it never helped and its working area was always narrower. Now a higher-gain screen holds contrast better straight on, as it does in a real room.',
      'Floor plan: a screen or display\'s working area shows a band for each content type it reaches - passive viewing, basic decisions, analytical decisions, full-motion video - so more room light narrows it a step at a time instead of it vanishing. Green is the content you picked and above, amber is what it falls back to.',
      'Floor plan: when a screen is too dim for the content, it says what contrast it does reach straight on, and draws how far the next one down still works.',
      'Projection calculator: starts from the room light set on the floor plan, and names the content type the contrast is good for.',
      'Catalog: 82 classroom projectors added from projectorcentral.com - every Sharp/NEC, Panasonic, Epson and Sony classroom model still in production that the catalog did not have, and other makers\' classroom models released in 2026 - with list price, brightness, throw, lens shift, power and connectors.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.89',
    date: 'October 8, 2026',
    title: 'Throws matched to the screen',
    changes: [
      'Floor plan: a projector and its screen stay matched to one image. A longer or shorter reach, or a wider or narrower throw, resizes the screen to the image it lands, and the screen\'s brightness and viewing distance follow. A screen made wider zooms its projector to fill it.',
      'Floor plan: the end of a projector\'s throw draws the image, labeled with its width, diagonal, throw ratio and brightness. It turns red when the lens can\'t zoom that far.',
      'Floor plan: Throw to screen sets a projector\'s reach to its screen and zooms it to fill the screen.',
      'Floor plan: click any number beside a slider - facing, angle, reach, width, line weight, and the calculator\'s zoom - to type it in. Lengths take feet and inches (12\' 6", 12 6 or 150"), and a typed reach or width can go past the slider\'s end.',
      'Floor plan: each throw, cone and viewing angle can have its own color - click the dot beside it in the device bar - and the key shows it. Throws and angles lists every one on the sheet to show, hide or recolor each, or all at once.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.88',
    date: 'October 8, 2026',
    title: 'Projector specs in the catalog',
    changes: [
      'Catalog: projectors keep their resolution, aspect, contrast, light source and life, zoom, lens shift, weight and noise, from projectorcentral.com, and the Device Editor shows them. Picking a projector in the projection calculator fills in its lens shift.',
      'Catalog: 209 projectors filled in from projectorcentral.com, with the power draw of 90 that had none.',
      'Sequential names start at 1 with the first unit of a series, and devices added on the AV Flow carry on the numbering of those already in the room instead of starting again.',
      'Numbers already on units are kept - "Screen 4" and "Screen 5" stay 4 and 5 rather than turning into a second Screen 1 and 2 - and a new unit goes on the end. Taking the other of a pair off leaves the one left without a lone "1".',
      'Floor plan: while Measure or Set scale is on, clicks only measure - devices, places and labels on the sheet can\'t be picked up by accident.',
      'Floor plan: a Viewing angles switch hides or shows the cones, throws and viewing angles on screen. The export still offers a copy with or without them.',
      'Cost: the equipment table is sorted by manufacturer unless a room picks another order.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.87',
    date: 'October 8, 2026',
    title: 'Units numbered in sequence',
    changes: [
      'Cost: raising the quantity of a device on the AV Flow adds the extra units to the AV Flow, named on in sequence - 12 "Network PDU TV" and one more gives "Network PDU TV 13" - so each one can be placed on the floor plan and the racks. One fewer takes the highest-numbered unit off when nothing is cabled to it; otherwise only the quote\'s count comes down.',
      'Cost: several units on one line are named in sequence after the line\'s name, or after the name they share - "Computer Monitor 1", "Computer Monitor 2". A unit given a name of its own keeps it.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.86',
    date: 'October 8, 2026',
    title: 'Model search waits for a pick',
    changes: [
      'Devices page: the Model box works like the Python Module box - typing only searches the list, and the model applies when one is picked (Enter picks the top match) or when you leave the box. Before, a pause in typing saved it and threw the cursor out of the box.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.85',
    date: 'October 8, 2026',
    title: 'Module search waits for a pick',
    changes: [
      'Emoji picker: the emoji under the mouse moves - in the full list and in search results - and is shown large with its name at the bottom of the picker, so you can see how it will look before picking it.',
      'Team chat, with the style codes hidden (the eye): Backspace and Delete step over the hidden codes and take the letters you can see, and erasing a styled word takes its codes with it - no more half codes left behind.',
      'Devices page: typing in the Python Module box only searches the list. A module applies when one is picked from the list or Browse (Enter picks the top match), or - for a name typed by hand - when you leave the box. Applying a module reads its .py file and defaults, which was too much to do on every letter.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.84',
    date: 'October 8, 2026',
    title: 'Typing a model no longer lags',
    changes: [
      'Devices page: the Model, Module and Input boxes write what is typed once typing pauses, instead of on every key - a model is looked up in the catalog and carried to the AV Flow, the floor plans and the estimate, so typing or erasing one lagged badly. Picking from the list still applies at once.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.83',
    date: 'October 8, 2026',
    title: 'The project chat joins the team chat',
    changes: [
      'Smoother editing: the words boxes of the config form (names, labels, notes) are written when typing pauses, or on clicking away, instead of on every letter - each letter used to redraw the whole app.',
      'Estimate: the equipment rows stay where they are while a device is renamed. They are put in order again when you come back to the page, or pick from the Sort menu.',
      'Editing together: "saved changes to this room" (and its merge button) only comes up when their save holds something your copy does not have.',
      'The project chat is now the project\'s thread in the team chat - the same chat as the CTS Dashboard and Instructor Contact, saved in the team folder, so it can be read and answered from any of them. There is one chat button now, the team chat\'s: its sidebar lists every project\'s thread under Projects, and a button at the top of the chat goes to the project open here.',
      'A project\'s older chat (its <project>_chat folder beside the project file) and the old Everyone chat are copied in the first time they are opened here, under the people who wrote them. The old folders are left as they were.',
      'Search every project (the magnifier in the top right) lists every project on the share, each with a Chat button for its thread, and searches what was said in the project threads.',
      'Settings > Working together has a switch for the team features - off for a copy used on its own, away from the file share: no chat, no project threads, nothing written to the share.',
      'Renaming a device in the config form no longer lags: the name is written when typing pauses (or on clicking away) instead of on every letter, which redrew the AV Flow, the floor plans and the estimate each time.',
      'Text effects: pick a different effect for the next word and each word keeps its own; the preview plays both, and half-deleted codes no longer show in it.',
      'The team page is as wide as the window allows, so every app\'s full name fits.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.82',
    date: 'October 8, 2026',
    title: 'Team chat fits the window; every emoji; #word threads',
    changes: [
      'Emoji: the picker has every emoji (about 1,500), with a search box - type part of a name ("thumbs", "flamingo") and Enter picks the first one found. The common ones stay at the top.',
      'Start a thread by typing #word at the start of a message: "#lunch anyone?" posts "anyone?" in #lunch, starting it if it is new, and every CTS app sees it. The box says where the message will go before you send.',
      'With the codes hidden (the eye on the formatting bar), a message with a text effect is shown above the box as it will look, the effect playing.',
      'A long phrase with a text effect wraps instead of running off the side of the chat.',
      'The floating team chat shrinks to fit a smaller window and stays wholly on screen. It goes back to the size you left it when the window grows.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.81',
    date: 'October 8, 2026',
    title: 'Floor plans keep everything in reach; an All CTS apps chat',
    changes: [
      'Floor Plan: adding a drawing to a sheet that already has devices, '
          'markers or notes on it enlarges the drawing (keeping its shape) '
          'until it covers all of them, so nothing ends up past the edge '
          'where it cannot be reached.',
      'A sheet with things past the edge of its drawing says so, with an '
          'Enlarge to fit button. Floor plan settings has a Drawing size: '
          '- 10%, + 10% and Enlarge to fit everything. A calibrated scale '
          'follows the drawing.',
      'Team chat: a new "All CTS apps" conversation, seen in every app, sits first in the list. Under it is this app\'s own conversation (the dashboard\'s "Everyone" is now "CTS Dashboard", with all its history), and the other apps\' conversations can be opened from the list too.',
      "Who is online shows the version of the app each person has open, on the team chart and in the chat's Online now list.",
      'Animated emoji come from the team folder on the share (the whole set is kept there), then this PC, and the internet only when the share cannot be reached or the app runs on its own.',
      'Floor Plan: the device, screen, projector, camera and settings boxes can be dragged out of the way of the sheet. So can the projection calculator, color pickers and cable colors.',
      'Projection calculator: a picture of the throw from the side at an angle - the projector, its throw distance, and the screen with its width, height, diagonal and how far the bottom of the image is above or below the lens. Drag the projector closer or farther and the image grows or shrinks with it. Outlines mark the zoom\'s telephoto and wide ends. Drawn for light and dark mode.',
      'Projection calculator: a Units button (as on ProjectorCentral): throw distance and image size each in feet, inches, centimeters or meters, and brightness in foot-lamberts or nits. The boxes, results, tables and picture all follow, and the choice is kept for the next calculator until the app is closed.',
      'Projection calculator: a brightness gauge with what kind of room the image suits, and how far the lens shift can move the image up, down and to the sides.',
      'Devices on the floor plan are tied to their box on the AV Flow, not to the name on the estimate. Renaming a device or swapping its model no longer frees it to be placed again; each unit is placed once, under its own name, and the name follows it everywhere. Devices placed before this are tied up the first time the room opens.',
      'Renaming a device on the floor plan renames it on the AV Flow, the config and the estimate.',
      'Floor Plan: a projector or screen box has the pairing menu too, to choose which projector goes with which screen.',
      'Cost: the name on a line of one device renames that device everywhere. A line of several has a dropdown of each one\'s name and an Edit names box.',
      'Catalog: displays have a viewing angle and cameras a field of view. A display, camera or projector placed on the floor plan starts with its cone from the catalog (a projector\'s from its throw ratio, reaching the room\'s throw distance), and the device box has a Catalog button to put it back.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.80',
    date: 'October 7, 2026',
    title: 'Team chat effects, moving emoji and a who-is-where chart',
    changes: [
      'Team chat style buttons switch: pressing a style that is on takes it off, and a new colour, font, size or effect replaces the old one - switching styles no longer leaves underline or strikethrough lines behind.',
      'Effects (the sparkle button on the formatting bar): Big, Small, Shake, Nod, Ripple, Bloom, Jitter and Explode, like an iPhone. They play when the message appears; click the words to play them again.',
      "Emoji move, like in Teams (Google's animated Noto Emoji, kept on this PC after the first time); a message of only emoji shows them large. Both can be switched off in the Effects menu.",
      'Who is online: each app has its own colour (Dashboard blue, Room Config Builder purple, Instructor Contact teal) in light and dark mode. The team page is a chart - a row per person, a column per app, with the page and room in each. In the chat, someone with several apps open is one row with a dropdown of their apps.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.79',
    date: 'October 7, 2026',
    title: 'Team chat with the CTS Dashboard, and shared room edits',
    changes: [
      'The team chat from the CTS Dashboard is here too (the speech bubble '
          'with people beside the project chat): direct messages, groups, '
          'room threads, topics, formatting, pictures and GIFs. It is the '
          'same chat as the dashboard and Instructor Contact, and each '
          'message says which app it came from.',
      'Who is online shows everyone in any CTS app, which app, and the room '
          'they are looking at.',
      'The open room has a "working on" button in the title bar: tag '
          'yourself or a colleague (they get a message). The CTS Dashboard '
          'shows the same tag on the room.',
      'Settings: Team Folder (blank uses the dashboard\'s), and Shared Rooms '
          'Folder - Save Room As starts there, and each save leaves a copy '
          'of the room there (switch it off below).',
    ],
  ),
  ChangelogEntry(
    version: '0.5.78',
    date: 'October 7, 2026',
    title: 'Descriptions in Check Defaults',
    changes: [
      'Check Defaults shows an (i) next to each key it can add back; hover '
          'it to see what the key is for.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.77',
    date: 'October 7, 2026',
    title: 'Device names on the AV Flow, and saved rooms open as saved',
    changes: [
      'A device\'s box on the AV Flow is titled with the device\'s name from '
          'its config, including in rooms saved with an older title. '
          'Renaming the box on the AV Flow renames the device too.',
      'A room the app has saved opens exactly as saved: no fields such as '
          'keep_alive_qualifier are added back. Press Convert to run the '
          'conversion on it again.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.76',
    date: 'October 6, 2026',
    title: 'GIF search works out of the box',
    changes: [
      'GIF search in the chat now uses KLIPY, with a key built into the app, '
          'so it works with nothing to set up. A key of your own can still '
          'be set under Application Configuration > Working together.',
      'With no GIF key at all, the GIF button takes a link to a GIF and '
          'sends that.',
      'The log now notes when the screen stops drawing and when it comes '
          'back, very slow frames, the window being hidden or moved to '
          'another screen, and the key pressed just before the window '
          'closed - to help track down freezes and black screens.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.75',
    date: 'October 6, 2026',
    title: 'Room quantities from the Sheet, and a better chat',
    changes: [
      'A projection screen on the signal flow gets its motor control wired '
          'automatically: to a screen controller, a relay on the control '
          'processor, or a wall switch placed beside it - whichever is free '
          'first. The order, and which of the three are allowed, are set on '
          'the Flow Rules tab under Projection screens.',
      'In the published workbook and Google Sheet, every other figure follows '
          'a room tab\'s Qty: the line\'s Extended and the room totals, All '
          'Items, Parts by Room and Core Components all read it.',
      'Pull brings room quantities back: change a Qty on a room\'s tab, set '
          'it to 0 or delete the row, and the room\'s estimate follows. A '
          'line added by hand changes or comes off; a device counted off the '
          'drawing takes the typed count, staying on the drawing at 0. Other '
          'edits on a room\'s tab are still listed in the history file.',
      'The Keyboard shortcuts section is one line per shortcut with its keys '
          'drawn as keycaps, and opens without the stutter.',
      'Chat: the search is a button that opens a bar over the conversation, '
          'filtering it and marking what matched, with All chats beside it '
          'for every project. The chat is laid out more cleanly, with the '
          'window choices in one Layout menu and messages from one person '
          'grouped.',
      'Chat messages can be edited after posting, and say (edited) for '
          'everybody once they have been.',
      'Emoji reactions on chat messages: point at a message for quick ones '
          'or the full set, and click a reaction to add or take back yours.',
      'Pictures and GIFs in the chat. Paste a screenshot straight into the '
          'message box with Ctrl+V, add a picture from a file, or search '
          'GIFs online and pick one to send. GIF search needs a Tenor key, '
          'set under Application Configuration > Working together.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.74',
    date: 'October 6, 2026',
    title: 'Keyboard shortcuts and a throw diagram',
    changes: [
      'The projection calculator draws its answer like Projector Central '
          'does: a side view with the screen, the projector, the beam, the '
          'zoom range and where lens shift lets the lens sit, and a top view. '
          'The ceiling height is a new field.',
      'The calculator\'s screen size can be typed in feet as well as inches.',
      'Typing in the Catalog search no longer stutters: the list catches up '
          'when you pause.',
      'Boxes on the cabling drawing grow to show all of their text. Select '
          'one and drag its corner to resize it; right-click and Fit to text '
          'sizes it to the text again.',
      'Keyboard shortcuts for what is selected on a drawing: Delete removes '
          'it and the arrows move it (Shift for a bigger step) on the floor '
          'plan, the signal flow in Edit mode, the cabling drawing and a '
          'picked-up rack device, which moves a U at a time. Esc lets go.',
      'A selected projector, camera, display or screen on the floor plan '
          'turns with [ and ], widens and narrows its cone with . and , , '
          'reaches further or less with = and -, and shows or hides the cone '
          'with V.',
      'Keyboard shortcuts in Application Configuration lists every shortcut '
          'and what it does, and any of them can be changed: click the keys '
          'and press new ones.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.73',
    date: 'October 6, 2026',
    title: 'Extron prices updated',
    changes: [
      'The shared catalog has Extron\'s current list and education prices '
          'for 339 products, read off extron.com. Most went up about 10 '
          'percent; 32 products gained an education price they did not '
          'have, and two list prices that were typed wrong are corrected.',
      '206 Extron products that Extron has retired are now marked retired, '
          'so they drop out of the pickers. Rooms that already use them keep '
          'their prices and connectors.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.72',
    date: 'October 6, 2026',
    title: 'Where screens and displays work',
    changes: [
      'Every projector and lens in the catalog has a Calculator button that '
          'opens the projection calculator with its throw ratio and lumens. '
          'A projector sold without a lens is offered the same maker\'s '
          'lenses.',
      'Displays in the catalog have a Brightness field in nits.',
      'Room light on the Floor Plan toolbar: how much light lands on the '
          'screens and what the content needs, from passive viewing to '
          'full-motion video. Screens and displays then show where the '
          'picture holds that contrast, out to six image heights, or say '
          'when it is too dim.',
      'Displays on a floor plan are drawn as wide as the panel, sized from '
          'the model on a scaled sheet, with the viewing area flaring from '
          'their edges like a screen. The calculator also sets a screen\'s '
          'gain and width.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.71',
    date: 'October 6, 2026',
    title: 'Projector specs and catalog filters',
    changes: [
      'The catalog has throw ratios and lumens for most projectors, from '
          'projectorcentral.com, so the projection calculator fills itself '
          'in. Models sold without a lens take the throw from the lens on '
          'the estimate.',
      'Hide warranties on the Catalog tab hides warranty extensions and '
          'service plans.',
      'US models only on the Catalog tab hides models made for other '
          'markets: UK, EU and other plug and plate versions, Epson EB- and '
          'CB- projectors, and Panasonic projectors for China, Europe and '
          'Asia. Both switches are remembered.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.70',
    date: 'October 5, 2026',
    title: 'Projection calculator and measuring',
    changes: [
      'The Floor Plan toolbar is grouped: the sheet and its look on the '
          'first line, with the exports at the right; the drawing tools, the '
          'lists and the measuring tools on the second. Sheet, label and '
          'cable colors share one Colors menu.',
      'Projection calculator: throw distance from the screen size, or the '
          'image size from the distance, with brightness in foot-lamberts '
          'and nits, contrast in room light, lens shift and mounting height, '
          'brightness over distance and how it falls off to the side.',
      'The calculator takes the throw ratio and lumens off the catalog. '
          'Projectors and lenses have Throw ratio and Brightness fields in '
          'the Device Editor, and fall back to what their notes say; a lens '
          'on the estimate is offered for the projector beside it.',
      'Each room has a throw distance: set it with Throw distance on the '
          'Floor Plan toolbar, or save it from the calculator. The calculator '
          'starts from it.',
      'Projection screens on a floor plan are drawn as wide as the screen, '
          'and can show a viewing area that flares out from both edges, '
          'shaded brighter toward the middle.',
      'A projector\'s throw is shaded by distance; on a scaled sheet it '
          'carries rings giving the distance and how bright the image would '
          'be there.',
      'Select a projector or screen to see how far the projector sits off '
          'the screen\'s center line. Square to screen moves and turns the '
          'projector onto it, Aim at screen just turns it, and Square to '
          'projector turns the screen.',
      'Measure on the Floor Plan toolbar, once the sheet has a scale: click '
          'two points to get the length in feet and inches.',
      'Export PNG can leave the viewing angles, throws and their labels off '
          'the picture.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.69',
    date: 'October 5, 2026',
    title: 'Live device edits and Set scale',
    changes: [
      'Selecting a device on a floor plan puts sliders for its direction, '
          'cone angle and reach above the sheet, and the cone moves as you '
          'drag. The edit dialog shows its changes on the sheet as you make '
          'them too, and Cancel puts them back.',
      'Set scale on the Floor Plan toolbar: click both ends of something '
          'whose length you know, type its length in feet and inches, and '
          'the sheet is scaled from it. The button then shows the scale.',
      'The Floor Plan toolbar is laid out in two lines: the sheet\'s own '
          'settings first, starting with Plan settings, then the drawing '
          'tools, with the exports at the right.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.68',
    date: 'October 5, 2026',
    title: 'Devices on floor plans and cabling',
    changes: [
      'Floor plans have an Add device menu listing the equipment on the '
          'room\'s estimate, A to Z and each name once. Pick one and click '
          'the sheet to place its icon; a sheet takes as many of each as the '
          'estimate buys, and raising the quantity there makes room for more.',
      'Projectors, cameras and displays on a floor plan can be turned to '
          'face the way they point, and can show a field of view, throw or '
          'viewing angle cone with its own width and reach.',
      'The Device button on the Cabling tab offers the same estimate list '
          'with the same limits, and a projector or camera box can be turned. '
          'Other device still picks any icon.',
      'Duplicating a floor plan sheet now keeps its paper color.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.67',
    date: 'October 5, 2026',
    title: 'Animated menu button',
    changes: [
      'The menu button at the top left turns into an X while the menu is '
          'open, and back when it closes.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.66',
    date: 'October 5, 2026',
    title: 'Driver logins filled in',
    changes: [
      'The driver defaults review now ticks the driver\'s username and '
          'password when the device has none, so a Kramer VIA GO picks up its '
          'default login. A login already set is still left alone.',
      'Moving a device into another family now keeps its username along with '
          'its address and password.',
      'In the menu under your picture, the light and dark mode switch now sits '
          'with Your profile, and Application Configuration sits above Help.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.65',
    date: 'October 5, 2026',
    title: 'Room on the top bar',
    changes: [
      'When the top bar fills up, colleagues who have the file open show as '
          'just their picture. Hover over one to see their name, which room '
          'they are in and whether they have unsaved changes.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.64',
    date: 'October 5, 2026',
    title: 'Quieter about the catalog',
    changes: [
      'Starting the app no longer says a colleague has the catalog open just '
          'because they have the app running. It speaks up when they are '
          'actually editing it.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.63',
    date: 'October 5, 2026',
    title: 'Where it stands, wider and optional',
    changes: [
      'The "where it stands" pop-up when a project opens can be turned off: '
          'untick "Show when a project opens" on it, or use the switch in App '
          'Config. The button on the Project tab still shows it any time.',
      'On a wide screen "where it stands" is wider, with the details beside '
          'the overview, so more of it fits without scrolling. Narrow screens '
          'keep the tall single column.',
      'The scroll bar in "where it stands" no longer covers the text.',
      'Closing a room while a project is open takes you back to the Project '
          'tab.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.62',
    date: 'October 5, 2026',
    title: 'Rooms no longer open as changed',
    changes: [
      'Opening a room no longer marks it as changed when you have not '
          'touched it. Leads and boxes the config calls for are still drawn '
          'in on open, and are saved with your next save.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.61',
    date: 'October 4, 2026',
    title: 'Chat and room type fixes, and the Auris look',
    changes: [
      'Opening another project while the chat was checking for messages '
          'could skip loading that project\'s chat, then pop up every old '
          'message as new. New messages in Everyone could also go missing at '
          'that moment. Both are fixed.',
      'In the separate chat window, accented letters and symbols no longer '
          'turn into garbage characters now and then.',
      'A chat message that could not be sent is put back in the box instead '
          'of being lost.',
      'The chat stays where you scrolled to while you read back; it only '
          'jumps to the bottom for a new message or another channel.',
      'The chat does less work while it is closed.',
      'Hyflex room type: the matrix and the DSP are joined on their DMP '
          'expansion sockets (the lead used to land on the DSP\'s audio '
          'output), and the power controller has all eight outlets, so the '
          'doc cam and USB switch get their power leads.',
      'Active learning room type: the ceiling speakers are driven by the '
          'matrix\'s 70V amplifier rather than straight off a DSP line '
          'output.',
      'Room types already saved in a shared folder keep their old wiring; '
          'delete the Hyflex and Active learning files there to get the fixed '
          'ones.',
      'In the Auris style, dialogs, menus, tooltips and messages lift off '
          'the page with a soft glow in dark mode and a soft shadow in light.',
      'When the device info editor cannot write a driver because its '
          'folder is read-only, it says so and how to fix it.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.60',
    date: 'October 4, 2026',
    title: 'A cleaner look and smoother motion',
    changes: [
      'In the Classic style, cards are flat with a thin outline, dialogs and '
          'menus have rounder corners, tooltips are easier to read and '
          'messages along the bottom float above the page.',
      'Switching tabs fades the new page in, and the highlight in the side '
          'menu glides to the tab you picked.',
      'Changing the theme settings is quicker.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.59',
    date: 'October 3, 2026',
    title: 'A New File button in the side menu',
    changes: [
      'While no room is open, the side menu starts with New File - the page '
          'for a new file, a new project or a campus. It folds away when a '
          'room is opened, as the room tabs drop in.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.58',
    date: 'October 3, 2026',
    title: 'Tabs in the built-in browser; the chat docks at the top or bottom',
    changes: [
      'The built-in browser has tabs: a link opened while it is up becomes a '
          'new tab, + opens an empty one (type an address or something to '
          'search for), and each tab closes on its own. Tabs not in front '
          'keep their pages.',
      'A docked browser takes its share of the window and the rest of the '
          'app makes room for it, so scroll bars reach their last rows.',
      'The chat can be docked across the top or the bottom of the window '
          'too - the buttons in its title bar, or App Config > Working '
          'together. Drag its inner edge to make it taller; the page makes '
          'room for it.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.57',
    date: 'October 3, 2026',
    title: 'The built-in browser docks where it should; a clearer deployment '
        'target',
    changes: [
      'The built-in browser sits in the same layer as dialogs and menus, so '
          'its "where this window sits" menu opens by its button, docking to '
          'a side works at any interface size, and a docked browser is made '
          'larger by dragging its inner edge. A resize shows an outline and '
          'is applied when the mouse is let go, which takes away the lag.',
      'File > Deployment target: the X that clears the target is inside the '
          'search field, where it reads as clearing the field rather than '
          'closing the window.',

      'The side menu: Cost, Lifecycle, Wizard, Devices, System, Raw JSON, '
          'Schematic, AV Flow, Floor Plan, Cabling and Racks stay folded away '
          'until a room is open or a new one started, then drop in one after '
          'another.',
      'Combining the changes a colleague saved always shows first what will '
          'be added - each change, where it is and what it was - and waits '
          'for you to confirm. Places you both changed are still asked about '
          'after.',
      'Somebody else editing is shown by their picture at the top - dimmed '
          'while they are only looking - with the Combine button beside it. '
          'The message that they opened the file shows once, and a waiting '
          'save is announced once rather than at every autosave.',
      'Chat: delete your own messages (the bin by the time), add a picture '
          'with the picture button by Send - click it to see it full size - '
          'and each message shows the picture of whoever wrote it beside '
          'the name.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.56',
    date: 'October 3, 2026',
    title: 'An Everyone chat; search every chat and project; a wider chat; '
        'older rooms show their data again',
    changes: [
      'An Everyone channel for anybody who uses the app, kept in the chat '
          'folder in the Root Folder on the share. It is there with or without '
          'a project open; @ names anybody who has opened the app.',
      'Search every chat and every project: the search button on the title '
          'bar, or in the chat. Projects are found by name anywhere under the '
          'Root Folder, messages by what was said, who said it or the room. '
          'Clicking one opens it - the project first when it is not open.',
      'The chat slide-out is made wider by dragging its left edge. Its fill '
          'the screen button puts the chat in one half and the search in the '
          'other.',
      'Rooms whose files were named for config.json by an older version '
          '(config_cost.json and the rest, beside config.json or in a config '
          'folder) show their data again, and are moved into room_files '
          'under the name of the room when opened.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.55',
    date: 'October 3, 2026',
    title: 'Export by Convert; the chat on the title bar only; your logo kept '
        'on the share; a roomier profile',
    changes: [
      'Export has moved down a row, beside Convert. The chat opens from its '
          'button on the title bar; the button that floated in the lower '
          'left is gone (notices of new messages still show there).',
      'The chat opens as a slide-out unless App Config > Working together '
          'says otherwise. Moving it from its own title bar lasts until the '
          'app is closed; turn on "Remember the last way it was opened" to '
          'keep it.',
      'The estimate logo chosen in Your profile is copied to the shared '
          'folder beside the avatars (assets\\logos, under your login), with '
          'a copy kept on this computer, so an estimate always has its logo '
          'even when the file it was picked from moves or the share is out '
          'of reach.',
      'Your profile is wider, so the scroll bar no longer sits on the '
          'Estimate PDF settings, and has a button by its title to make it '
          'fill the window.',

    ],
  ),
  ChangelogEntry(
    version: '0.5.54',
    date: 'October 3, 2026',
    title: 'Smoother dragging of the browser and the chat',
    changes: [
      'Dragging the built-in browser window or the floating chat panel '
          'now follows the pointer smoothly: the window is moved as it '
          'stands instead of being redrawn on every movement, and it '
          'starts moving the moment the button goes down.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.53',
    date: 'October 3, 2026',
    title: 'Project chat; a fuller history; Google sign-in with no setup; '
        'the toolbar rearranged; smoother typing',
    changes: [
      'Project chat: a conversation kept with the job, in a '
          '"<project>_chat" folder beside the project file, so everybody who '
          'opens it sees the same thing - no server needed. General, a '
          'channel per room, and one per tab people talk about. Open it from '
          'the chat button in the top right or the hover button in the lower '
          'left, as a slide-out, a floating panel you can drag, or a window '
          'of its own; the buttons in its title bar move it between the '
          'three.',
      'Type @ in the chat to name anybody who has opened the job or is in '
          'its history. A message that names you is drawn bold in the '
          'warning color, and the chat icon turns into a red @ until you '
          'read it. Other new messages show a count, and a notice in the '
          'lower left. A question, or a message naming you, opens the chat '
          'by itself (App Config > Working together turns that off).',
      'History: every change now records the name, email and computer '
          'beside the Windows login, and the room and tab it was made on. '
          'Rows read "Name (login)"; click one for everything recorded about '
          'it. The history can be searched and narrowed to one person, and '
          'a new People tab lists everybody who has opened the job, with '
          'when they first and last did and how many changes are theirs.',
      'The toolbar: the screenshot, Export and the chat are in the top '
          'right. Light/dark and Help are in the menu under your picture.',
      'Google sign-in with no setup: App Config > Working together has a '
          'Sign in with Google button that covers both the workbook upload '
          'and the live Google Sheet. The OAuth client is built into the app '
          '(GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in secrets.json), so '
          'nobody needs a JSON file. Your own client still works, under '
          'Advanced.',
      'Smoother typing in a room: the unsaved dot on Save is checked a '
          'quarter of a second after the keys pause instead of on every '
          'keystroke, and the check for who else has a file open no longer '
          'reads the file share on the screen\'s own thread.',
      'Who else is editing shows up within a few seconds: your copy tells '
          'the others as soon as you change something, and checks for them '
          'every two seconds instead of five.',
      'The live Google Sheet is no longer cleared and rewritten on each '
          'publish: only the cells that changed are written, so the Sheet\'s '
          'own version history shows what actually changed.',
      'Pull updates shows the whole picture first: every change that will '
          'be merged into the job, and every edit that will be dropped - '
          'typed in a tab the app cannot read back, or a cell it could not '
          'read - each listed in full.',
      'A built-in browser: Google Sheets open in a floating window inside '
          'the app that can be dragged, resized or made to fill the screen. '
          'App Config > Working together turns it off.',
      'Updates are one click: the notice offers Close and Update, which '
          'installs straight away - no second Update to press.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.52',
    date: 'October 2, 2026',
    title: 'Room files named for the room; best match first in building '
        'search; the Excel workbook checked tab by tab; avatars show at once',
    changes: [
      'A room loaded from the processor layout - rooms\\SCI248\\code\\'
          'upload_to_root\\config.json - names its AV flow, cabling, cost, '
          'floor plan, history and racks files for the room '
          '(SCI248_cost.json), not for the folder (upload_to_root_cost.json). '
          'Files already named for upload_to_root are renamed when the room '
          'is opened. config.json keeps its name. Recent files, project '
          'pricing and the campus view show the room\'s name too.',
      'Building and room searches put the building whose code was typed '
          'first: "SCI" lists Science before Behavioral and Social Science. '
          'Then codes and rooms that start with what was typed, then names '
          'with a word that does, each alphabetical.',
      'The workbook in the synced folder is now compared with what was last '
          'published on every tab and every cell, the same as the live '
          'Google Sheet. Edits to a room\'s tab are listed before a save or a '
          'publish writes over them, and kept in the history file. Formula '
          'cells are compared as formulas, so a total that moved because a '
          'quantity changed is not listed as an edit of its own; a formula '
          'typed over with a figure is.',
      'Avatars are drawn from a copy on this computer, so they show as soon '
          'as the app opens. The copy is checked against the file share in '
          'the background and replaced when the share\'s picture changes, or '
          'removed when it is taken off the share.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.51',
    date: 'October 2, 2026',
    title: 'Nothing typed in the Google Sheet is written over unseen; '
        'updates are noticed while you work',
    changes: [
      'Every tab of a project\'s live Google Sheet is now compared with '
          'what was last published, cell by cell - not only Core Components, '
          'Deliveries and Purchase Orders. A row changed in a room\'s tab '
          'used to be found by no pull and written over by the next save.',
      'Those edits are listed with the rest whenever you pull, and before '
          'every publish - on save and from the Online copy box - saying the '
          'tab, the row, the column, and what it said before and now. The '
          'app cannot bring an edit to a report tab back into the room, so '
          'they are marked to make by hand, and the whole list is kept in '
          'the project\'s .online_history.txt file before the Sheet is '
          'written over.',
      'Publish in the Online copy box now checks for edits first, the same '
          'as a save does. It used to write straight over them.',
      'Edits typed before this version\'s first publish cannot be found: '
          'the comparison starts from the next publish.',
      'A new release is offered within half an hour of landing, the same as '
          'the CTS Dashboard. The check used to wait until nothing was '
          'unsaved, which could be the rest of the session. Installing still '
          'asks about unsaved work before the app closes.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.50',
    date: 'October 2, 2026',
    title: 'Closing a project leaves the Project page; online edits are '
        'kept in a history file',
    changes: [
      'Changes brought in from a project\'s Online copy - the workbook in '
          'the synced folder or the live Google Sheet - are also listed in a '
          'history file beside the project, named after it and ending '
          '.online_history.txt: when, who, where they came from, and each '
          'change as the review showed it.',
      'Closing a project always goes to the Cost tab. With a room open that '
          'is the room\'s cost; with none it is the start screen, with the '
          'recent files. It could stay on the closed project\'s page, or go '
          'to Settings or the catalog.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.49',
    date: 'October 2, 2026',
    title: 'Publish a project to a live Google Sheet',
    changes: [
      'A project\'s Online copy can publish to one live Google Sheet as well '
          'as, or instead of, the synced folder. The Sheet is rewritten in '
          'place, its link is kept on the project so everybody publishes to '
          'the same one, and edits typed into it are pulled back the same way '
          'as from the folder.',
      'The Google client in App Config can be loaded from the JSON file '
          'Google Cloud downloads for it.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.48',
    date: 'October 2, 2026',
    title: 'Combine works again, and saves by others are flagged',
    changes: [
      'The Combine button on the top bar works again when somebody else '
          'saves a room or project you have open.',
      'A save by somebody else to the open room or project shows a badged '
          'Combine button on every tab, naming which file they saved.',
      'The Catalog tab shows a sync icon beside Reload when somebody else '
          'saves the catalog. Pressing it brings their changes in.',
      'Saving a room or a project no longer offers to open the file - it '
          'is the one already open. Open folder is still offered.',
      'Picking a room from the title bar while on the Project tab goes to '
          'that room\'s Cost tab. On any room tab, the tab stays and shows '
          'the room picked.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.47',
    date: 'October 2, 2026',
    title: 'Save a changed Cost line to the catalog',
    changes: [
      'A Cost line whose manufacturer, part number or price was changed '
          'from the catalog has a button at the right of its row that saves '
          'those changes to the catalog.',
      'Saving a project whose online copy is open or locked shows a brief '
          'notice naming the file, and the log records it. The project '
          'itself still saves.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.46',
    date: 'October 2, 2026',
    title: 'DTP power toggle buttons',
    changes: [
      'System settings have a dtp_power_toggle_1 key for the panel button '
          'that turns DTP power off and on at an IN1808 port. It is a '
          'dropdown of the ports that can do it - 7, 8 or 1B - and blank '
          'means no button.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.45',
    date: 'October 2, 2026',
    title: 'Manufacturer and part number editable on the Cost page',
    changes: [
      'The manufacturer and part number of a line on the Cost page can be '
          'edited by clicking its Model cell. An edited line leaves the '
          'catalog - a warning says so, its price is kept as a room price, '
          'and a broken-link icon marks it. It can be restored from the same '
          'box.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.44',
    date: 'October 1, 2026',
    title: 'Settings moved to the profile and the File menu',
    changes: [
      'The gear button is gone from the title bar - Application '
          'Configuration opens from the profile menu.',
      'The deployment target is on the File menu, which names the room '
          'that is set.',
      'Theme, colors, interface and text size, and the Estimate PDF settings '
          'are in your profile instead of Application Configuration.',
      'The box shown when hovering over someone editing has a solid '
          'background.',
      'Names in the +N list of editors are in normal text instead of grey.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.43',
    date: 'October 1, 2026',
    title: 'Original app icon restored',
    changes: [
      'The app icon is back to the original hard hat and gear.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.42',
    date: 'October 1, 2026',
    title: 'Calendar invites easier to find',
    changes: [
      'Every open To-do shows "Calendar invite" beside its date, on the To do '
          'list and on the timeline\'s job list - add it to your calendar or '
          'email it as an invite.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.41',
    date: 'October 1, 2026',
    title: 'Settings errors fixed, and up to five people editing at once',
    changes: [
      'Fixed: opening and shutting a Settings section, then scrolling, made '
          'the text boxes in it fail - a stream of errors, and boxes that '
          'could not be clicked or typed in.',
      'Each room on the procurement log folds to its heading, with Collapse '
          'all and Expand all.',
      'The profile holds your name, email and avatar; the theme, colors and '
          'sizes are back in App Config under Appearance.',
      'Out of the box the app works from its own folder, devices and '
          'documentation included. First-Time Setup says whether the file '
          'server can be reached, and Set to file server only works when it '
          'can.',
      'Combining saves no longer treats the defaults a room is given when it '
          'opens as somebody\'s edit, and never joins two short values such as '
          'room numbers - only notes and other text are kept side by side.',
      'History, completed and deleted notes are signed with the same name as '
          'the editing chips.',
      'With more than three people editing, the top bar shows three and a '
          '+N list of the rest. Each person\'s chip and list entry says which '
          'room they have open and which tab they are on.',
      'Long options in the System and Devices drop-downs are cut short with '
          'an ellipsis instead of running past the box.',
      'A blank av_flow_rules.json is installed with the app.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.40',
    date: 'October 1, 2026',
    title: 'Settings in sections, your profile, and deliveries on the order',
    changes: [
      'Settings are in sections that fold open and shut: deployment target, '
          'pricing, editing behavior, updates, autosave, logging, files and '
          'folders, working together, data files, shared lists and the '
          'processor connection. Logging has a section of its own.',
      'A profile button beside the gear shows your avatar, name and email, '
          'and opens your profile or Application Configuration. Your name, '
          'email, avatar, theme, colors and sizes are set in your profile.',
      'Hovering over someone who has the same file open shows their avatar '
          'large.',
      'The devices and documentation folders on the file server are the '
          'default for everybody who can reach it, whatever their Root '
          'Folder.',
      'Each purchase order on the Deliveries page folds to its heading, with '
          'Collapse all and Expand all.',
      'Logging a delivery of a part puts its PO on that part\'s order on the '
          'Equipment list, and marks it arrived once the whole quantity is in.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.39',
    date: 'October 1, 2026',
    title: 'Combining saves keeps everybody\'s work; reminders, attachments '
        'and avatars',
    changes: [
      'On the job list, Add lights up as soon as you start typing.',
      'A job note can be sent out as a calendar reminder: Add to my '
          'calendar opens it in Outlook, and Email as invite opens a new '
          'email with it attached. A note with no date asks for one.',
      'Pictures and documents can be attached to a job note. They are '
          'copied into a folder beside the project file; pictures and PDFs '
          'open in the app, anything else in its own program.',
      'Merges and saves of shared files now wait their turn instead of '
          'running together, with a Syncing chip while they work. Bringing '
          'in somebody else\'s project save no longer re-reads every room.',
      'On the Cost tab the tax name, tax rate and PDF boxes sit in one '
          'line; the rate\'s note no longer pushes its box down.',
      'Combining somebody else\'s save keeps everybody\'s new items: two '
          'notes, lines or rooms added at the same time are both kept, where '
          'one of them used to be lost.',
      'The combine window says in plain words what was changed, and keeps '
          'both versions wherever it can. Where it cannot, each one has to be '
          'chosen before Combine - nobody\'s work is thrown away by default.',
      'The history has a Finished tasks tab: every completed or deleted '
          'job-list note, grouped by who finished it, with a filter for one '
          'person.',
      'Setting a note to Waiting on asks what it is waiting for, and takes '
          'files to go with it. The reason shows on the note.',
      'The timeline lists every job-list note, dated or not, and exports as '
          'a spreadsheet, a list (copied or saved) or a picture.',
      'App Config has Your avatar: a picture shown instead of your initials '
          'when others have the same file open. It is kept in the Root '
          'Folder\'s assets\\avatars - on the file share when that is the '
          'root.',
      'The Root Folder starts with av_flow_rules.json (blank, or the one '
          'installed with the app) and the devices and documentation '
          'folders, filled from the installed copies.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.38',
    date: 'October 1, 2026',
    title: 'Room for the scroll bar on First-Time Setup',
    changes: [
      'First-Time Setup leaves room on the right for its scroll bar, so it '
          'no longer sits on the Browse buttons.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.37',
    date: 'October 1, 2026',
    title: 'Setup starts on the app\'s own folder, with the file server a press away',
    changes: [
      'A new install starts with the Root Folder on the app\'s own folder. '
          'First-Time Setup shows the file server\'s Configurator_Files '
          'folder with a Set to file server button. An install already '
          'reading from the file server stays on it.',
      'Until a first file has been opened, the Open dialog starts in the '
          'Projects folder on the file server.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.36',
    date: 'October 1, 2026',
    title: 'The project total holds still while a room opens',
    changes: [
      'Opening a room from a project no longer makes the total jump up and '
          'back down. While the room is loading it is counted as its file '
          'says, and from memory once it has loaded.',
      'The Procurement and Responsibility grids show one scroll bar down '
          'the right and one along the bottom, instead of an extra pair '
          'beside the room column and under the headings.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.35',
    date: 'October 1, 2026',
    title: 'A steady project total; your own procurement columns',
    changes: [
      'The project total no longer jumps when a room is opened. Opening a '
          'room reads again only the rooms whose files have changed.',
      'Opening a project checks every room\'s files and records what each '
          'room priced at in the project file. When rooms changed since the '
          'last time, the Project tab names them with their old and new '
          'totals.',
      'Rooms at a priority that buys only some items, or that adds items, '
          'are taxed at the job\'s rate again. They had been quoted with no '
          'tax.',
      'The procurement log\'s Columns button adds your own columns, deletes '
          'built-in ones and ticks them back on, and has Delete all to start '
          'the columns over. Added columns are saved with the project, filled '
          'in by pressing a cell, and go into the picture and the '
          'spreadsheet.',
      'A column can also be deleted from its heading.',
      'Add rooms back lists the rooms taken off the procurement log with a '
          'check box each, so only the ones ticked come back.',
      'Moving a column on the Procurement and Responsibility pages is '
          'smoother: the line shows which side it will land, the sheet '
          'scrolls when the column is held near an edge, and a drop on a '
          'heading\'s edge still lands.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.34',
    date: 'October 1, 2026',
    title: 'Faster typing on the Cost tab; search and sorting for parts and deliveries',
    changes: [
      'Typing a name, description, manufacturer, part number or note on the '
          'Cost tab no longer lags. The change is taken when the typing '
          'pauses, on Enter, or on clicking away, rather than on every key.',
      'On the Cost tab, a room on its project\'s tax rate shows the rate: '
          '"Project rate: 9.25%" above the box, and the rate in the box.',
      'The Deliveries page has a search box that finds deliveries and '
          'purchase orders by item, PO number, vendor, location or room.',
      'On the Deliveries page each delivery folds down to its heading line, '
          'Collapse all and Expand all do the lot, and the Purchase Orders '
          'and Delivered sections fold too.',
      'The Equipment page has a Sort by menu: order-by date, part, unit '
          'price, extended price, lead time, package or quantity, with an '
          'arrow that reverses the order.',
      'Adding a delivery or a purchase order shows each part with its '
          'manufacturer, model and part number, and the search finds parts '
          'by any of those as well as by name.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.33',
    date: 'October 1, 2026',
    title: 'The procurement log follows the rooms',
    changes: [
      'The procurement log follows the rooms. Every piece of equipment and '
          'hardware on a room is on the log, and a line shows the name the '
          'room has for it now - rename or swap a part and the log, its '
          'spreadsheet and its picture change with it. A line whose item has '
          'left the room is flagged rather than dropped.',
      'A whole room section can be removed from the procurement log, and '
          'removed lines can be put back from the toolbar.',
      'Column widths on the Procurement and Responsibility pages can be '
          'dragged by the right-hand edge of a heading. The width is kept '
          'with the project; double-click the edge to put it back.',
      'On the Cost tab, a line that is quoted but not drawn can have spares, '
          'the same as a drawn one.',
      'On the Cost tab, the name of every equipment, rack hardware and cable '
          'line can be edited, including lines counted off the diagram - a '
          'row of twelve boxes can be given one title instead of twelve '
          'names. Cleared, it goes back. Any text on the page can be '
          'selected and copied.',
      'On the Cost tab, where the tax rate comes from - the project, the '
          'default, or this room - is said above the Tax rate box.',
      'On the Project Rooms page the Equipment, Labor, Room total, Notes and '
          'buttons line up from row to row.',
      'Install windows are now called maintenance windows.',
      'A to-do with a due date is on the Timeline until it is done.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.32',
    date: 'September 30, 2026',
    title: 'Opening a file no longer marks it edited',
    changes: [
      'Opening a room no longer marks it as changed. A room on its '
          "project's tax rate was reading as edited the moment it opened.",
      'The name of somebody else with a file open is shown only once they '
          'have changed it - unsaved work, or a save since they opened it - '
          'rather than whenever they have it open.',
      'On the Cost tab the Model heading sits directly over the model text.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.31',
    date: 'September 30, 2026',
    title: 'Procurement headings: rename them, whole words',
    changes: [
      'Pressing a Procurement column heading now lets you retitle the '
          'column as well as color it. The title is kept with the project '
          'and used by the spreadsheet and the picture; blank goes back to '
          'the usual one.',
      'A column heading never splits a word across two lines. It wraps '
          'between words, and a word too wide for its column is set a '
          'little smaller instead.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.30',
    date: 'September 30, 2026',
    title: 'Interface size; a full-height procurement grid',
    changes: [
      'App Config has an Interface Size: the whole window is drawn at the '
          'size picked there, whatever the Windows display scaling is. 100% '
          'is the size the app is at Windows 100%; Follow Windows keeps the '
          'old behavior. It runs from 50% to 200%. Text Size still applies on '
          'top, and now runs from 70% to 200%.',
      'The Procurement grid is a full window tall instead of the space left '
          'under the headings. Scrolled to, it fills the screen with its '
          'sideways bar at the foot.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.29',
    date: 'September 30, 2026',
    title: 'Build date; movable procurement columns',
    changes: [
      'Procurement columns can be dragged into a new order by the grip on '
          'each heading. The order is kept with the project and used by the '
          'spreadsheet and the picture.',
      'The Procurement grid fills the window, so its sideways scroll bar is '
          'at the foot of the screen. Click the bar or drag it, or hold Shift '
          'and turn the mouse wheel.',
      'A project has a build date, beside the tax rate. Equipment with no '
          'install date of its own is aged from it on the replacement plan, '
          'so a new building has its lifecycle from the day it opens. A year '
          'on its own can be typed.',
      'The room picker in the title bar has "Close this room", which leaves '
          'the project open.',
      'On the Cost tab, equipment and other items have one Add button each, '
          'like rack hardware and cabling. The dialog takes a catalog part, '
          'or just a name whose details can be filled in on the line later. '
          'The Model column sits a little clear of the name beside it.',
      'Warnings say a part is "missing pricing" and an item is "missing a '
          'vendor and will not be tracked". A job with no spares says so once '
          'on the workbook rather than twice.',
      'The Packages page describes vendors as the companies that will be '
          'sent a quote for equipment related to the current project.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.28',
    date: 'September 30, 2026',
    title: 'Procurement column colors and picture',
    changes: [
      'On the Procurement page, press a column heading to give it a color of '
          'its own, or put it back to its default. The colors are kept with '
          'the project, and the spreadsheet - on its own or in the project '
          'workbook - colors its headings to match.',
      'The Procurement page has an Image button: the whole log as a '
          'picture, in the column colors, to save as a PNG, copy, or '
          'annotate.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.27',
    date: 'September 30, 2026',
    title: 'Manufacturer and part number on every cost line',
    changes: [
      'Every table on the Cost tab - equipment, rack hardware, cabling and '
          'other items - shows each line\'s manufacturer, model and part '
          'number. A line added by hand, with no catalog part behind it, has '
          'its own manufacturer and part number to type, in the Add dialog '
          'and on the line. The room exports carry a Manufacturer column.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.26',
    date: 'September 30, 2026',
    title: 'Online Copy folder',
    changes: [
      'In Online Copy the folder can be typed or edited in place, and Choose '
          "opens in the job's own folder.",
    ],
  ),
  ChangelogEntry(
    version: '0.5.25',
    date: 'September 30, 2026',
    title: 'Estimate notice; procurement log in the workbook',
    changes: [
      'The Procurement page zooms and scrolls both ways with the device '
          'column held in view. The column headings are colored boxes of one '
          'size, and company, status and install phase show as colored '
          'labels. Each date can be typed or picked from a calendar, in the '
          'grid or in the line editor.',
      'The project workbook has an AV Procurement Log sheet, the same as the '
          'Procurement page exports.',
      "The project workbook's Responsibility sheet is the same as the one the "
          'Responsibility page exports.',
      'The standard terms are now the Estimate Notice, set in App Config and '
          "shown in their own box on the Cost tab, apart from the room's own "
          'notes. Room estimates print it last, on the PDF and in Excel; the '
          'project workbook leaves it off. Rooms that had the terms in their '
          'notes have them taken out when opened.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.24',
    date: 'September 30, 2026',
    title: 'Procurement log; a project tax rate; frozen room column',
    changes: [
      'Workbook sheets keep column A - the room or item name - in view when '
          'scrolling right, in Excel and in Google Sheets. The title wraps in '
          'column A instead of being merged across, and a note or a long '
          'sentence is labeled in column A with its text across the rest of '
          'the row.',
      "On the workbook's Summary, a long list of buildings wraps in column B.",
      'A tax rate can be set for the whole project, beside the project number, '
          'and every room uses it unless the room sets its own. Settings has '
          'a default tax rate that new projects start with. Clearing a '
          "room's tax rate puts it back on the project's.",
      "On the Cost tab, a line that is in the room config has a menu on its "
          'tick: "Not part of the room config" or "This product never needs '
          'a module" removes its device block and keeps it on the diagram and '
          'the estimate.',
      'The workbook\'s list of things to check before sending, and the '
          'warnings on the Project tab, say "1 part has" and "5 parts have" '
          'instead of "5 parts has" or "part(s)".',
      'The Project tab has a Procurement page: the AV procurement log for '
          'the contractor, room by room, with the status of each submittal '
          'and who it went to ("Submitted to DPR"), install phase, lead time, '
          'P6 dates and the date required on site. Fill it from the rooms or '
          'add lines by hand, and export it as a spreadsheet.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.23',
    date: 'September 30, 2026',
    title: 'Class schedule in the workbook; progress on job-wide edits',
    changes: [
      'The project workbook has a Class Schedule tab when install windows are '
          'on the timeline: a chart of the windows by date for each room, each '
          "room's week in half-hour slots with its classes and windows, and "
          'the classes meeting in those rooms.',
      'Part names on the room tabs, All Items, Parts by Room, the order '
          'timeline, spares, purchasing and vendor tabs link to their row on '
          'Core Components, and read their model and price from it.',
      'Swapping a confidence monitor to a Dell model names it a PC monitor.',
      'Swapping, renaming or pricing a part in every room shows a progress bar '
          'and no longer holds up the window while the rooms are read and '
          'written. Each room reads only the files the change needs.',
      'The room lists in the swap and rename previews leave room for the '
          'scrollbar.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.22',
    date: 'September 30, 2026',
    title: 'Rename on swap; a log file per day',
    changes: [
      'Swapping a part across the project can rename it too: a name typed '
          'in the swap preview goes on every swapped box and its control '
          'device, in every room.',
      'A new Rename button beside Swap on the project parts list names every '
          'box on that product, in every room, without changing the model.',
      'The session log starts a new file when the date changes, so an app '
          'left open overnight keeps each day\'s activity in its own file. '
          'The old file ends cleanly and the new one names it.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.21',
    date: 'September 29, 2026',
    title: 'New rooms come drawn',
    changes: [
      'A room saved for the first time - a new room, or one built from a '
          'project line item - gets its AV Flow file in room_files straight '
          'away, with its devices placed and the routing drawn from the '
          'config, as the AV Flow tab would on first opening.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.20',
    date: 'September 29, 2026',
    title: 'Everything from the shared folder',
    changes: [
      'File > Use Shared Folder for All Settings points the Root Folder at '
          'the shared Configurator_Files folder and clears every file and '
          'folder chosen elsewhere, so the catalog, rates, vendors and the '
          'rest are all read from there.',
      'Changing the Root Folder now reloads labor rates, base costs, '
          'delivery locations and vendors from the new folder instead of the '
          'files read before.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.19',
    date: 'September 29, 2026',
    title: 'A folder per room',
    changes: [
      'System Settings has Startup/Shutdown Audio Input and Output: a '
          'switcher input tied to the room audio at startup and shutdown. '
          'Both are blank in the default config.',
      'Each room is saved in a folder named for it, as config.json - the '
          'name the processor reads - with its signal flow, racks, floor '
          'plans, cabling, cost, history and backups in a room_files folder '
          'beside it. A room saved the old way is moved into this layout the '
          'next time it is opened, and the project follows it; save the '
          'project afterwards to keep the new link.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.18',
    date: 'September 29, 2026',
    title: 'One shared folder, edited together',
    changes: [
      'The Root Folder defaults to the shared Configurator_Files folder on '
          'doit-files. Anything that folder does not carry - the modules, '
          'manuals, template and buildings list - still comes from the '
          'app\'s own folder.',
      'Several people can have the catalog and the other shared files open '
          'and save at the same time. Each save waits its turn and keeps what '
          'others saved since you opened the file, instead of writing over '
          'it. A save held up for a moment by another person or a virus scan '
          'is retried rather than failing.',
      'Catalog entries, and items in the other shared lists, record who '
          'added them and who last changed them, and when. The Device Editor '
          'shows it above each entry.',
      'Every estimate carries the standard terms in its notes, now including '
          'the 60-day validity and approval wording, on the Cost tab, the PDF '
          'and the Excel exports. Notes you wrote are kept, with the terms '
          'after them, and older wording is brought up to date.',
      'Logging works as it does in the Extron debugger: one log per session, '
          'kept 30 days, every line stamped with its time zone, a header '
          'naming the version and machine, a note when the last session did '
          'not close properly, and a memory reading every minute. Settings '
          'has a Log Folder.',
      'Long sessions: the catalog\'s undo no longer copies the whole catalog '
          'on every change anywhere in the app, and keeps 20 steps rather '
          'than 60. A network drop is logged once rather than every few '
          'seconds.',
      'Updated to the latest components, including the standalone Material '
          'library. Some light-theme text on colored panels is slightly '
          'softer.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.17',
    date: 'September 29, 2026',
    title: 'A folder per room, and a steadier catalog',
    changes: [
      'Each room\'s files now live in a folder named after the room, beside '
          'its config: the AV flow, racks, floor plans, cabling, cost, '
          'history, control schematic, backups, change log and imported '
          'pictures. The folder holding your rooms shows just the room, '
          'project and campus files. Rooms saved the old way are moved into '
          'their folder when you open them.',
      'Core Components lists only the products on the job. Devices with no '
          'control module are on the Control Gaps sheet.',
      'Pulling the online copy back finds a part even after the catalog has '
          'given it a part number or model since the copy was published. A '
          'row it still cannot match is listed, not passed over as '
          'unchanged.',
      'Device Editor: typing in an entry no longer lags. The page remembers '
          'the open entry, search, filters, scroll position and unsaved '
          'changes when you go to another page and come back. Save catalog '
          'stays at the top right, and the other buttons wrap below it when '
          'the window is narrow.',
      'The Root Folder setting shows the app\'s own folder when nothing else '
          'is chosen, and the installer lets users save the files in it, so '
          'the catalog can be saved after a fresh install. A save that '
          'fails says where and why.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.16',
    date: 'September 28, 2026',
    title: 'Core Components comes back, and priority add-ons',
    changes: [
      'Online copy: pulling it back now reads Core Components too. A '
          'changed unit price becomes this job\'s price for that part in '
          'every room that has it, a changed name renames those devices, and '
          'a changed model is swapped in across the job. You are then asked '
          'whether to also update the catalog (price, part number, or a new '
          'model).',
      'Publish-on-save no longer writes over a workbook whose Core '
          'Components has edits nobody has pulled; it holds and asks, as it '
          'already did for deliveries and purchase orders.',
      'Priorities: Replaces only can name items as well as categories, and '
          'take anything from the catalog. Add-ons quote extra items for '
          'every room at a priority - two speakers per room, say - on the '
          'project quote, without changing the room files.',
      'A cost line whose devices share a name shows it once, not once per '
          'device.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.15',
    date: 'September 28, 2026',
    title: 'Summary crew hours linked',
    changes: [
      'Project workbook: the Summary\'s crew hours and total labor hours '
          'add up each room\'s Labor section too.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.14',
    date: 'September 28, 2026',
    title: 'Summary totals linked, and rooms by priority',
    changes: [
      'Project workbook: the Summary\'s Rooms table reads each room tab\'s '
          'totals, and its Building total adds up the rooms that count.',
      'Priorities and funding: each priority has Add rooms, there is an Add '
          'priority button for the next one, and each room has a button to '
          'take it off the job. Rooms can be typed or pasted straight into '
          'any priority, an existing one or a new one.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.13',
    date: 'September 28, 2026',
    title: 'Workbook totals as formulas, and editable quantities',
    changes: [
      'Project workbook: each room\'s part names, models and part numbers '
          'also read from Core Components, and every total is a formula - '
          'the room totals, fees, tax, Parts total and the All Items room '
          'totals - so an edit on Core Components carries all the way '
          'through.',
      'Cost tab: Qty can be typed on every line, drawn ones included. The '
          'drawing keeps its own count, shown in the box until a quantity is '
          'typed; clear it to follow the drawing again.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.12',
    date: 'September 28, 2026',
    title: 'Master-list prices, faster project open, one doc cam',
    changes: [
      'Project workbook: each room\'s unit prices, and those on All Items, '
          'read from the part\'s row on Core Components. Change a price there '
          'in Excel or Google Sheets and every room with that part follows. '
          'A room priced differently keeps its own figure.',
      'Opening a project reads its rooms in the background with a progress '
          'bar, instead of the window freezing while a large job loads.',
      'A room type\'s document camera is no longer drawn twice when the room '
          'is opened.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.11',
    date: 'September 28, 2026',
    title: 'Room sorting, parts by room, and updated room types',
    changes: [
      'Find install windows: the rooms are a drop-down checklist, with '
          'Select all and Deselect all, in alphabetical order.',
      'The title bar\'s room picker lists rooms alphabetically by room code.',
      'Project > Rooms can be sorted by order added, room name or priority.',
      'Project > Equipment has a By room view: each room\'s parts, with '
          'quantity, unit price and a room total.',
      'The Budget card shows what remains after the rooms\' estimate.',
      'The three 2 Display room types have one APC in the rack and a SurgeX '
          'SX-DPP-102 behind each display, instead of three APC units.',
      'Catalog prices filled in from the RYG estimates sheet for 15 models '
          'that had none, including the Sony display, the Shure mics and the '
          'AVer cameras.',
      'Room types now use the DTP CrossPoint 82 4K IPCP Q SA switcher, the '
          'DTP3 CrossPoint 42 USB, and the tabletop TLP Pro 835T and 1035T '
          'touch panels. The 42 USB, 835T and 1035T are new in the catalog, '
          'and the 82 4K Q has current prices.',
      'Device Editor: entries that come with the catalog are no longer '
          'marked as yours. Yours, and My entries only, now mean entries you '
          'added in the app.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.10',
    date: 'September 28, 2026',
    title: 'Campuses you build, and replace-only priorities',
    changes: [
      'A priority set to replace only some categories now leaves the rest of '
          'its rooms off the project entirely: not bought, not installed, and '
          'not on the project export. The room files still list everything, '
          'and the totals say how many lines were left off as existing.',
      'Project workbook: where each part goes is now the Parts by Room tab, '
          'one column per room with the quantity, instead of a long "Rooms:" '
          'line under every part on Core Components.',
      'The Screenshot and Export buttons no longer cover the last rows of a '
          'page. Every page scrolls far enough to clear them.',
      'A project is no longer treated as a campus. File > New Campus starts '
          'empty, and a campus can hold rooms as well as projects. The Campus '
          'button on a project appears only once it is on a saved campus, and '
          'opening a campus no longer changes the open project.',
      'Open Recent and the start screen have Remove missing files, which '
          'forgets only the files that were moved or deleted.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.9',
    date: 'September 28, 2026',
    title: 'Projector-only priorities, and an All Items sheet',
    changes: [
      'A priority can buy only some categories, e.g. priority 5 buys only '
          'Projector. Use the Buys button on its heading under Priorities and '
          'funding. Everything else in those rooms is listed as "Furnished by '
          'existing" at no cost, and the room files are not changed.',
      'The project workbook, in Excel and Google Sheets, has an All Items '
          'sheet after the Summary: every priced line in every room, then '
          'each room\'s total against its target. Room names link to the '
          'room\'s own tab, and each room tab links back to All Items and the '
          'Summary.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.8',
    date: 'September 28, 2026',
    title: 'Several buildings, priorities and funding on a project',
    changes: [
      'Project > Buildings takes more than one building, separated by '
          'commas: "ARTS, HOLT, PAC".',
      'Paste a room list... on Project > Rooms adds one line item per line. '
          'Blank lines and repeats are skipped, and each room\'s building '
          'code is added to the job\'s buildings. Build or Swap on a line '
          'turns it into a real room when you get to it.',
      'Paste a room list... also reads spreadsheet columns: room type, '
          'Central or Dept, and a target price. Blank lines between groups '
          'can set priority 1, 2, 3 and so on.',
      'Project > Rooms has a Priorities and funding card: rooms grouped by '
          'priority with a subtotal for each, and the source and target price '
          'of every room. The budget is the maximum. Money can move between '
          'rooms, but a target that would go over the maximum is refused.',
      'The maximum can be locked. Unlocking it asks first, and the Budget '
          'card shows it with a lock while it is locked.',
      'Build all from room types... on the line items builds a room file '
          'for each line from its room type\'s preset, in the project\'s '
          'folder, and puts it on the job in place of the line. A line keeps '
          'its priority, source and target when it becomes a room.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.7',
    date: 'September 25, 2026',
    title: 'Fits a scaled display, and a setup program',
    changes: [
      'Display scaling: the window now always opens inside the screen. At 125% or 150% scaling its default size was larger than a laptop screen, so it opened with its bottom and right edge out of sight.',
      'Device Editor: the "Pick a model" note scrolls instead of running off '
          'the bottom of a short window.',
      'Setup program: the app can now be installed for everyone into '
          'Program Files, with optional Start menu and desktop shortcuts. '
          'Settings, recovery copies and logs stay in each user\'s '
          '%APPDATA%\\RoomConfigBuilder as before.',
      'Install windows added from Find install windows show on Project > '
          'Timeline\'s dates line as "Install - <room number>", including on '
          'a job with no parts yet.',
      'The project workbook\'s Order Timeline sheet lists the install '
          'windows: date, day, room, time and notes. A job with install '
          'windows and no parts still gets the sheet.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.6',
    date: 'September 25, 2026',
    title: 'Screenshot and export the install window timeline',
    changes: [
      'Find install windows has a screenshot button and an Export menu at '
          'the top right.',
      'The screenshot is the whole timeline, every room and every day in '
          'the range rather than just what is on screen, ready to copy or to '
          'annotate and save as a PNG. It is titled with the job and the '
          'dates, and carries no how-to text.',
      'Export saves the timeline as Excel (.xlsx) or plain text, or copies '
          'it: the planned install windows first, then each room\'s classes '
          'and free windows day by day.',
      'The preset estimate notes now also say what is excluded: electrical, '
          'conduit, raceway, patching and painting (arranged through '
          'Facilities Management Services), and new or repaired network '
          'jacks (a Telecommunications Services request). Estimates '
          'that already have notes keep them.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.5',
    date: 'September 25, 2026',
    title: 'Install window timeline, and the corner buttons tuck away',
    changes: [
      'The screenshot button floats in the lower right corner, just above '
          'Export, and drops into the corner itself when there is nothing '
          'to export. It has left the title bar.',
      'Screenshot and Export fade and shrink into the corner until the '
          'pointer comes near, so they no longer sit over the last rows of '
          'a page. Each wakes up on its own.',
      'Find install windows has a Timeline view (the default): each day is a '
          'row with its classes drawn as blocks and the free stretches '
          'between them in green, like the debugger\'s Room Timeline. Click '
          'a free block to put it on the job; it turns solid. Runs of free '
          'days share one row. The List view is still there.',
      'Find install windows is quicker with long date ranges and several '
          'rooms: each room\'s days are worked out once per change of '
          'settings, and only the rows on screen are built.',
      'PDF wording and Base costs windows are wider, and their scrollbar '
          'sits beside the boxes instead of over them.',
    ],
  ),
  ChangelogEntry(
    version: '0.5.4',
    date: 'September 24, 2026',
    title: 'Install windows from the class schedule, and screenshot sizing',
    changes: [
      'Project > Timeline has an Install windows card. Find install windows '
          'reads the Facilities class schedule export (the same '
          'FacilitiesLinkClassScheduleDaily.csv the CTS-Dashboard uses) and '
          'lists, for each room on the job, when it is free: the stretches '
          'between classes and the whole days with nothing booked (breaks, '
          'the weeks between terms).',
      'Choose the date range, how long a window has to be, the working day, '
          'and whether weekends count. Click a window to put it on the '
          'timeline; click it again to take it off. The windows are saved '
          'with the project.',
      'The schedule file is set in Settings (Class Schedule) or from the '
          'finder itself.',
      'Screenshot annotation window, matching the CTS-Dashboard: the title '
          'and Copy / Save PNG / close stay on the top row at any window size, '
          'and only the drawing tools wrap underneath.',
    ],
  ),
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
