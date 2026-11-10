import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ============================================================================
// [TEAM VAULT - AD GROUP LOCK]: Windows DPAPI-NG, protecting to a group.
//
// The classic DPAPI in secret_store.dart locks a value to ONE Windows user on
// ONE machine. DPAPI-NG (ncrypt.dll, Windows 8 / Server 2012 and later) can
// lock it to a protection descriptor instead - here "SID=<group SID>" - so
// any member of that Active Directory group, on any domain PC, can unlock it,
// and nobody else can. The keys come from the domain's Group Key
// Distribution Service; there is no shared password and nothing in this
// binary that helps an outsider.
//
// What it needs: a domain-joined PC, a domain whose controllers run Server
// 2012 or later with a KDS root key (standard in a current AD), and the user
// in the group. Without those, [protect] / [unprotect] throw
// [DpapiNgException] with the Windows error, and the vault falls back to its
// passphrase.
// ============================================================================

class DpapiNgException implements Exception {
  final String message;
  final int status;
  const DpapiNgException(this.message, this.status);

  @override
  String toString() =>
      '$message (0x${(status & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')})';
}

/// One AD group the signed-in user belongs to.
class AdGroup {
  final String name;
  final String sid;
  const AdGroup(this.name, this.sid);

  @override
  bool operator ==(Object other) => other is AdGroup && other.sid == sid;

  @override
  int get hashCode => sid.hashCode;
}

typedef _CreateDescNative = Int32 Function(
    Pointer<Utf16>, Uint32, Pointer<IntPtr>);
typedef _CreateDesc = int Function(Pointer<Utf16>, int, Pointer<IntPtr>);
typedef _CloseDescNative = Int32 Function(IntPtr);
typedef _CloseDesc = int Function(int);
typedef _ProtectNative = Int32 Function(IntPtr, Uint32, Pointer<Uint8>, Uint32,
    Pointer<Void>, IntPtr, Pointer<Pointer<Uint8>>, Pointer<Uint32>);
typedef _Protect = int Function(int, int, Pointer<Uint8>, int, Pointer<Void>,
    int, Pointer<Pointer<Uint8>>, Pointer<Uint32>);
typedef _UnprotectNative = Int32 Function(Pointer<IntPtr>, Uint32,
    Pointer<Uint8>, Uint32, Pointer<Void>, IntPtr, Pointer<Pointer<Uint8>>,
    Pointer<Uint32>);
typedef _Unprotect = int Function(Pointer<IntPtr>, int, Pointer<Uint8>, int,
    Pointer<Void>, int, Pointer<Pointer<Uint8>>, Pointer<Uint32>);
typedef _LocalFreeNative = IntPtr Function(Pointer<Void>);
typedef _LocalFree = int Function(Pointer<Void>);

class DpapiNg {
  DpapiNg._();

  /// No UI from the key service, ever - this runs behind the app's own.
  static const int _ncryptSilent = 0x40;

  static DynamicLibrary? _ncrypt;
  static DynamicLibrary? _kernel32;

  static bool get supported => Platform.isWindows;

  static DynamicLibrary get _nc => _ncrypt ??= DynamicLibrary.open('ncrypt.dll');
  static DynamicLibrary get _k32 =>
      _kernel32 ??= DynamicLibrary.open('kernel32.dll');

  /// Locks [data] so only members of the group with [groupSid] can unlock it.
  static Uint8List protect(Uint8List data, String groupSid) {
    if (!supported) {
      throw const DpapiNgException('AD group lock needs Windows', -1);
    }
    final create = _nc.lookupFunction<_CreateDescNative, _CreateDesc>(
        'NCryptCreateProtectionDescriptor');
    final close = _nc.lookupFunction<_CloseDescNative, _CloseDesc>(
        'NCryptCloseProtectionDescriptor');
    final protectSecret =
        _nc.lookupFunction<_ProtectNative, _Protect>('NCryptProtectSecret');
    final localFree =
        _k32.lookupFunction<_LocalFreeNative, _LocalFree>('LocalFree');

    final descriptor = 'SID=$groupSid'.toNativeUtf16();
    final handle = calloc<IntPtr>();
    final input = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    final out = calloc<Pointer<Uint8>>();
    final outLen = calloc<Uint32>();
    try {
      var status = create(descriptor, 0, handle);
      if (status != 0) {
        throw DpapiNgException('Windows would not use that group', status);
      }
      try {
        input.asTypedList(data.length).setAll(0, data);
        status = protectSecret(handle.value, _ncryptSilent, input, data.length,
            nullptr, 0, out, outLen);
        if (status != 0) {
          throw DpapiNgException(
              'Windows could not lock the vault to that group', status);
        }
        final result = Uint8List.fromList(out.value.asTypedList(outLen.value));
        localFree(out.value.cast());
        return result;
      } finally {
        close(handle.value);
      }
    } finally {
      // Wipe the plaintext copy before giving the memory back.
      for (var i = 0; i < data.length; i++) {
        input[i] = 0;
      }
      calloc.free(descriptor);
      calloc.free(handle);
      calloc.free(input);
      calloc.free(out);
      calloc.free(outLen);
    }
  }

  /// Unlocks a blob from [protect]. Throws when this user is not in the group
  /// (or the domain cannot be reached and no key is cached).
  static Uint8List unprotect(Uint8List blob) {
    if (!supported) {
      throw const DpapiNgException('AD group lock needs Windows', -1);
    }
    final unprotectSecret = _nc
        .lookupFunction<_UnprotectNative, _Unprotect>('NCryptUnprotectSecret');
    final localFree =
        _k32.lookupFunction<_LocalFreeNative, _LocalFree>('LocalFree');
    final input = calloc<Uint8>(blob.isEmpty ? 1 : blob.length);
    final out = calloc<Pointer<Uint8>>();
    final outLen = calloc<Uint32>();
    try {
      input.asTypedList(blob.length).setAll(0, blob);
      final status = unprotectSecret(nullptr, _ncryptSilent, input, blob.length,
          nullptr, 0, out, outLen);
      if (status != 0) {
        throw DpapiNgException(
            'This Windows account cannot unlock the vault with its group',
            status);
      }
      final view = out.value.asTypedList(outLen.value);
      final result = Uint8List.fromList(view);
      for (var i = 0; i < view.length; i++) {
        view[i] = 0;
      }
      localFree(out.value.cast());
      return result;
    } finally {
      calloc.free(input);
      calloc.free(out);
      calloc.free(outLen);
    }
  }

  /// The domain groups the signed-in user is in, from `whoami /groups`.
  /// Empty off Windows, off the domain, or on any failure.
  static Future<List<AdGroup>> myGroups() async {
    if (!supported) return const [];
    try {
      final r = await Process.run('whoami', ['/groups', '/fo', 'csv', '/nh']);
      return parseWhoamiGroups(r.stdout as String);
    } catch (_) {
      return const [];
    }
  }

  /// Rows of `whoami /groups /fo csv /nh` whose type is "Group" - the domain
  /// groups, not the machine's aliases or the well-known ones.
  static List<AdGroup> parseWhoamiGroups(String csv) {
    final out = <AdGroup>[];
    for (final line in csv.split(RegExp(r'\r?\n'))) {
      final m = RegExp(r'^"([^"]*)","([^"]*)","([^"]*)"').firstMatch(line);
      if (m == null) continue;
      if (m.group(2) != 'Group') continue;
      final sid = m.group(3)!;
      if (!sid.startsWith('S-1-5-21-')) continue;
      out.add(AdGroup(m.group(1)!, sid));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }
}
