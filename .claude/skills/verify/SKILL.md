---
name: verify
description: Build, launch, and drive the Room Config Builder Windows app to verify changes end-to-end.
---

# Verifying the Room Config Builder (Flutter Windows)

## Build & launch
- `flutter run -d windows --no-resident` — builds (~60s cold) and detaches.
  The process is **room_config_builder** (not extron_configurator); window
  title "Room Config Builder".
- No hot reload with `--no-resident`; code changes need a full stop + rerun:
  `Stop-Process -Name room_config_builder -Force`.

## Driving the UI (no test framework — real window automation)
- PowerShell + user32 (SetCursorPos / mouse_event / SendKeys) works well.
  **Call `SetProcessDPIAware()` first** — this machine runs 3840x2160 at
  200% scale and un-aware processes get virtualized coordinates.
- While a native file dialog is open, the process's MainWindowTitle is the
  dialog's title — match the window by process name, not title.
- Native file dialogs (open/save): focus lands in the filename box; SendKeys
  the full path + `{ENTER}`.

## Getting a config loaded
- On launch nothing is loaded. "Create New Config (From template)" loads the
  template but **zeroes all dev_ counts** (wizard flow) — the Devices and
  Schematic tabs will be empty.
- To get real devices, use the folder-open toolbar button and open
  `config.json` from the repo root (counts: 2 cameras, 1 projector, 1
  switcher, 1 power, wireless). Loading it triggers a "Legacy Config
  Updated" dialog (Acknowledge) and writes side artifacts **into the config's
  folder**: `<Room>_old_config.json` backup, `config_backup_log.txt`,
  `deployment_app_migration_log.txt` — delete these after testing, and never
  save/export over the repo config.json. Prefer copying config.json to the
  scratchpad and opening that copy.

## Gotchas
- `flutter analyze` baseline is ~60 info-level lints (exit code 1); errors
  and warnings are the signal, infos are pre-existing.
- The Edit tool can corrupt this repo's CRLF files in rare cases — if git
  suddenly shows a whole-file diff, check for a stray NUL byte
  (`file` says "data" instead of text).
- pubspec: the `excel` package conflicts with pdfrx (xml constraint);
  xlsx export uses the hand-rolled `lib/xlsx_writer.dart` over `archive`.
