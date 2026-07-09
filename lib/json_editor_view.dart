import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';

// --- CUSTOM CONTROLLER FOR SYNTAX HIGHLIGHTING (theme-aware) ---
class JsonSyntaxController extends TextEditingController {
  JsonSyntaxController({String? text}) : super(text: text);

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
    final Color zebraColor   = isDark ? Colors.white.withOpacity(0.03) : Colors.black.withOpacity(0.03);

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
  const JsonEditorView({Key? key}) : super(key: key);

  @override
  State<JsonEditorView> createState() => _JsonEditorViewState();
}

class _JsonEditorViewState extends State<JsonEditorView> {
  late JsonSyntaxController _controller;
  String _errorMessage = '';
  String _lastKnownStateString = ''; // Tracks state to prevent overriding active typing

  @override
  void initState() {
    super.initState();
    _controller = JsonSyntaxController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.watch<AppStateProvider>();
    final newStateString = provider.getPrettyConfigString();
    
    // If the state was changed on another tab, update the text editor
    if (_lastKnownStateString != newStateString) {
      _controller.text = newStateString;
      _lastKnownStateString = newStateString;
    }
  }

  Future<void> _applyJson() async {
    final provider = context.read<AppStateProvider>();
    try {
      provider.updateConfigFromRawJson(_controller.text);

      // Also write straight to the working file (the file that was opened or
      // the working copy chosen during an SFTP download), so Apply = save.
      String? savedPath;
      String saveNote = '';
      try {
        savedPath = await provider.saveCurrentConfigToFile();
        saveNote = savedPath != null
            ? ' Saved to ${savedPath.split(Platform.pathSeparator).last}.'
            : ' No working file loaded — use Export to save to disk.';
      } catch (e) {
        saveNote = ' WARNING: could not write working file ($e).';
      }

      if (!mounted) return;
      setState(() {
        _errorMessage = '';
        _lastKnownStateString = provider.getPrettyConfigString(); // Sync baseline
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('JSON Config applied to memory.$saveNote'),
          backgroundColor:
              saveNote.startsWith(' WARNING') ? Colors.orange.shade800 : Colors.green,
        ),
      );
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    }
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
              ElevatedButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Apply Changes'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade700,
                  foregroundColor: Colors.white, // Force readable text in light mode
                ),
                onPressed: _applyJson,
              )
            ],
          ),
          const SizedBox(height: 16),
          if (_errorMessage.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.red.shade900,
              child: Text("Invalid JSON: $_errorMessage", style: const TextStyle(color: Colors.white)),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _controller,
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
        ],
      ),
    );
  }
}