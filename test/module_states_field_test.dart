import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/schema_field_builder.dart';
import 'package:extron_configurator/ui_schema.dart';

/// A "module_states" field (a projector's `input`) must go red when the config
/// holds a state the selected module doesn't implement.
///
/// AJH125B is the case: key_map.json injects `input` = "HDBaseT" for every
/// PROJECTORDEVICE_*, but the PT-FW430U driver's SetInput only offers
/// Computer 1 / Computer 2 / Video / S-Video / DVI-I / Network / HDMI. The value
/// is left in place — the field flags it so the tech fixes it deliberately.
void main() {
  const String ptfw = 'modules.device.pana_vp_PTFW4xxEA_Series';
  // A real driver with no 'Input' command at all.
  const String noInput = 'modules.device.apc_other_AP79xxB_Series';

  // The field parses the .py file through the provider. Real file I/O can't
  // complete inside a testWidgets body (the pump owns the clock), so the schema
  // and the parsed-state caches are warmed HERE, in a normal async zone; the
  // widget then reads them straight out of the provider's cache.
  late AppStateProvider provider;

  setUpAll(() async {
    provider = AppStateProvider(autoLoadSettings: false)
      ..modulesPath = 'device'
      ..uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json');
    for (final module in const [ptfw, noInput]) {
      await provider.getStatesForModuleCommand(module, 'Input');
    }
  });

  /// Pumps just the `input` field of a projector carrying [input].
  Future<void> pumpInputField(WidgetTester tester, String input,
      {String module = ptfw}) async {
    provider.roomConfig = {
      'PROJECTORDEVICE_1': {
        'model': 'PT-FW430U',
        'module': module,
        'input': input,
      },
    };

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) =>
              SchemaFieldBuilder.buildField(
                context: context,
                provider: provider,
                sectionKey: 'PROJECTORDEVICE_1',
                fieldKey: 'input',
                value: input,
              ) ??
              const SizedBox.shrink(),
        ),
      ),
    ));
    // Lets the FutureBuilder's cached future resolve
    await tester.pump();
  }

  /// The decoration the TextFormField handed to its inner TextField (the form
  /// wrapper doesn't expose it).
  InputDecoration decorationOf(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).decoration!;

  /// The helper line currently under the field.
  String helperOf(WidgetTester tester) => decorationOf(tester).helperText ?? '';

  /// True when the field is decorated with the red mismatch styling.
  bool isRed(WidgetTester tester) {
    final border = decorationOf(tester).enabledBorder;
    return border is OutlineInputBorder &&
        border.borderSide.color == Colors.red.shade400;
  }

  testWidgets('goes red when the value is not a state of the module',
      (tester) async {
    await pumpInputField(tester, 'HDBaseT');

    expect(isRed(tester), isTrue);
    final helper = helperOf(tester);
    expect(helper, contains('HDBaseT'));
    expect(helper, contains('is not a'));
    // Points at both ways out: pick a supported state, or extend the module
    expect(helper, contains('add it to the module'));
  });

  testWidgets('stays normal for a state the module implements', (tester) async {
    await pumpInputField(tester, 'HDMI');

    expect(isRed(tester), isFalse);
    // Falls back to the informational helper
    expect(helperOf(tester), contains("states from 'Input'"));
  });

  testWidgets('an empty value is not a mismatch', (tester) async {
    await pumpInputField(tester, '');
    expect(isRed(tester), isFalse);
  });

  testWidgets('no module selected asks for one instead of going red',
      (tester) async {
    await pumpInputField(tester, 'HDBaseT', module: '');

    expect(isRed(tester), isFalse);
    expect(helperOf(tester), contains('Select a Python module first'));
  });

  testWidgets('a module with no such command explains itself, not red',
      (tester) async {
    // Nothing to check the value against, so the field reports the missing
    // command rather than calling the value wrong.
    await pumpInputField(tester, 'HDBaseT', module: noInput);

    expect(isRed(tester), isFalse);
    expect(helperOf(tester), contains('not found in'));
  });
}
