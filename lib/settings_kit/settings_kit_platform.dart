// The settings kit's file work, picked at compile time: dart:io never reaches
// a web build. See settings_kit.dart.
export 'settings_kit_stub.dart' if (dart.library.io) 'settings_kit_io.dart';
