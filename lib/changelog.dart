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

const String kAppVersion = '0.5.86+96';

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
