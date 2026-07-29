import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/ui_schema.dart';

/// Covers the two schema features behind the VGA-over-USB reporting:
///   * "labelWhen" — input_usb reads "VGA over USB" only in a VGA room
///   * "consistency" — gui_tab_type's USB/VGA source and gui_usb_or_vga are
///     flagged when they disagree, and silent when they don't
///
/// Both are exercised against the BUILT-IN schema and against the real
/// ui_schema.json, so the shipped file staying in step with the code is part
/// of the test rather than something to remember.
void main() {
  UiSchema fromFile() {
    final doc = jsonDecode(File('ui_schema.json').readAsStringSync());
    final schema = UiSchema.builtIn();
    schema.applyJsonMap(doc as Map<String, dynamic>);
    return schema;
  }

  final schemas = <String, UiSchema Function()>{
    'built-in': UiSchema.builtIn,
    'ui_schema.json': fromFile,
  };

  schemas.forEach((name, build) {
    group('input_usb labelWhen ($name)', () {
      test('reads "VGA over USB" when the room is set to VGA', () {
        expect(build().labelFor('input_usb', {'gui_usb_or_vga': 'VGA'}),
            'VGA over USB');
      });

      test('is case-insensitive on the condition value', () {
        expect(build().labelFor('input_usb', {'gui_usb_or_vga': 'vga'}),
            'VGA over USB');
      });

      test('falls back to no schema label in a USB room', () {
        // Null lets the report apply its own acronym casing ("USB") and the
        // editor fall back to the raw key, exactly as before the change.
        expect(build().labelFor('input_usb', {'gui_usb_or_vga': 'USB'}), isNull);
        expect(build().labelFor('input_usb', const {}), isNull);
      });

      test('leaves the other inputs alone', () {
        final schema = build();
        for (final key in const ['input_hdmi', 'input_pc', 'input_doc_cam']) {
          expect(schema.labelFor(key, {'gui_usb_or_vga': 'VGA'}), isNull,
              reason: '$key must not pick up a VGA label');
        }
      });
    });

    group('gui_usb_or_vga consistency ($name)', () {
      String? check(UiSchema schema, String field, Map<String, dynamic> setup) =>
          schema.consistencyMessageFor(field, 'SYSTEM_SETUP', setup);

      test('flags a VGA source list against a USB transport', () {
        final schema = build();
        const setup = {'gui_tab_type': 'DOC_VGA_WL', 'gui_usb_or_vga': 'USB'};
        final message = check(schema, 'gui_usb_or_vga', setup);
        expect(message, isNotNull);
        // The live values are interpolated into the helper line
        expect(message, contains('DOC_VGA_WL'));
        expect(message, contains('VGA'));
        // Flagged from the sources side too, not just on gui_usb_or_vga
        expect(check(schema, 'gui_inputs', setup), isNotNull);
      });

      test('flags a USB source list against a VGA transport', () {
        final schema = build();
        const setup = {'gui_tab_type': 'BR_DOC_USB_WL', 'gui_usb_or_vga': 'VGA'};
        expect(check(schema, 'gui_usb_or_vga', setup), isNotNull);
        expect(check(schema, 'gui_inputs', setup), isNotNull);
      });

      test('stays silent when the two agree', () {
        final schema = build();
        for (final setup in const [
          {'gui_tab_type': 'DOC_VGA_WL', 'gui_usb_or_vga': 'VGA'},
          {'gui_tab_type': 'BR_DOC_USB_WL', 'gui_usb_or_vga': 'USB'},
          {'gui_tab_type': '4_DVD_USB', 'gui_usb_or_vga': 'USB'},
        ]) {
          expect(check(schema, 'gui_usb_or_vga', setup), isNull,
              reason: 'agreeing values must not be flagged: $setup');
          expect(check(schema, 'gui_inputs', setup), isNull);
        }
      });

      test('never fires for tab types that name neither USB nor VGA', () {
        final schema = build();
        // The Wireless-only options pin no source transport, so gui_usb_or_vga
        // is free either way — the reason the two keys were left unfolded.
        for (final tabType in const ['WL', 'DOC_WL']) {
          for (final transport in const ['USB', 'VGA']) {
            final setup = {
              'gui_tab_type': tabType,
              'gui_usb_or_vga': transport,
            };
            expect(check(schema, 'gui_usb_or_vga', setup), isNull,
                reason: '$tabType / $transport must not be flagged');
          }
        }
      });

      test('does not flag unrelated fields', () {
        final schema = build();
        expect(
            check(schema, 'gui_mic_mix',
                {'gui_tab_type': 'DOC_VGA_WL', 'gui_usb_or_vga': 'USB'}),
            isNull);
      });

      test('a missing gui_tab_type fires nothing', () {
        final schema = build();
        expect(check(schema, 'gui_usb_or_vga', {'gui_usb_or_vga': 'USB'}),
            isNull);
      });
    });
  });

  test('ui_schema.json keeps its consistency rules', () {
    // Guards the "defining any entries REPLACES the built-in list" rule: an
    // empty/omitted array in the file would silently fall back to the built-in
    // set, an edit that deletes them would not.
    expect(fromFile().consistencyRules, hasLength(2));
  });
}
