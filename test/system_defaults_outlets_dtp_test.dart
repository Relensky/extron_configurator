import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/schema_field_builder.dart';
import 'package:extron_configurator/ui_schema.dart';

/// Two system defaults: every APC outlet in the new-room template supports
/// reboot, and a blank dtp_power_toggle_1 reads as "(none - no button)"
/// rather than as an empty box.
void main() {
  test('every outlet in the new-room template supports reboot', () {
    final config =
        jsonDecode(File('config.json').readAsStringSync()) as Map<String, dynamic>;
    final flags = <String, dynamic>{};
    void walk(Object? node) {
      if (node is Map) {
        node.forEach((k, v) {
          if (RegExp(r'^power1_outlet_\d+_supports_reboot$').hasMatch('$k')) {
            flags['$k'] = v;
          }
          walk(v);
        });
      }
    }

    walk(config);
    expect(flags, hasLength(8));
    expect(flags.values, everyElement(isTrue));
  });

  testWidgets('a blank dtp_power_toggle_1 shows "(none - no button)"',
      (tester) async {
    final schema = await tester.runAsync(
        () => UiSchema.load(explicitPath: 'ui_schema.json'));
    final provider = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema!
      ..roomConfig = {
        'SYSTEM_SETUP': {'dtp_power_toggle_1': ''},
      };
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) =>
                  SchemaFieldBuilder.buildField(
                    context: context,
                    provider: provider,
                    sectionKey: 'SYSTEM_SETUP',
                    fieldKey: 'dtp_power_toggle_1',
                    value: '',
                  ) ??
                  const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('(none - no button)'), findsOneWidget);
  });
}
