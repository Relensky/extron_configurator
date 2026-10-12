// The settings kit off dart:io (a web build): nothing is stored between runs
// and every path is taken to be there. See settings_kit_io.dart.

String? readKitValue(String name) => null;

void writeKitValue(String name, String value) {}

Future<bool> kitPathExists(String path, {bool folder = false}) async => true;
