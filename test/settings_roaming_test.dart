// [SETTINGS ROAMING]: two simulated PCs sharing one folder.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:extron_configurator/dpapi_ng.dart';
import 'package:extron_configurator/settings_roaming.dart';
import 'package:flutter_test/flutter_test.dart';

// Stand-ins for the two encryptions: the local one is per PC (its marker
// names the PC, so PC B cannot read PC A's), DPAPI-NG is shared.
String _protect(String pc, String plain) =>
    plain.isEmpty ? '' : 'loc:$pc:${base64Encode(utf8.encode(plain))}';
String _unprotect(String pc, String stored) {
  if (!stored.startsWith('loc:')) return stored;
  if (!stored.startsWith('loc:$pc:')) return '';
  return utf8.decode(base64Decode(stored.substring('loc:$pc:'.length)));
}

Uint8List _ngProtect(Uint8List d, String sid) =>
    Uint8List.fromList([...utf8.encode('$sid|'), ...d.map((b) => b ^ 0x5a)]);
Uint8List _ngUnprotect(Uint8List b) {
  final bar = b.indexOf('|'.codeUnitAt(0));
  return Uint8List.fromList(b.sublist(bar + 1).map((x) => x ^ 0x5a).toList());
}

class _Pc {
  _Pc(this.name, this.dir, String team,
      {List<List<String>> filePaths = const []}) {
    roaming = SettingsRoaming(
      app: 'test_app',
      login: 'someone',
      machine: name,
      files: [
        RoamingFile(
          id: 'config',
          path: '${dir.path}/Config.json',
          roams: (k, v) => k != 'Logs' && !SettingsRoaming.isLocalDrivePath(v),
          filePaths: filePaths,
        ),
        RoamingFile(
            id: 'wm',
            path: '${dir.path}/window_memory.json',
            section: 'settings'),
      ],
      statePath: '${dir.path}/state.json',
      fileStoreDir: '${dir.path}/roamed',
      protectLocal: (p) => _protect(name, p),
      unprotectLocal: (s) => _unprotect(name, s),
      isLocalSecret: (s) => s.startsWith('loc:'),
      ngProtect: _ngProtect,
      ngUnprotect: _ngUnprotect,
      userSid: () async => 'S-1-5-21-1',
    )..folder = team;
  }

  final String name;
  final Directory dir;
  late final SettingsRoaming roaming;

  File get config => File('${dir.path}/Config.json');
  Map<String, dynamic> read() => jsonDecode(config.readAsStringSync());
  void write(Map<String, dynamic> m) => config.writeAsStringSync(jsonEncode(m));
  String secret(String key) => _unprotect(name, read()[key] as String);
}

void main() {
  late Directory root;
  late String team;
  late _Pc a;
  late _Pc b;

  setUp(() {
    root = Directory.systemTemp.createTempSync('roaming_test');
    team = '${root.path}/team';
    a = _Pc('PCA', Directory('${root.path}/a')..createSync(), team);
    b = _Pc('PCB', Directory('${root.path}/b')..createSync(), team);
  });
  tearDown(() => root.deleteSync(recursive: true));

  Map<String, dynamic> shareDoc() =>
      jsonDecode(File(a.roaming.shareFile).readAsStringSync());

  test('first PC puts its settings on the share, secrets sealed', () async {
    a.write({
      'isDarkMode': true,
      'Logs': 'C:/logs',
      'Tickets': 'C:/Users/me/tickets.xlsx',
      'TightVNC_Password': _protect('PCA', 'hunter2'),
    });
    final r = await a.roaming.sync(startup: true);
    expect(r.problem, '');
    expect(r.needsChoice, isFalse);
    final cfg = shareDoc()['files']['config'] as Map;
    expect(cfg['isDarkMode']['v'], true);
    expect(cfg.containsKey('Logs'), isFalse, reason: 'machine-only key');
    expect(cfg.containsKey('Tickets'), isFalse, reason: 'local drive path');
    final sealed = cfg['TightVNC_Password']['v'] as String;
    expect(sealed, startsWith('ngsid:v1:'));
    expect(File(a.roaming.shareFile).readAsStringSync(),
        isNot(contains('hunter2')));
    expect(
        a.roaming.shareFile,
        endsWith(
            'users${Platform.pathSeparator}someone${Platform.pathSeparator}test_app_settings.json'));
  });

  test('second PC asks, then takes the share settings', () async {
    a.write(
        {'isDarkMode': true, 'TightVNC_Password': _protect('PCA', 'hunter2')});
    await a.roaming.sync(startup: true);

    b.write({'isDarkMode': false, 'Logs': 'D:/mine'});
    final ask = await b.roaming.sync(startup: true);
    expect(ask.needsChoice, isTrue);
    expect(b.read()['isDarkMode'], false, reason: 'nothing before the choice');

    final r =
        await b.roaming.sync(startup: true, choice: RoamingChoice.useShared);
    expect(r.pulledFiles, contains('config'));
    expect(b.read()['isDarkMode'], true);
    expect(b.read()['Logs'], 'D:/mine');
    // Re-encrypted for PC B's own local store.
    expect(b.read()['TightVNC_Password'], startsWith('loc:PCB:'));
    expect(b.secret('TightVNC_Password'), 'hunter2');
  });

  test('an iPad or Mac folder path is not pushed or pulled', () async {
    const ipad = '/private/var/mobile/Library/LiveFiles/'
        'com.apple.filesystems.smbclientd/x/CTS';
    expect(SettingsRoaming.isLocalDrivePath(ipad), isTrue);
    expect(SettingsRoaming.isLocalDrivePath('~/Documents'), isTrue);
    expect(SettingsRoaming.isLocalDrivePath(r'\\server\share'), isFalse);
    expect(SettingsRoaming.isLocalDrivePath('//server/share'), isFalse);

    a.write({'Root': ipad, 'isDarkMode': true});
    await a.roaming.sync(startup: true);
    final cfg = shareDoc()['files']['config'] as Map;
    expect(cfg.containsKey('Root'), isFalse);

    // One already on the share (written before this rule) is not taken.
    final doc = shareDoc();
    (doc['files']['config'] as Map)['Root'] = {
      ...(cfg['isDarkMode'] as Map),
      'v': ipad,
    };
    File(a.roaming.shareFile).writeAsStringSync(jsonEncode(doc));
    b.write({'Root': r'\\server\share'});
    await b.roaming.sync(startup: true, choice: RoamingChoice.useShared);
    expect(b.read()['Root'], r'\\server\share');
  });

  test('keep this PC puts its settings over the share', () async {
    a.write({'isDarkMode': true});
    await a.roaming.sync(startup: true);
    b.write({'isDarkMode': false});
    await b.roaming.sync(startup: true, choice: RoamingChoice.keepThisPc);
    expect(shareDoc()['files']['config']['isDarkMode']['v'], false);
    expect(b.read()['isDarkMode'], false);
  });

  test('a change on one PC reaches the other at its next start only', () async {
    a.write({'isDarkMode': true, 'uiTextScale': 1.0});
    await a.roaming.sync(startup: true);
    b.write({});
    await b.roaming.sync(startup: true, choice: RoamingChoice.useShared);

    a.write({...a.read(), 'uiTextScale': 1.25});
    final pushed = await a.roaming.sync();
    expect(pushed.pushed, 1);

    // While running, B only pushes.
    final running = await b.roaming.sync();
    expect(running.pulled, 0);
    expect(b.read()['uiTextScale'], 1.0);

    final start = await b.roaming.sync(startup: true);
    expect(start.pulled, 1);
    expect(b.read()['uiTextScale'], 1.25);

    // Nothing changed anywhere now.
    final again = await b.roaming.sync(startup: true);
    expect(again.pushed + again.pulled, 0);
  });

  test('re-encrypting the same password is not a change', () async {
    a.write({'p': _protect('PCA', 'x')});
    await a.roaming.sync(startup: true);
    // DPAPI output differs each time; simulate with a different-looking blob
    // that decrypts the same.
    a.write({'p': 'loc:PCA:${base64Encode(utf8.encode('x'))}'});
    expect((await a.roaming.sync()).pushed, 0);
  });

  test('a removed key is removed on the other PC', () async {
    a.write({'x': 1, 'y': 2});
    await a.roaming.sync(startup: true);
    b.write({});
    await b.roaming.sync(startup: true, choice: RoamingChoice.useShared);
    a.write({'x': 1});
    await a.roaming.sync();
    await b.roaming.sync(startup: true);
    expect(b.read().containsKey('y'), isFalse);
  });

  test('only the named section of window_memory roams', () async {
    a.write({});
    File('${a.dir.path}/window_memory.json').writeAsStringSync(jsonEncode({
      'windows': {
        'room': {'x': 1}
      },
      'settings': {'campusMap.satellite': true},
    }));
    await a.roaming.sync(startup: true);
    b.write({});
    File('${b.dir.path}/window_memory.json').writeAsStringSync(jsonEncode({
      'windows': {
        'room': {'x': 99}
      },
    }));
    final r =
        await b.roaming.sync(startup: true, choice: RoamingChoice.useShared);
    expect(r.pulledFiles, contains('wm'));
    final wm =
        jsonDecode(File('${b.dir.path}/window_memory.json').readAsStringSync());
    expect(wm['settings']['campusMap.satellite'], true);
    expect(wm['windows']['room']['x'], 99);
  });

  test('a key file travels encrypted and is written locally', () async {
    final key = File('${a.dir.path}/sa.json')
      ..writeAsStringSync('{"k":"secret-key"}');
    final paths = [
      ['OnlineSources', 'GoogleServiceAccountKey'],
    ];
    a = _Pc('PCA', a.dir, team, filePaths: paths);
    b = _Pc('PCB', b.dir, team, filePaths: paths);
    a.write({
      'OnlineSources': {
        'GoogleServiceAccountKey': key.path,
        'GoogleAccess': 'serviceAccount'
      }
    });
    await a.roaming.sync(startup: true);
    expect(File(a.roaming.shareFile).readAsStringSync(),
        isNot(contains('secret-key')));

    b.write({});
    await b.roaming.sync(startup: true, choice: RoamingChoice.useShared);
    final local =
        b.read()['OnlineSources']['GoogleServiceAccountKey'] as String;
    expect(local, startsWith(Directory('${b.dir.path}/roamed').absolute.path));
    expect(File(local).readAsStringSync(), '{"k":"secret-key"}');
  });

  test('plain-text secrets and a virtual store (keystore / prefs)', () async {
    SettingsRoaming pc(String name, Map<String, dynamic> store) =>
        SettingsRoaming(
          app: 'virt',
          login: 'someone',
          machine: name,
          files: [
            RoamingFile(
              id: 'prefs',
              path: 'prefs',
              plainSecretKeys: const {'smtpPassword'},
              load: () async => Map<String, dynamic>.of(store),
              store: (set, remove) async {
                store.addAll(set);
                remove.forEach(store.remove);
              },
            ),
          ],
          statePath: '${root.path}/$name.state.json',
          fileStoreDir: '${root.path}/$name.roamed',
          protectLocal: (p) => p,
          unprotectLocal: (s) => s,
          isLocalSecret: (_) => false,
          ngProtect: _ngProtect,
          ngUnprotect: _ngUnprotect,
          userSid: () async => 'S-1-5-21-1',
        )..folder = team;

    final storeA = <String, dynamic>{'smtpPassword': 'p@ss', 'devMode': false};
    await pc('A', storeA).sync(startup: true);
    final text =
        File('$team/users/someone/virt_settings.json').readAsStringSync();
    expect(text, isNot(contains('p@ss')));
    expect(text, contains('ngsid:p1:'));

    final storeB = <String, dynamic>{'devMode': true};
    await pc('B', storeB).sync(startup: true, choice: RoamingChoice.useShared);
    expect(storeB['smtpPassword'], 'p@ss');
    expect(storeB['devMode'], false);
  });

  test('off on this PC does nothing', () async {
    a.write({'x': 1});
    await a.roaming.sync(startup: true, choice: RoamingChoice.off);
    expect(File(a.roaming.shareFile).existsSync(), isFalse);
    expect(await a.roaming.isEnabled(), isFalse);
    await a.roaming.setEnabled(true);
    await a.roaming.sync(startup: true);
    expect(File(a.roaming.shareFile).existsSync(), isTrue);
  });

  test('real DPAPI-NG to my own SID round-trips (this PC, on the domain)',
      () async {
    final sid = await SettingsRoaming.currentUserSid();
    if (sid.isEmpty) {
      markTestSkipped('no SID here');
      return;
    }
    final Uint8List blob;
    try {
      blob = DpapiNg.protect(utf8.encode('roaming check'), sid);
    } on DpapiNgException catch (e) {
      markTestSkipped('DPAPI-NG unavailable: $e');
      return;
    }
    expect(utf8.decode(DpapiNg.unprotect(blob)), 'roaming check');
  }, skip: !Platform.isWindows);
}
