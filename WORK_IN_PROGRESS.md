# Work in progress - October 16, 2026

Nothing is committed yet. All the changes below are in the working tree.

## Released

- **0.5.130+140**: built, and the setup .exe and .zip are copied to Beta.
- **0.5.131+141** (in kind): built (`build\installer\room_config_builder_setup_0.5.131+141.exe` and the `.zip`). **Not copied to Beta yet.** It is on hold until the light-mode freeze below is understood. The freeze happened in 0.5.129, so it is not new in 0.5.131. If it is not a new bug, copy both files to `\\doit-files\ATEC\CTS\StaffFiles\Program_Releases\Beta`.
- The full test suite passed on 0.5.131 (4,466 tests).

## Released 17:10
- **0.5.137+147** is in Beta: Add several connectors (count, type, direction, location) in the Device Editor and the AV Flow device dialog; the Network switch (no module) category; categories you add yourself (saved in the catalog file as `categories`); the Update catalog wording and price-needed note for unpriced catalog parts; Other items above Rack hardware; the Optional upgrades card also shows for an optional crew alone.
- Chat pictures close on a click beside them in all three apps. CTS Dashboard **1.40.6+140** and Instructor Contact **0.9.38+51** are in Beta with that alone.
- Catalog data: the Netgear M4250-40G8F-PoE+ has all 40 ports network, both ways, top. It and the Cisco C1300-48FP-4X, the Cisco Network switch and the TP-Link TL-SG108PE are now Network switch (no module). Done in the share's av_devices.json and the repo copy; the Netgear entry was added to the repo copy.
- 4,499 tests passed. Of the 5 failures, two were flakes that passed alone, and three were tests updated for the new card order and for two-way ports placed anywhere.

## Released 16:31
- **0.5.136+146** is in Beta: the options section switch hides while options are left out of the total, the Optional upgrades card sits above Equipment, and the row buttons line up on every table (tag, replace, catalog, catalog price, delete). 4,495 tests passed.

## Released 15:51
- **0.5.135+145** is in Beta. Add all cables from config (AV Flow and Cabling card), Copy quantity in Compare and copy, minus/lower count takes cabled and config units off (config block removed, count down), Optional on every line and labor, tag button and Replace with another model on Other items, Estimate only switch on the Cost tab, project in-kind and options figures plus the in-kind list on the Budget card, pane icons swapped, room close on the Project tab. 4,494 tests passed.
- Config changes from the minus button are not on the drawing's Undo, same as Delete line.

## Released 14:52
- **0.5.134+144** is in Beta. It has: drawn parts swap in Compare and copy, the P5 Bought for priority ticks and per-room add-on edits, Other items above Cabling, Packages renamed Quotes, and optional upgrades (Cost tab card and switches, PDF, project With options and per-room options off, purge). 4,485 tests passed.
- Not built: purging options from a room that is not open (only the Cost tab of the open room has it); no test drives the project page's With options chip or the room-row button.

## Released 13:42
- **0.5.133+143** is in Beta (setup .exe and .zip). It has: the theme-switch fix for the chat button (`_TeamChatFabState.didUpdateWidget` no longer marks the overlay dirty during a build), Replace a part in Compare and copy, Sort A to Z / by priority on the room menu, and per-device replace plus per-gear ticks in AV Flow Copy from a room. 4,472 tests passed.
- The freeze was never caught hanging in a test. The chat-button fix is the best lead; if it happens again, note the tab and chat mode.
- The two new Copy from a room dialogs have no click-through test yet.

## Afternoon pickup
- **Emoji count - fixed** in `_reactionChip`: the fill is made opaque (own reaction blended over `surface`) and the count is white or black87 depending on that fill's brightness.
- **Freeze - still not reproduced.** The four loops flagged below now skip a non-finite path length (`dashPath`, the two dashed-border painters in `schematic_view.dart`, `runEndAnchor` in `cabling_schematic.dart`). That is hardening only; the cause is not confirmed. Still open: how the switch was made and what was on screen.
- Scratch tests deleted. Bumped to **0.5.132+142**.

## Decision (user, 11:50)
Hold 0.5.131. Find the freeze and fix the emoji count first, then bump to 0.5.132, build and copy to Beta.

## Findings since (11:50 to 12:00)
- **Emoji count - cause confirmed.** In Classic teal (009688) dark mode, your own reaction's chip fill is `primaryContainer` at 70% alpha (rgb 0.35/0.60/0.58, mid teal). The count is painted **pure black** (`onPrimaryContainer`), which measures 3.5:1. That is the dark number you see. Fix in `_reactionChip` (`lib/team/team_widgets.dart:3074`): blend the fill over the panel background, then choose light or dark ink by contrast (for example with `ThemeData.estimateBrightnessForColor`). Do the same for others' reactions instead of leaving the color null. Note that the floating chat panel paints its own background, black87 in dark mode and white in light (`lib/team/team_floating_panel.dart:198`), not the theme surface.
- **Freeze - not reproduced yet.** No hang when switching dark to light with SCI248 open on any of the 17 tabs, in Classic teal or the default style (`test/zz_freeze_repro_test.dart`). No hang with the real team chat open in floating mode either (`test/zz_freeze_chat_repro_test.dart`). The other chat modes only failed on test-teardown errors.
- The saved settings still say `isDarkMode: true`, so the hang came before the async settings save ran. The app theme does not follow Windows (MaterialApp uses only the in-app setting). The log shows the app going inactive and active just before the hang.
- **Ask the user next:** how did they switch to light - the sun/moon toolbar button, App Config, or Windows Settings? And what was on screen: which tab, and was the chat or a dialog open?
- **Delete the scratch tests before release:** `test/zz_freeze_repro_test.dart`, `test/zz_freeze_chat_repro_test.dart`, `test/zz_reaction_color_test.dart`.

## In progress

### 1. The app froze switching from dark to light mode
- Found in the running 0.5.129 copy (pid 48076): it showed "Not Responding" and kept one CPU core at 100%. Its log (`%APPDATA%\RoomConfigBuilder\logs\session_log_2026-10-16_10-15-11_48076.txt`) stops at 11:44:29 and the heartbeat stopped too. That points to an endless loop on the main thread, not a deadlock.
- The SCI248 room (`C:\GitHub\ControlScript-Template\rooms\SCI248\...`) was open, and the team chat had been in use.
- Ruled out: the contrast helpers in `lib/contrast.dart` (their loops are bounded), the Auris scheme loop, and the chat format parser (its loop does not depend on the theme).
- Next step: a scratch widget test based on `test/theme_toggle_test.dart`. Open SCI248 in `RoomConfigApp`, then switch dark to light on every tab, printing each tab first. Run it with `flutter test --timeout 60s` so a hang shows which tab causes it. Still to check: the dash-painting loops `lib/run_painting.dart:85` and `lib/schematic_view.dart:2015/2374` (they never end if a path length is infinite or NaN), and `lib/cabling_schematic.dart:1107`.

### 2. In dark mode, the emoji reaction count in team chat is dark text
- Happens only in this app, not in Instructor Contact or the Dashboard.
- The code is `_reactionChip` in `lib/team/team_widgets.dart:3074`. The count's color is `onPrimaryContainer` on a 70%-alpha `primaryContainer` (your own reaction), or the theme's default `labelSmall` color (other people's reactions). Neither is measured against the fill that is actually drawn.
- Planned fix: blend the fill over the surface it sits on (`Color.alphaBlend`), then choose light or dark ink from that blend. `lib/team` imports nothing from the app, so keep the fix local to that file.
- No changes have been made for this yet.

## Done this session (uncommitted; also in the changelog for 0.5.130 and 0.5.131)
- Copy from another room: fixed the blank list on projects whose rooms are each a folder with a `config.json`. Added a Room file button, plus recent projects and rooms first.
- The Compare/copy window stays open, copies in both directions, and has Replace existing items.
- P1/P2 priority badges in the title-bar room menu.
- Combine nags about room snapshots: opening a project no longer rewrites it when only prices moved. Combines that differ only in snapshots are silent.
- Catalog combine lists each model and each changed field before anything is taken.
- AV Flow, Copy from a room: copies the AV flow, racks, floor plans and cabling. Models missing from the catalog are each added or left out.
- In kind: labor in kind, an in-kind block under the totals, an In kind table in the PDF, workbook and text exports, and an "In kind - from our stock" option when adding a part that is not in the catalog.
