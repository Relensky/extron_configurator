#ifndef RUNNER_CRASH_LOG_H_
#define RUNNER_CRASH_LOG_H_

// Records crashes the Dart error handlers cannot see - the process dying in
// native code, or never reaching a normal close - in the app's error log.
//
// Writes to %APPDATA%\RoomConfigBuilder\logs, the same folder AppLogger uses
// (lib/app_logger.dart).

// Call first thing in wWinMain. Reports any earlier session that did not
// close normally, marks this one as running, and installs the handlers.
void InstallCrashLogging();

// Call after a normal close. lib/crash_session.dart does the same for exits
// that skip wWinMain's return, such as installing an update.
void EndCrashLoggingSession();

#endif  // RUNNER_CRASH_LOG_H_
