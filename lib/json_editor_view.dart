import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';

// --- CUSTOM CONTROLLER FOR SYNTAX HIGHLIGHTING ---
class JsonSyntaxController extends TextEditingController {
  JsonSyntaxController({String? text}) : super(text: text);

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final List<TextSpan> lineSpans = [];
    final lines = text.split('\n');

    // Regex to match JSON components
    final RegExp syntaxRegex = RegExp(
      r'(?<key>"[^"]+"\s*:)|(?<string>"[^"]+")|(?<number>-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|(?<boolean>\b(?:true|false|null)\b)',
    );

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final isEven = i % 2 == 0;
      
      // 1. Alternating background colors per line
      final lineStyle = style?.copyWith(
        backgroundColor: isEven ? Colors.white.withOpacity(0.03) : Colors.transparent,
      ) ?? TextStyle(backgroundColor: isEven ? Colors.white.withOpacity(0.03) : Colors.transparent);

      final List<TextSpan> syntaxSpans = [];
      int start = 0;

      // 2. Apply different colors based on the matched JSON type
      for (final match in syntaxRegex.allMatches(line)) {
        if (match.start > start) {
          syntaxSpans.add(TextSpan(text: line.substring(start, match.start), style: lineStyle));
        }

        TextStyle matchedStyle = lineStyle;
        if (match.namedGroup('key') != null) {
          matchedStyle = matchedStyle.copyWith(color: Colors.lightBlueAccent); // Keys
        } else if (match.namedGroup('string') != null) {
          matchedStyle = matchedStyle.copyWith(color: Colors.greenAccent); // Strings
        } else if (match.namedGroup('number') != null) {
          matchedStyle = matchedStyle.copyWith(color: Colors.orangeAccent); // Numbers
        } else if (match.namedGroup('boolean') != null) {
          matchedStyle = matchedStyle.copyWith(color: Colors.pinkAccent); // Booleans/Null
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

  void _applyJson() {
    final provider = context.read<AppStateProvider>();
    try {
      provider.updateConfigFromRawJson(_controller.text);
      setState(() {
        _errorMessage = '';
        _lastKnownStateString = provider.getPrettyConfigString(); // Sync baseline
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('JSON Config successfully applied to memory.'), backgroundColor: Colors.green),
      );
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
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
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700),
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
              // Dark background to let the syntax colors pop
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14, color: Colors.white70),
              decoration: const InputDecoration(
                filled: true,
                fillColor: Color(0xFF1E1E1E), // Similar to VS Code standard dark
                border: OutlineInputBorder(),
                hintText: 'Paste or edit your config.json here...',
              ),
            ),
          ),
        ],
      ),
    );
  }
}