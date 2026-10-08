// ============================================================================
// [TEAM CHAT - PASTE]: a picture from the Windows clipboard, for Ctrl+V in
// the chat.
//
// Flutter's Clipboard only carries text, and a clipboard package would be
// another native plugin to keep building, so this reads the clipboard
// through user32 directly (ffi is already a dependency). In order:
//   1. "PNG"   - what browsers and Office put there; kept as it is.
//   2. CF_DIB  - what Print Screen, Win+Shift+S and the Snipping Tool put
//                there; turned into RGBA here and into a PNG by the caller.
//   3. CF_HDROP - image files copied in File Explorer; read from disk.
// ============================================================================

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

/// A picture ready to post: its file bytes, extension and size.
class ClipboardPicture {
  final Uint8List bytes;
  final String ext;
  final int width;
  final int height;

  /// The file it came from, for one copied in File Explorer.
  final String name;

  const ClipboardPicture(this.bytes, this.ext, this.width, this.height,
      {this.name = ''});
}

/// The largest picture the chat takes, from the clipboard or a file.
const int kChatPictureMaxBytes = 20 * 1024 * 1024;

/// Extensions the chat shows as pictures.
const Set<String> kChatPictureExtensions = {
  'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'
};

class ClipboardImage {
  ClipboardImage._();

  static const int _cfDib = 8;
  static const int _cfHdrop = 15;

  static DynamicLibrary? _user32, _kernel32, _shell32;
  static DynamicLibrary get _u32 =>
      _user32 ??= DynamicLibrary.open('user32.dll');
  static DynamicLibrary get _k32 =>
      _kernel32 ??= DynamicLibrary.open('kernel32.dll');
  static DynamicLibrary get _s32 =>
      _shell32 ??= DynamicLibrary.open('shell32.dll');

  static final _openClipboard = _u32.lookupFunction<
      Int32 Function(IntPtr), int Function(int)>('OpenClipboard');
  static final _closeClipboard = _u32
      .lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
  static final _isFormatAvailable = _u32.lookupFunction<
      Int32 Function(Uint32), int Function(int)>('IsClipboardFormatAvailable');
  static final _getClipboardData = _u32.lookupFunction<
      IntPtr Function(Uint32), int Function(int)>('GetClipboardData');
  static final _registerFormat = _u32.lookupFunction<
      Uint32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)>('RegisterClipboardFormatW');
  static final _globalLock = _k32.lookupFunction<
      Pointer<Uint8> Function(IntPtr), Pointer<Uint8> Function(int)>(
      'GlobalLock');
  static final _globalUnlock = _k32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('GlobalUnlock');
  static final _globalSize = _k32
      .lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GlobalSize');
  static final _dragQueryFile = _s32.lookupFunction<
      Uint32 Function(IntPtr, Uint32, Pointer<Utf16>, Uint32),
      int Function(int, int, Pointer<Utf16>, int)>('DragQueryFileW');

  static int? _pngFormat;

  /// Whether the clipboard holds something [read] can turn into a picture.
  /// Cheap: nothing is copied.
  static bool get hasPicture {
    if (!Platform.isWindows) return false;
    try {
      return _isFormatAvailable(_png) != 0 ||
          _isFormatAvailable(_cfDib) != 0 ||
          _isFormatAvailable(_cfHdrop) != 0;
    } catch (_) {
      return false;
    }
  }

  static int get _png {
    final cached = _pngFormat;
    if (cached != null) return cached;
    final name = 'PNG'.toNativeUtf16();
    try {
      return _pngFormat = _registerFormat(name);
    } finally {
      calloc.free(name);
    }
  }

  /// The pictures on the clipboard (several for files copied in File
  /// Explorer), or an empty list when it holds none. Throws only for a
  /// picture that is too big, with a message to show.
  static Future<List<ClipboardPicture>> read() async {
    if (!Platform.isWindows) return const [];
    final raw = _readRaw();
    if (raw == null) return const [];
    if (raw.png != null) {
      final png = raw.png!;
      final size = pngSize(png);
      return [ClipboardPicture(png, 'png', size.$1, size.$2)];
    }
    if (raw.dib != null) {
      final decoded = dibToRgba(raw.dib!);
      if (decoded == null) return const [];
      final png = await _rgbaToPng(decoded.rgba, decoded.width, decoded.height);
      if (png == null) return const [];
      _checkSize(png.length);
      return [ClipboardPicture(png, 'png', decoded.width, decoded.height)];
    }
    final out = <ClipboardPicture>[];
    for (final path in raw.files) {
      final dot = path.lastIndexOf('.');
      final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
      if (!kChatPictureExtensions.contains(ext)) continue;
      final file = File(path);
      _checkSize(await file.length());
      final bytes = await file.readAsBytes();
      final size = await pictureSize(bytes);
      out.add(ClipboardPicture(bytes, ext, size.$1, size.$2,
          name: path.split(RegExp(r'[\\/]')).last));
    }
    return out;
  }

  static void _checkSize(int length) {
    if (length > kChatPictureMaxBytes) {
      throw StateError('That picture is ${(length / 1048576).toStringAsFixed(1)} '
          'MB; the chat takes up to ${kChatPictureMaxBytes ~/ 1048576} MB.');
    }
  }

  /// Copies what is on the clipboard out of it, holding it open as briefly
  /// as possible. Another program can have it open: a few quick retries.
  static ({Uint8List? png, Uint8List? dib, List<String> files})? _readRaw() {
    var opened = false;
    for (var i = 0; i < 5 && !opened; i++) {
      opened = _openClipboard(0) != 0;
      if (!opened) sleep(const Duration(milliseconds: 20));
    }
    if (!opened) return null;
    try {
      Uint8List? copy(int format) {
        if (_isFormatAvailable(format) == 0) return null;
        final h = _getClipboardData(format);
        if (h == 0) return null;
        final p = _globalLock(h);
        if (p == nullptr) return null;
        try {
          final n = _globalSize(h);
          if (n <= 0) return null;
          _checkSize(n);
          return Uint8List.fromList(p.asTypedList(n));
        } finally {
          _globalUnlock(h);
        }
      }

      final png = copy(_png);
      if (png != null && pngSize(png).$1 > 0) {
        return (png: png, dib: null, files: const []);
      }
      final dib = copy(_cfDib);
      if (dib != null) return (png: null, dib: dib, files: const []);
      final files = <String>[];
      if (_isFormatAvailable(_cfHdrop) != 0) {
        final h = _getClipboardData(_cfHdrop);
        if (h != 0) {
          final count = _dragQueryFile(h, 0xFFFFFFFF, nullptr, 0);
          for (var i = 0; i < count && i < 20; i++) {
            final len = _dragQueryFile(h, i, nullptr, 0);
            final buf = calloc<Uint16>(len + 1);
            try {
              _dragQueryFile(h, i, buf.cast(), len + 1);
              files.add(buf.cast<Utf16>().toDartString(length: len));
            } finally {
              calloc.free(buf);
            }
          }
        }
      }
      return (png: null, dib: null, files: files);
    } finally {
      _closeClipboard();
    }
  }

  /// A PNG's width and height from its header; (0, 0) when it is not one.
  static (int, int) pngSize(Uint8List b) {
    if (b.length < 24 ||
        b[0] != 0x89 ||
        b[1] != 0x50 ||
        b[2] != 0x4E ||
        b[3] != 0x47) {
      return (0, 0);
    }
    final d = ByteData.sublistView(b);
    return (d.getUint32(16), d.getUint32(20));
  }

  /// Any picture's size, by decoding it; (0, 0) when Flutter cannot.
  static Future<(int, int)> pictureSize(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final size = (frame.image.width, frame.image.height);
      frame.image.dispose();
      codec.dispose();
      return size;
    } catch (_) {
      return (0, 0);
    }
  }

  /// A CF_DIB (BITMAPINFOHEADER or V4/V5, then the pixels) as opaque RGBA.
  /// 24- and 32-bit only - what screenshots are; null for anything else.
  static ({Uint8List rgba, int width, int height})? dibToRgba(Uint8List dib) {
    if (dib.length < 40) return null;
    final d = ByteData.sublistView(dib);
    final headerSize = d.getUint32(0, Endian.little);
    final width = d.getInt32(4, Endian.little);
    final rawHeight = d.getInt32(8, Endian.little);
    final bpp = d.getUint16(14, Endian.little);
    final compression = d.getUint32(16, Endian.little);
    if (width <= 0 || rawHeight == 0 || (bpp != 24 && bpp != 32)) return null;
    // BI_RGB (0) or BI_BITFIELDS (3) only.
    if (compression != 0 && compression != 3) return null;
    final height = rawHeight.abs();
    final bottomUp = rawHeight > 0;

    // Channel masks: BI_BITFIELDS puts them after a 40-byte header, a V4/V5
    // header holds them itself. Otherwise blue, green, red.
    int rMask = 0x00FF0000, gMask = 0x0000FF00, bMask = 0x000000FF;
    var offset = headerSize;
    if (compression == 3 && bpp == 32) {
      // Right after the 40-byte core header in either case.
      const at = 40;
      if (dib.length < at + 12) return null;
      rMask = d.getUint32(at, Endian.little);
      gMask = d.getUint32(at + 4, Endian.little);
      bMask = d.getUint32(at + 8, Endian.little);
      if (headerSize == 40) offset += 12;
    }
    final stride = ((width * bpp + 31) ~/ 32) * 4;
    if (dib.length < offset + stride * height) return null;

    int shiftOf(int mask) {
      if (mask == 0) return 0;
      var s = 0;
      while ((mask >> s) & 1 == 0) {
        s++;
      }
      return s;
    }

    final rs = shiftOf(rMask), gs = shiftOf(gMask), bs = shiftOf(bMask);
    final out = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      final srcRow = offset + (bottomUp ? height - 1 - y : y) * stride;
      var o = y * width * 4;
      if (bpp == 24) {
        for (var x = 0; x < width; x++) {
          final i = srcRow + x * 3;
          out[o++] = dib[i + 2];
          out[o++] = dib[i + 1];
          out[o++] = dib[i];
          out[o++] = 255;
        }
      } else {
        for (var x = 0; x < width; x++) {
          final px = d.getUint32(srcRow + x * 4, Endian.little);
          out[o++] = (px & rMask) >> rs;
          out[o++] = (px & gMask) >> gs;
          out[o++] = (px & bMask) >> bs;
          // Screenshots leave alpha at 0; they are always opaque.
          out[o++] = 255;
        }
      }
    }
    return (rgba: out, width: width, height: height);
  }

  static Future<Uint8List?> _rgbaToPng(Uint8List rgba, int w, int h) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(buffer,
        width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return data?.buffer.asUint8List();
  }
}
