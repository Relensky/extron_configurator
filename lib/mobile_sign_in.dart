import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

import 'app_paths.dart';
import 'services/ios_share.dart';
import 'team/team_host.dart' show kDefaultTeamFolder;
import 'team/team_presence.dart' show TeamIdentity;

// ============================================================================
//  [iOS SIGN-IN]: who is using the app on an iPhone or iPad
// ============================================================================
//  On Windows the app knows who you are from the Windows sign-in, and
//  everything personal hangs off that name: your settings in the team folder
//  (team\users\<login>), your picture, your presence chip and chat messages,
//  and "changed by" on everything you save. An iPad has no Windows sign-in -
//  the app saw "unknown" - so it asks once for the same campus username and
//  keeps it on the device.
//
//  The same screen connects the CTS share first, because that is where the
//  username is checked and where the settings it unlocks come from.
//
//  Read at startup, BEFORE the app state is made: the presence, chat and
//  collaboration pieces take their identity when they are created.
// ============================================================================

String? get _file {
  final dir = userDataDirOrNull();
  return dir == null ? null : path.join(dir, 'sign_in.json');
}

/// The campus username kept on this device, or ''.
String loadMobileLogin() {
  try {
    final f = _file;
    if (f == null || !File(f).existsSync()) return '';
    final d = jsonDecode(File(f).readAsStringSync());
    return d is Map ? '${d['login'] ?? ''}'.trim() : '';
  } catch (_) {
    return '';
  }
}

void _saveMobileLogin(String login) {
  final f = _file;
  if (f == null) return;
  File(f).parent.createSync(recursive: true);
  File(f).writeAsStringSync(
    jsonEncode({'login': login, 'at': DateTime.now().toIso8601String()}),
  );
}

/// Forgets the username; the sign-in screen shows on the next start.
void signOutMobile() {
  try {
    final f = _file;
    if (f != null && File(f).existsSync()) File(f).deleteSync();
  } catch (_) {}
}

/// On iOS: sets this device's identity for the team kit and the save stamps,
/// asking for it first when none is kept. Call before the app is made.
Future<void> ensureMobileSignIn() async {
  if (!Platform.isIOS) return;
  TeamIdentity.machineOverride = await IosShare.deviceName();
  var login = loadMobileLogin();
  if (login.isEmpty) {
    final done = Completer<String>();
    runApp(_SignInApp(onDone: done.complete));
    login = await done.future;
    _saveMobileLogin(login);
  }
  TeamIdentity.userOverride = login;
}

/// The login as the folders spell it: lower case, no domain.
String _cleanLogin(String raw) {
  var s = raw.trim();
  final at = s.indexOf('@');
  if (at > 0) s = s.substring(0, at);
  final slash = s.lastIndexOf(RegExp(r'[\\/]'));
  if (slash >= 0) s = s.substring(slash + 1);
  return s.toLowerCase();
}

class _SignInApp extends StatelessWidget {
  const _SignInApp({required this.onDone});
  final void Function(String login) onDone;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Room Config Builder',
    theme: ThemeData(colorSchemeSeed: const Color(0xFF1E88E5)),
    darkTheme: ThemeData(
      colorSchemeSeed: const Color(0xFF1E88E5),
      brightness: Brightness.dark,
    ),
    home: _SignInPage(onDone: onDone),
  );
}

class _SignInPage extends StatefulWidget {
  const _SignInPage({required this.onDone});
  final void Function(String login) onDone;

  @override
  State<_SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<_SignInPage> {
  final _login = TextEditingController();
  String _shareMessage = '';
  bool _picking = false;

  /// null: not checked (no share); true / false: a settings folder for the
  /// name is / isn't in the team folder.
  bool? _found;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _login.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 500), _check);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _login.dispose();
    super.dispose();
  }

  Future<void> _pickShare() async {
    setState(() => _picking = true);
    final problem = await IosShare.pick();
    if (!mounted) return;
    setState(() {
      _picking = false;
      _shareMessage = problem ?? '';
    });
    _check();
  }

  Future<void> _check() async {
    final login = _cleanLogin(_login.text);
    if (login.isEmpty || !IosShare.active || IosShare.offline) {
      if (mounted) setState(() => _found = null);
      return;
    }
    final users = path.join(sharePath(kDefaultTeamFolder), 'users', login);
    bool? found;
    try {
      found = await Directory(users).exists().timeout(IosShare.answerWithin);
    } catch (_) {
      found = null;
    }
    if (mounted && _cleanLogin(_login.text) == login) {
      setState(() => _found = found);
    }
  }

  void _continue() {
    final login = _cleanLogin(_login.text);
    if (login.isEmpty) return;
    widget.onDone(login);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final connected = IosShare.active && !IosShare.offline;
    final login = _cleanLogin(_login.text);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.tablet_mac_outlined,
                    size: 56,
                    color: scheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Room Config Builder',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Set up this device',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _step(
                    theme,
                    number: '1',
                    title: 'Connect to the CTS share',
                    done: connected,
                    body: [
                      const Text(
                        'On campus Wi-Fi or the VPN, open the Files app, tap '
                        '… > Connect to Server and enter '
                        'smb://doit-files.csuchico.edu. Then come back here '
                        'and pick the Classroom Technology folder '
                        '(ATEC > CTS > StaffFiles > Classroom Technology).',
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          icon: _picking
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  connected
                                      ? Icons.check_circle_outline
                                      : Icons.dns_outlined,
                                ),
                          label: Text(
                            connected
                                ? 'Connected - pick again'
                                : 'Pick the share folder',
                          ),
                          onPressed: _picking ? null : _pickShare,
                        ),
                      ),
                      if (_shareMessage.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            _shareMessage,
                            style: TextStyle(color: scheme.error),
                          ),
                        ),
                      if (!connected)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'You can skip this and connect later from the '
                            'cloud button in the top bar; the app works '
                            'from its own files until then.',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _step(
                    theme,
                    number: '2',
                    title: 'Your campus username',
                    done: _found == true,
                    body: [
                      const Text(
                        'The name you sign in to a campus PC with. Your '
                        'settings, picture and team chat come from it, and '
                        'it goes on everything you save.',
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _login,
                        autocorrect: false,
                        enableSuggestions: false,
                        textCapitalization: TextCapitalization.none,
                        decoration: const InputDecoration(
                          labelText: 'Username',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _continue(),
                      ),
                      if (login.isNotEmpty && _found != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            _found!
                                ? 'Found $login on the share.'
                                : 'No one called $login has used the CTS apps '
                                      'yet. Check the spelling - a new name '
                                      'starts with default settings.',
                            style: TextStyle(
                              color: _found!
                                  ? Colors.green.shade700
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: login.isEmpty ? null : _continue,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Continue'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _step(
    ThemeData theme, {
    required String number,
    required String title,
    required bool done,
    required List<Widget> body,
  }) {
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: done ? Colors.green.shade600 : scheme.primary,
              foregroundColor: Colors.white,
              child: done
                  ? const Icon(Icons.check, size: 16)
                  : Text(number, style: const TextStyle(fontSize: 13)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  ...body,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
