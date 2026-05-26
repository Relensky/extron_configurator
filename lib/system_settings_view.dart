import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';
import 'config_dictionary.dart';

class SystemSettingsView extends StatelessWidget {
  const SystemSettingsView({Key? key}) : super(key: key);

  Widget _wrapWithInfo(BuildContext context, String key, Widget field) {
    final desc = ConfigDictionary.descriptions[key];
    if (desc == null) return field;
    
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: field),
        IconButton(
          icon: const Icon(Icons.info_outline, color: Colors.blueAccent),
          tooltip: desc,
          onPressed: () {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(key),
                content: Text(desc),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
              )
            );
          },
        )
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final systemSetup = provider.roomConfig['SYSTEM_SETUP'] as Map<String, dynamic>?;

    if (systemSetup == null || systemSetup.isEmpty) {
      return const Center(child: Text("No SYSTEM_SETUP found in the current config."));
    }

    // Filter out the 'dev_' hardware counts because they belong in the Setup Wizard
    final List<String> configKeys = systemSetup.keys.where((k) => !k.startsWith('dev_')).toList();
    configKeys.sort(); // Sort alphabetically for easier navigation

    return ListView.builder(
      padding: const EdgeInsets.all(32.0),
      itemCount: configKeys.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 20.0),
            child: Text('System Settings', style: Theme.of(context).textTheme.headlineMedium),
          );
        }

        final key = configKeys[index - 1];
        final value = systemSetup[key];

        Widget field;
        if (value is bool) {
          field = SwitchListTile(
            title: Text(key),
            value: value,
            onChanged: (val) => provider.updateDeviceValue('SYSTEM_SETUP', key, val),
          );
        } else {
          field = TextFormField(
            initialValue: value?.toString() ?? '',
            decoration: InputDecoration(labelText: key, border: const OutlineInputBorder()),
            onChanged: (val) {
              dynamic parsedVal = val;
              if (value is int) parsedVal = int.tryParse(val) ?? 0;
              provider.updateDeviceValue('SYSTEM_SETUP', key, parsedVal);
            },
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: _wrapWithInfo(context, key, field),
        );
      },
    );
  }
}