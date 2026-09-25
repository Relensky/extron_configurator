; ============================================================================
; Windows installer for a CTS Flutter app (Inno Setup 6).
;
; SHARED: this file and build_installer.ps1 are byte-identical in
; extron_debugger, extron_configurator, instructor_contact_flutter,
; geo_guess_csuchico and quizzer. Everything that differs between the apps -
; name, exe, AppId, extra files - is in app_settings.iss beside it, so a fix
; here is copied to the other four unchanged.
;
; Build with build_installer.ps1, which finds ISCC.exe and can build the
; release first. The setup:
;   - installs for all users into C:\Program Files\<AppFolder> (asks for
;     administrator permission),
;   - asks whether to add a Start menu shortcut and a desktop shortcut (for
;     everyone on the PC),
;   - replaces an older install in place, closing the app first,
;   - adds an uninstaller to Settings > Apps.
; Program Files cannot be written by a normal user, so an app that keeps
; files beside its exe must set PerUserData and keep them in AppData (see
; the app's own per-user data code).
; ============================================================================

#include "app_settings.iss"

#ifndef ReleaseDir
  #define ReleaseDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\build\installer"
#endif
#ifndef SetupIcon
  #define SetupIcon "..\windows\runner\resources\app_icon.ico"
#endif
#ifndef PerUserData
  #define PerUserData 0
#endif

#define ExePath AddBackslash(ReleaseDir) + AppExeName
#if !FileExists(ExePath)
  #error No release build found. Run: flutter build windows --release
#endif
; pubspec's version, e.g. 1.13.0+22 - the same string the in-app updater reads.
#define AppVersion GetStringFileInfo(ExePath, "ProductVersion")

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppFolder}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename={#SetupBaseName}_setup_{#AppVersion}
SetupIconFile={#SetupIcon}
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
; A running copy holds its exe and DLLs open; close it rather than fail.
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "startmenuicon"; Description: "Create a &Start menu shortcut"; GroupDescription: "Shortcuts (for everyone on this PC):"
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts (for everyone on this PC):"

[Files]
; The release build. Anything a test run may have left in the folder -
; settings, secrets, logs, chats, reports - stays out.
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb,*.log,*.bak*,Config.json,secrets.json,dashboard_logs,logs,AiChats,ping_reports,reports,per_user_data.txt"
#if PerUserData
; Tells the app it is installed, so it keeps its files in AppData even when
; run as administrator (when Program Files would be writable).
Source: "per_user_data.txt"; DestDir: "{app}"; Flags: ignoreversion
#endif

[Icons]
; Admin install: {autoprograms} / {autodesktop} are the all-users folders.
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: startmenuicon
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
; As the signed-in user, not the administrator who approved the install.
Filename: "{app}\{#AppExeName}"; Description: "Start {#AppName} now"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallDelete]
; Files the in-app updater added after install are not in the uninstall log.
; Each user's own files in AppData are left alone.
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\*.dll"
Type: files; Name: "{app}\{#AppExeName}"
Type: dirifempty; Name: "{app}"
