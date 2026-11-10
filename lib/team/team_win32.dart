import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ============================================================================
// [TEAM KIT - APPS]: finding and focusing another CTS program, straight
// through Windows.
//
// TeamAppLaunch used to ask `tasklist` whether a program was running (about
// 350 ms) and start PowerShell to bring its window to the front (about
// 800 ms) - over a second before a hand-off even began. These calls do the
// same in a few milliseconds. Each returns null / false when it cannot
// answer, and the caller falls back to the old way.
// ============================================================================

final class _ProcessEntry32W extends Struct {
  @Uint32()
  external int dwSize;
  @Uint32()
  external int cntUsage;
  @Uint32()
  external int th32ProcessID;
  @IntPtr()
  external int th32DefaultHeapID;
  @Uint32()
  external int th32ModuleID;
  @Uint32()
  external int cntThreads;
  @Uint32()
  external int th32ParentProcessID;
  @Int32()
  external int pcPriClassBase;
  @Uint32()
  external int dwFlags;
  @Array(260)
  external Array<Uint16> szExeFile;
}

typedef _EnumProcNative = Int32 Function(IntPtr hwnd, IntPtr lParam);

class TeamWin32 {
  TeamWin32._();

  static DynamicLibrary? _k32;
  static DynamicLibrary? _u32;

  static DynamicLibrary get _kernel32 =>
      _k32 ??= DynamicLibrary.open('kernel32.dll');
  static DynamicLibrary get _user32 =>
      _u32 ??= DynamicLibrary.open('user32.dll');

  /// Process ids of every running copy of [exe] ('instructor_contact_system.exe',
  /// matched without case), or null when Windows could not be asked.
  static List<int>? pidsOf(String exe) {
    if (!Platform.isWindows) return null;
    try {
      final snapshot = _kernel32.lookupFunction<
          IntPtr Function(Uint32, Uint32),
          int Function(int, int)>('CreateToolhelp32Snapshot');
      final first = _kernel32.lookupFunction<
          Int32 Function(IntPtr, Pointer<_ProcessEntry32W>),
          int Function(int, Pointer<_ProcessEntry32W>)>('Process32FirstW');
      final next = _kernel32.lookupFunction<
          Int32 Function(IntPtr, Pointer<_ProcessEntry32W>),
          int Function(int, Pointer<_ProcessEntry32W>)>('Process32NextW');
      final close = _kernel32.lookupFunction<Int32 Function(IntPtr),
          int Function(int)>('CloseHandle');

      const th32csSnapProcess = 0x2;
      final handle = snapshot(th32csSnapProcess, 0);
      if (handle == -1 || handle == 0) return null;
      final entry = calloc<_ProcessEntry32W>();
      try {
        entry.ref.dwSize = sizeOf<_ProcessEntry32W>();
        final wanted = exe.toLowerCase();
        final pids = <int>[];
        var ok = first(handle, entry);
        while (ok != 0) {
          final name = _exeName(entry.ref.szExeFile);
          if (name.toLowerCase() == wanted) pids.add(entry.ref.th32ProcessID);
          ok = next(handle, entry);
        }
        return pids;
      } finally {
        calloc.free(entry);
        close(handle);
      }
    } catch (_) {
      return null;
    }
  }

  static String _exeName(Array<Uint16> chars) {
    final codes = <int>[];
    for (var i = 0; i < 260; i++) {
      final c = chars[i];
      if (c == 0) break;
      codes.add(c);
    }
    return String.fromCharCodes(codes);
  }

  // EnumWindows' callback reports through these (it runs synchronously on
  // this thread, inside the EnumWindows call).
  static int _wantedPid = 0;
  static int _found = 0;
  static int Function(int, Pointer<Uint32>)? _windowPid;
  static int Function(int)? _isVisible;
  static int Function(int, int)? _getWindow;

  static int _enumProc(int hwnd, int lParam) {
    final pidOut = calloc<Uint32>();
    try {
      _windowPid!(hwnd, pidOut);
      if (pidOut.value != _wantedPid) return 1;
      const gwOwner = 4;
      if (_isVisible!(hwnd) == 0 || _getWindow!(hwnd, gwOwner) != 0) return 1;
      _found = hwnd;
      return 0;
    } finally {
      calloc.free(pidOut);
    }
  }

  /// Brings the main window of process [processId] to the front, restoring
  /// it when minimised. False when it has no visible window or Windows
  /// refused.
  static bool focusProcess(int processId) {
    if (!Platform.isWindows) return false;
    try {
      _windowPid ??= _user32.lookupFunction<
          Uint32 Function(IntPtr, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
      _isVisible ??= _user32.lookupFunction<Int32 Function(IntPtr),
          int Function(int)>('IsWindowVisible');
      _getWindow ??= _user32.lookupFunction<IntPtr Function(IntPtr, Uint32),
          int Function(int, int)>('GetWindow');
      final enumWindows = _user32.lookupFunction<
          Int32 Function(Pointer<NativeFunction<_EnumProcNative>>, IntPtr),
          int Function(
              Pointer<NativeFunction<_EnumProcNative>>, int)>('EnumWindows');
      final isIconic = _user32.lookupFunction<Int32 Function(IntPtr),
          int Function(int)>('IsIconic');
      final showWindow = _user32.lookupFunction<Int32 Function(IntPtr, Int32),
          int Function(int, int)>('ShowWindow');
      final setForeground = _user32.lookupFunction<Int32 Function(IntPtr),
          int Function(int)>('SetForegroundWindow');

      _wantedPid = processId;
      _found = 0;
      enumWindows(
          Pointer.fromFunction<_EnumProcNative>(_enumProc, 0), 0);
      final hwnd = _found;
      if (hwnd == 0) return false;
      const swRestore = 9;
      if (isIconic(hwnd) != 0) showWindow(hwnd, swRestore);
      return setForeground(hwnd) != 0;
    } catch (_) {
      return false;
    }
  }
}
