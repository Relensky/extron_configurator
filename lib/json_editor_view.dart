import 'contrast.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';

// --- CUSTOM CONTROLLER FOR SYNTAX HIGHLIGHTING (theme-aware) ---
class JsonSyntaxController extends TextEditingController {
  JsonSyntaxController({super.text});

  /// Updated by the view whenever the app theme changes
  bool isDark = true;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final List<TextSpan> lineSpans = [];
    final lines = text.split('\n');

    // Pick a syntax palette that stays readable on the active background
    final Color keyColor     = isDark ? Colors.lightBlueAccent : Colors.blue.shade800;
    final Color stringColor  = isDark ? Colors.greenAccent     : Colors.green.shade800;
    final Color numberColor  = isDark ? Colors.orangeAccent    : Colors.deepOrange.shade800;
    final Color booleanColor = isDark ? Colors.pinkAccent      : Colors.purple.shade700;
    final Color zebraColor   = isDark ? Colors.white.withValues(alpha: 0.03) : Colors.black.withValues(alpha: 0.03);

    // Regex to match JSON components
    final RegExp syntaxRegex = RegExp(
      r'(?<key>"[^"]+"\s*:)|(?<string>"[^"]+")|(?<number>-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|(?<boolean>\b(?:true|false|null)\b)',
    );

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final isEven = i % 2 == 0;
      
      // 1. Alternating background colors per line
      final lineStyle = style?.copyWith(
        backgroundColor: isEven ? zebraColor : Colors.transparent,
      ) ?? TextStyle(backgroundColor: isEven ? zebraColor : Colors.transparent);

      final List<TextSpan> syntaxSpans = [];
      int start = 0;

      // 2. Apply different colors based on the matched JSON type
      for (final match in syntaxRegex.allMatches(line)) {
        if (match.start > start) {
          syntaxSpans.add(TextSpan(text: line.substring(start, match.start), style: lineStyle));
        }

        TextStyle matchedStyle = lineStyle;
        if (match.namedGroup('key') != null) {
          matchedStyle = matchedStyle.copyWith(color: keyColor); // Keys
        } else if (match.namedGroup('string') != null) {
          matchedStyle = matchedStyle.copyWith(color: stringColor); // Strings
        } else if (match.namedGroup('number') != null) {
          matchedStyle = matchedStyle.copyWith(color: numberColor); // Numbers
        } else if (match.namedGroup('boolean') != null) {
          matchedStyle = matchedStyle.copyWith(color: booleanColor); // Booleans/Null
        }

        syntaxSpans.add(TextSpan(text: match.group(0), style: matchedStyle));
        start = match.end;
      }

      if (start < line.length) {
        syntaxSpans.add(TextSpan(text: line.substring(start), style: lineStyle));
      }

      // Add the newline character back (except for the very last line)
      if (i < lines.length - 1) {
        syntaxSpans.add(TextSpan(text: '\n', style: lineStyle));
      }

      lineSpans.add(TextSpan(children: syntaxSpans));
    }

    return TextSpan(children: lineSpans, style: style);
  }
}

// --- UPDATED VIEW ---
class JsonEditorView extends StatefulWidget {
  const JsonEditorView({super.key});

  @override
  State<JsonEditorView> createState() => _JsonEditorViewState();
}

/// The Raw JSON tab has no Apply button: the toolbar's Save is what writes
/// config.json now, and it writes what is in MEMORY — so this editor has to
/// keep memory in step with the text by itself, or a save would quietly write
/// around whatever was typed here. Typing is committed on a short debounce,
/// when the field loses focus, when the tab is left, and (through
/// [AppStateProvider.pendingRawEditorCommit]) the instant Save is pressed.
/// Text that doesn't parse is never committed — the red banner stands and the
/// config keeps the last version that did parse.
class _JsonEditorViewState extends State<JsonEditorView> {
  late JsonSyntaxController _controller;
  final FocusNode _focusNode = FocusNode();
  String _errorMessage = '';
  String _lastKnownStateString = ''; // Tracks state to prevent overriding active typing

  /// Long enough that a commit doesn't run on every keystroke (each one
  /// re-parses the config and re-warms the module caches), short enough that
  /// it has normally already happened by the time a hand reaches the toolbar.
  static const Duration _commitDelay = Duration(milliseconds: 400);
  Timer? _commitTimer;

  /// Typed text not yet applied to the config; null when the two agree.
  String? _pendingText;

  /// Captured here so a commit can still be flushed while the widget is being
  /// torn down (switching tabs), where the InheritedWidget is out of reach.
  AppStateProvider? _provider;

  @override
  void initState() {
    super.initState();
    _controller = JsonSyntaxController();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.watch<AppStateProvider>();
    _provider = provider;
    // Let Save flush this editor before it writes, so pressing it inside the
    // debounce window can't save the pre-edit config.
    provider.pendingRawEditorCommit = _commitNow;
    final newStateString = provider.getPrettyConfigString();

    // Adopt a change made ELSEWHERE (another tab, a load) — but never on top
    // of active typing: the pretty form is sorted and pruned, so pushing it
    // back mid-edit would reformat the text out from under the caret.
    if (_lastKnownStateString != newStateString &&
        _pendingText == null &&
        !_focusNode.hasFocus) {
      _controller.text = newStateString;
      _lastKnownStateString = newStateString;
    }
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) _commitNow();
  }

  /// Queues [text] to be applied once typing pauses.
  void _scheduleCommit(String text) {
    final bool wasIdle = _pendingText == null;
    _pendingText = text;
    _commitTimer?.cancel();
    _commitTimer = Timer(_commitDelay, _commitNow);
    if (wasIdle) setState(() {}); // Header flips to "unapplied edits"
  }

  /// Applies the pending text to the config now. A no-op when there is
  /// nothing pending, so Save and the focus listener can both call it freely.
  void _commitNow() {
    _commitTimer?.cancel();
    _commitTimer = null;
    final String? text = _pendingText;
    final AppStateProvider? provider = _provider;
    if (text == null || provider == null) return;
    _pendingText = null;

    try {
      provider.updateConfigFromRawJson(text);
      if (!mounted) return;
      setState(() {
        _errorMessage = '';
        // Baseline = what the config now prints as, so the sync above leaves
        // the user's own formatting alone until something else changes it.
        _lastKnownStateString = provider.getPrettyConfigString();
      });
    } catch (e) {
      // Half-typed JSON is the normal case here, not an error worth shouting
      // about: the banner shows it and the config keeps its last good state.
      if (!mounted) return;
      setState(() => _errorMessage = e.toString());
    }
  }

  @override
  void dispose() {
    _commitTimer?.cancel();
    _focusNode.removeListener(_onFocusChange);
    // Leaving the tab mid-debounce: apply the edit after this frame rather
    // than notify the provider in the middle of the teardown that got us here.
    final String? text = _pendingText;
    final AppStateProvider? provider = _provider;
    if (provider != null) {
      if (identical(provider.pendingRawEditorCommit, _commitNow)) {
        provider.pendingRawEditorCommit = null;
      }
      if (text != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            provider.updateConfigFromRawJson(text);
          } catch (_) {
            // Unparseable text is dropped, exactly as it would have been by
            // pressing Apply on it.
          }
        });
      }
    }
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Follow the app theme: dark editor in dark mode, paper-white in light mode
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    _controller.isDark = isDark;
    final Color editorFill = isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF7F7F7);
    final Color editorText = isDark ? Colors.white70 : Colors.black87;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Raw Config.json Editor', style: Theme.of(context).textTheme.headlineSmall),
              // Where the text stands relative to the config, since there is
              // no longer a button to press for the answer.
              // THREE CHANNELS, not one. The icon says which state this is,
              // the sentence says it in words, and the color only reinforces
              // them — so it reads the same to somebody who cannot tell the
              // green from the red.
              //
              // The colors themselves are measured rather than named: plain
              // Colors.green is 2.8:1 on a light surface and Colors.orange is
              // 2.0:1, both under the 3:1 an icon needs to be seen at all.
              Builder(builder: (context) {
                final theme = Theme.of(context);
                final surface = theme.colorScheme.surface;
                final (IconData icon, Color tint, String label) =
                    _pendingText != null
                        ? (
                            Icons.edit,
                            warningOn(surface),
                            'Applying edits…',
                          )
                        : _errorMessage.isEmpty
                            ? (
                                Icons.check_circle_outline,
                                successOn(surface),
                                'Applied to the loaded config',
                              )
                            : (
                                Icons.error_outline,
                                readableOn(
                                  surface,
                                  prefer: [theme.colorScheme.error],
                                ),
                                'Not applied - invalid JSON',
                              );
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18, color: tint),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(color: tint),
                    ),
                  ],
                );
              }),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Edits here are applied to the temporary loaded config as you type - press '
            'Save in the toolbar to write them to the local config file.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 16),
          if (_errorMessage.isNotEmpty)
            Builder(builder: (context) {
              // A themed pair rather than a fixed dark red under fixed white:
              // the scheme guarantees these two read together, and on the
              // light themes the old pairing put white on a red the rest of
              // the page had no relationship with.
              final scheme = Theme.of(context).colorScheme;
              return Container(
                padding: const EdgeInsets.all(12),
                color: scheme.errorContainer,
                child: Text(
                  'Invalid JSON: $_errorMessage',
                  style: TextStyle(
                    color: errorOn(scheme, scheme.errorContainer),
                  ),
                ),
              );
            }),
          const SizedBox(height: 8),
          Expanded(
            // TAB = INDENT (like VS Code): intercept the Tab key before the
            // focus system moves to the next widget and insert four spaces at
            // the caret instead (matching the file's indent width). Shift+Tab
            // is left alone so keyboard users can still leave the editor.
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.tab &&
                    !HardwareKeyboard.instance.isShiftPressed) {
                  const String indent = '    ';
                  final sel = _controller.selection;
                  if (!sel.isValid) return KeyEventResult.ignored;
                  final text = _controller.text;
                  final indented = text.replaceRange(sel.start, sel.end, indent);
                  _controller.value = TextEditingValue(
                    text: indented,
                    selection: TextSelection.collapsed(
                        offset: sel.start + indent.length),
                  );
                  // Writing the controller directly bypasses onChanged, so
                  // queue the commit here too — otherwise a Tab-indented edit
                  // would sit in the field unapplied.
                  _scheduleCommit(indented);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                onChanged: _scheduleCommit,
                maxLines: null,
                expands: true,
                keyboardType: TextInputType.multiline,
                // Background & text adapt to light/dark mode; syntax colors follow
                style: TextStyle(fontFamily: 'monospace', fontSize: 14, color: editorText),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: editorFill,
                  // Filled fields get a Material hover overlay that shifts the
                  // editor background on mouse-over — disable it entirely.
                  hoverColor: Colors.transparent,
                  border: const OutlineInputBorder(),
                  hintText: 'Paste or edit your config.json here...',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}