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
; The AV Flow tab's rules. Save them from the Flow Rules tab into the repo
; root to ship them; without the file the app uses its built-in rules.
Source: "..\av_flow_rules.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\labor_rates.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\processors.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\ui_schema.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\vendor_list.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\Room_Config_Builder_Guide.pdf"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\Revised 11.25.25_Personnel Billing Rates 25-26_CSUEU.pdf"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
; The ControlScript device modules, from the ControlScript-Template repo
; checked out beside this one. They go in {app}\devices - the folder the app
; scans when Settings names no Modules Path (effectiveModulesPath). No
; skipifsourcedoesntexist: a build without the modules must fail, not ship
; an app with none. convert_modules_drop_in_then_run.py is a tool, not a
; module.
Source: "..\..\ControlScript-Template\base\assets\src\modules\device\*"; DestDir: "{app}\devices"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: ".mypy_cache,__pycache__,convert_modules_drop_in_then_run.py"
Source: "..\documentation\*"; DestDir: "{app}\documentation"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
Source: "..\room_presets\*"; DestDir: "{app}\room_presets"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
Source: "..\RYG campus\*"; DestDir: "{app}\RYG campus"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist

[InstallDelete]
; Older setups installed the modules to {app}\device, which the app
; never looked in.
Type: filesandordirs; Name: "{app}\device"
