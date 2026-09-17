#include "crash_log.h"

// clang-format off
#include <windows.h>
#include <dbghelp.h>
// clang-format on

#include <algorithm>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>
#include <vector>

namespace {

// Crash dumps kept in the log folder; older ones are deleted at startup.
constexpr size_t kDumpsKept = 5;

std::wstring g_log_dir;
std::wstring g_marker;

// Set by whichever handler logs first, so one crash is one entry.
volatile LONG g_crash_logged = 0;

std::wstring ResolveLogDir() {
  for (const wchar_t* name : {L"APPDATA", L"LOCALAPPDATA"}) {
    wchar_t buffer[MAX_PATH];
    DWORD length = ::GetEnvironmentVariableW(name, buffer, MAX_PATH);
    if (length > 0 && length < MAX_PATH) {
      return std::wstring(buffer) + L"\\RoomConfigBuilder\\logs";
    }
  }
  return L"";
}

std::string Utf8(const std::wstring& text) {
  if (text.empty()) return "";
  int size = ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, nullptr, 0,
                                   nullptr, nullptr);
  if (size <= 1) return "";
  std::string out(size - 1, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, out.data(), size,
                        nullptr, nullptr);
  return out;
}

// Local time, in the shape AppLogger writes (ISO 8601).
std::string Timestamp() {
  SYSTEMTIME t;
  ::GetLocalTime(&t);
  char text[32];
  snprintf(text, sizeof(text), "%04u-%02u-%02uT%02u:%02u:%02u.%03u", t.wYear,
           t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
  return text;
}

std::wstring FileTimestamp() {
  SYSTEMTIME t;
  ::GetLocalTime(&t);
  wchar_t text[32];
  swprintf(text, 32, L"%04u%02u%02u_%02u%02u%02u", t.wYear, t.wMonth, t.wDay,
           t.wHour, t.wMinute, t.wSecond);
  return text;
}

// Appends one entry to deployment_app_error_log.txt, formatted like
// AppLogger.logError.
void AppendError(const std::string& message) {
  if (g_log_dir.empty()) return;
  const std::wstring path = g_log_dir + L"\\deployment_app_error_log.txt";
  HANDLE file = ::CreateFileW(path.c_str(), FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  const std::string entry =
      "[" + Timestamp() + "] ERROR: " + message +
      "\n--------------------------------------------------\n";
  DWORD written = 0;
  ::WriteFile(file, entry.data(), static_cast<DWORD>(entry.size()), &written,
              nullptr);
  ::CloseHandle(file);
}

// Writes crash_<time>.dmp and returns its file name, or "" on failure.
std::wstring WriteDump(EXCEPTION_POINTERS* pointers) {
  if (g_log_dir.empty()) return L"";
  const std::wstring name = L"crash_" + FileTimestamp() + L".dmp";
  const std::wstring path = g_log_dir + L"\\" + name;
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return L"";
  MINIDUMP_EXCEPTION_INFORMATION info{::GetCurrentThreadId(), pointers, FALSE};
  const BOOL ok = ::MiniDumpWriteDump(
      ::GetCurrentProcess(), ::GetCurrentProcessId(), file,
      static_cast<MINIDUMP_TYPE>(MiniDumpNormal | MiniDumpWithThreadInfo),
      pointers ? &info : nullptr, nullptr, nullptr);
  ::CloseHandle(file);
  if (!ok) {
    ::DeleteFileW(path.c_str());
    return L"";
  }
  return name;
}

// The DLL or exe an address belongs to, e.g. "pdfium.dll".
std::string ModuleOf(void* address) {
  HMODULE module = nullptr;
  if (!::GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            static_cast<LPCWSTR>(address), &module)) {
    return "an unknown module";
  }
  wchar_t path[MAX_PATH];
  if (::GetModuleFileNameW(module, path, MAX_PATH) == 0) {
    return "an unknown module";
  }
  std::wstring full(path);
  const size_t slash = full.find_last_of(L"\\/");
  return Utf8(slash == std::wstring::npos ? full : full.substr(slash + 1));
}

void LogCrash(const std::string& what, EXCEPTION_POINTERS* pointers) {
  if (::InterlockedExchange(&g_crash_logged, 1) != 0) return;
  const std::wstring dump = WriteDump(pointers);
  AppendError("The app crashed: " + what +
              (dump.empty() ? ". No crash dump could be written."
                            : ". Crash dump: " + Utf8(dump)));
}

LONG WINAPI OnUnhandledException(EXCEPTION_POINTERS* pointers) {
  char what[160];
  snprintf(what, sizeof(what), "exception 0x%08lX in %s",
           pointers->ExceptionRecord->ExceptionCode,
           ModuleOf(pointers->ExceptionRecord->ExceptionAddress).c_str());
  LogCrash(what, pointers);
  // Let Windows Error Reporting carry on as it would have.
  return EXCEPTION_CONTINUE_SEARCH;
}

void OnAbort(int) { LogCrash("abort() was called", nullptr); }

void OnTerminate() {
  LogCrash("std::terminate was called", nullptr);
  std::abort();
}

// session_<pid>.running marks a session that has not closed yet.
std::wstring MarkerFor(DWORD pid) {
  return g_log_dir + L"\\session_" + std::to_wstring(pid) + L".running";
}

bool ProcessIsRunning(DWORD pid) {
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return false;
  DWORD code = 0;
  const bool running =
      ::GetExitCodeProcess(process, &code) && code == STILL_ACTIVE;
  ::CloseHandle(process);
  return running;
}

std::string ReadSmallFile(const std::wstring& path) {
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
  if (file == INVALID_HANDLE_VALUE) return "";
  char buffer[256];
  DWORD read = 0;
  ::ReadFile(file, buffer, sizeof(buffer) - 1, &read, nullptr);
  ::CloseHandle(file);
  std::string text(buffer, read);
  while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
    text.pop_back();
  }
  return text;
}

// Reports and clears markers left by sessions that are no longer running.
// A marker whose process is still alive is another open copy of the app.
void ReportUnclosedSessions() {
  WIN32_FIND_DATAW found;
  HANDLE search = ::FindFirstFileW(
      (g_log_dir + L"\\session_*.running").c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return;
  do {
    const std::wstring name = found.cFileName;
    const DWORD pid =
        static_cast<DWORD>(wcstoul(name.c_str() + wcslen(L"session_"),
                                   nullptr, 10));
    if (pid != 0 && ProcessIsRunning(pid)) continue;
    const std::wstring path = g_log_dir + L"\\" + name;
    const std::string started = ReadSmallFile(path);
    AppendError("The previous session" +
                (started.empty() ? std::string() : " (" + started + ")") +
                " did not close normally. The app crashed, stopped "
                "responding and was ended, or Windows shut down while it was "
                "open.");
    ::DeleteFileW(path.c_str());
  } while (::FindNextFileW(search, &found));
  ::FindClose(search);
}

void WriteMarker() {
  g_marker = MarkerFor(::GetCurrentProcessId());
  HANDLE file = ::CreateFileW(g_marker.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
                              nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    g_marker.clear();
    return;
  }
  const std::string text = "started " + Timestamp();
  DWORD written = 0;
  ::WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written,
              nullptr);
  ::CloseHandle(file);
}

void PruneDumps() {
  std::vector<std::wstring> dumps;
  WIN32_FIND_DATAW found;
  HANDLE search =
      ::FindFirstFileW((g_log_dir + L"\\crash_*.dmp").c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return;
  do {
    dumps.push_back(found.cFileName);
  } while (::FindNextFileW(search, &found));
  ::FindClose(search);
  if (dumps.size() <= kDumpsKept) return;
  // Names sort by time.
  std::sort(dumps.begin(), dumps.end());
  for (size_t i = 0; i + kDumpsKept < dumps.size(); ++i) {
    ::DeleteFileW((g_log_dir + L"\\" + dumps[i]).c_str());
  }
}

}  // namespace

void InstallCrashLogging() {
  g_log_dir = ResolveLogDir();
  if (!g_log_dir.empty()) {
    const size_t logs = g_log_dir.find_last_of(L'\\');
    ::CreateDirectoryW(g_log_dir.substr(0, logs).c_str(), nullptr);
    ::CreateDirectoryW(g_log_dir.c_str(), nullptr);
    ReportUnclosedSessions();
    PruneDumps();
    WriteMarker();
  }
  ::SetUnhandledExceptionFilter(OnUnhandledException);
  std::set_terminate(OnTerminate);
  std::signal(SIGABRT, OnAbort);
}

void EndCrashLoggingSession() {
  if (!g_marker.empty()) ::DeleteFileW(g_marker.c_str());
}
