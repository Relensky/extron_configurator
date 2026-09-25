; ============================================================================
; Room Config Builder - what flutter_app.iss needs to know about this app.
; Everything else about the installer is shared; see flutter_app.iss.
; ============================================================================

#define AppName "Room Config Builder"
#define AppExeName "room_config_builder.exe"
; Never change: Windows uses it to find the existing install to upgrade.
#define AppId "{{80B1F60B-A1FB-4D85-9E0A-3F22E9A29EE8}"
#define AppPublisher "CSU Chico CTS"
#define AppFolder "Room Config Builder"
; Setup file name: room_config_builder_setup_<version>.exe
#define SetupBaseName "room_config_builder"
; Settings, recovery copies and logs already live in %APPDATA%\RoomConfigBuilder
; (lib/app_paths.dart), so nothing needs moving out of the install folder.
#define PerUserData 0

[Files]
; The data files the release zip carries beside the exe. The app reads them
; from its own folder when Settings names nothing else. A file or folder
; missing here is skipped.
Source: "..\av_devices.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\base_costs.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\buildings.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\config.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\delivery_locations.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\key_map.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\labor_rates.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\processors.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\ui_schema.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\vendor_list.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\Room_Config_Builder_Guide.pdf"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\Revised 11.25.25_Personnel Billing Rates 25-26_CSUEU.pdf"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\device\*"; DestDir: "{app}\device"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist; Excludes: ".mypy_cache,__pycache__"
Source: "..\documentation\*"; DestDir: "{app}\documentation"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
Source: "..\room_presets\*"; DestDir: "{app}\room_presets"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
Source: "..\RYG campus\*"; DestDir: "{app}\RYG campus"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
