import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'app_state.dart';

/// A path on App Config: applied once typing stops, with a spinner until the
/// folder or file behind it has been read.
///
/// Every key used to apply the path - and start reading a share - on each
/// letter typed or deleted, and the field was keyed on the saved value, so it
/// was rebuilt under the cursor as well. Now the path is applied after
/// [delay] without a keystroke, or straight away on Enter or leaving the box.
class SettingsPathField extends StatefulWidget {
  const SettingsPathField({
    super.key,
    required this.provider,
    required this.settingKey,
    required this.value,
    required this.decoration,
    this.delay = const Duration(milliseconds: 900),
  });

  final AppStateProvider provider;

  /// The [AppStateProvider.updateSetting] key this field writes.
  final String settingKey;

  /// The saved path. A new one from outside (a folder picked with the
  /// button) replaces the text unless the box is being typed in.
  final String value;

  /// Its suffix is kept, with the spinner placed in front of it.
  final InputDecoration decoration;

  final Duration delay;

  @override
  State<SettingsPathField> createState() => _SettingsPathFieldState();
}

class _SettingsPathFieldState extends State<SettingsPathField> {
  late final TextEditingController _text =
      TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();
  Timer? _wait;
  bool _reading = false;

  /// Bumped per apply, so an older read finishing does not stop the spinner
  /// of a newer one.
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _applyNow();
    });
  }

  @override
  void didUpdateWidget(SettingsPathField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value &&
        widget.value != _text.text &&
        !_focus.hasFocus) {
      _text.text = widget.value;
    }
  }

  @override
  void dispose() {
    // A pause cut short by leaving the page still applies what was typed.
    if (_wait?.isActive ?? false) {
      _wait!.cancel();
      if (_text.text != widget.value) {
        widget.provider.updateSetting(widget.settingKey, _text.text);
      }
    }
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _typed(String _) {
    _wait?.cancel();
    _wait = Timer(widget.delay, _applyNow);
  }

  Future<void> _applyNow() async {
    _wait?.cancel();
    final value = _text.text;
    if (value == widget.value) return;
    final run = ++_run;
    setState(() => _reading = true);
    await widget.provider.updateSetting(widget.settingKey, value);
    await widget.provider.settingWork;
    if (mounted && run == _run) setState(() => _reading = false);
  }

  @override
  Widget build(BuildContext context) {
    final suffix = widget.decoration.suffixIcon;
    return TextFormField(
      // Stable: keyed on the setting, not the value, so applying the path
      // does not rebuild the box under the cursor.
      key: ValueKey('${widget.settingKey}_field'),
      controller: _text,
      focusNode: _focus,
      onChanged: _typed,
      onFieldSubmitted: (_) => _applyNow(),
      decoration: widget.decoration.copyWith(
        suffixIcon: _reading
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Tooltip(
                    message: 'Reading the folder...',
                    child: SizedBox(
                      key: ValueKey('settings_path_reading'),
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                  ?suffix,
                ],
              )
            : suffix,
      ),
    );
  }
}
