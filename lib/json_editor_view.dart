import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';

class JsonEditorView extends StatefulWidget {
  const JsonEditorView({Key? key}) : super(key: key);

  @override
  State<JsonEditorView> createState() => _JsonEditorViewState();
}

class _JsonEditorViewState extends State<JsonEditorView> {
  late TextEditingController _controller;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    // Load initial JSON string from state
    final provider = context.read<AppStateProvider>();
    _controller = TextEditingController(text: provider.getPrettyConfigString());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _applyJson() {
    final provider = context.read<AppStateProvider>();
    try {
      provider.updateConfigFromRawJson(_controller.text);
      setState(() => _errorMessage = '');
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
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.black12,
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