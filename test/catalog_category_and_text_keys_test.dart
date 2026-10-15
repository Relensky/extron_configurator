import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/catalog_category_prompt.dart';
import 'package:extron_configurator/keyboard_shortcuts.dart';

/// A catalog save asks for a missing category and says what each one limits
/// an entry to; the text-box keys are the ones App Config says.
void main() {
  group('categoryLimits', () {
    test('says where each kind of category is offered', () {
      expect(categoryLimits(''), contains('No category'));
      expect(categoryLimits('Switcher'), contains('Switcher base cost'));
      expect(categoryLimits('Cable'), contains('Add cable'));
      expect(categoryLimits('Vent plate'), contains('rack'));
      expect(categoryLimits('AV / Misc', hasPorts: false),
          contains('only in Other items'));
      expect(categoryLimits('AV / Misc'), contains('treated as equipment'));
      expect(categoryLimits('Fox Systems'), contains('Not a category'));
    });
  });

  group('the missing-category prompt', () {
    Future<(AppStateProvider, Future<bool>)> open(WidgetTester tester) async {
      final p = AppStateProvider(autoLoadSettings: false);
      p.avDeviceLibrary.upsert(const AvDeviceTemplate(
        model: 'DTP HDMI 4K 330 Tx',
        partNumber: '60-1331-12',
        custom: true,
        ports: [],
      ));
      late Future<bool> result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = confirmCatalogCategories(context, p),
            child: const Text('save'),
          ),
        ),
      ));
      await tester.tap(find.text('save'));
      await tester.pumpAndSettle();
      return (p, result);
    }

    testWidgets('a picked category goes on the entry', (tester) async {
      final (p, result) = await open(tester);
      expect(find.text('DTP HDMI 4K 330 Tx has no category'), findsOneWidget);
      await tester.tap(
          find.byKey(const ValueKey('missing_category_pick_DTP HDMI 4K 330 Tx')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Switcher').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Switcher base cost'),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('missing_category_save')));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(
        p.avDeviceLibrary.templateForModel('DTP HDMI 4K 330 Tx')?.category,
        'Switcher',
      );
    });

    testWidgets('save without leaves it blank; cancel stops the save',
        (tester) async {
      var (p, result) = await open(tester);
      await tester.tap(find.byKey(const ValueKey('missing_category_skip')));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(
          p.avDeviceLibrary.templateForModel('DTP HDMI 4K 330 Tx')?.category,
          '');

      (p, result) = await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });
  });

  group('text-box keys', () {
    late FocusNode secondFocus;
    Future<TextEditingController> pump(
      WidgetTester tester,
      KeyboardShortcuts keys, {
      bool selectable = false,
    }) async {
      final c = TextEditingController(text: 'one\ntwo\nthree');
      secondFocus = FocusNode();
      addTearDown(secondFocus.dispose);
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => Shortcuts(
          shortcuts: textBoxShortcuts(keys),
          child: Actions(actions: textBoxActions, child: child!),
        ),
        home: Scaffold(
          body: Builder(builder: (context) {
            final fields = Column(children: [
              TextField(controller: c, maxLines: 4, autofocus: true),
              TextField(key: const ValueKey('second'), focusNode: secondFocus),
            ]);
            // The Cost page's text can all be selected; Flutter's own line
            // keys broke in there.
            return selectable ? SelectionArea(child: fields) : fields;
          }),
        ),
      ));
      await tester.pumpAndSettle();
      c.selection = const TextSelection.collapsed(offset: 5); // in "two"
      await tester.pump();
      return c;
    }

    testWidgets('Home and End go to the top and bottom of the box',
        (tester) async {
      final c = await pump(tester, const KeyboardShortcuts());
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(c.selection.baseOffset, c.text.length);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(c.selection.baseOffset, 0);
    });

    testWidgets('Up and Down move a line', (tester) async {
      final c = await pump(tester, const KeyboardShortcuts());
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(c.selection.baseOffset, greaterThan(7)); // on "three"
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(c.selection.baseOffset, lessThan(4)); // on "one"
    });

    testWidgets('Up and Down work inside a SelectionArea, as on Cost',
        (tester) async {
      final c = await pump(tester, const KeyboardShortcuts(), selectable: true);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(c.selection.baseOffset, lessThan(4)); // on "one"
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(c.selection.baseOffset, greaterThan(7)); // on "three"
    });

    testWidgets('Up in a one-line box goes to the start', (tester) async {
      await pump(tester, const KeyboardShortcuts());
      final second = TextEditingController(text: 'hello');
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => Shortcuts(
          shortcuts: textBoxShortcuts(const KeyboardShortcuts()),
          child: Actions(actions: textBoxActions, child: child!),
        ),
        home: Scaffold(
          body: TextField(controller: second, autofocus: true),
        ),
      ));
      await tester.pumpAndSettle();
      second.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(second.selection.baseOffset, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(second.selection.baseOffset, 5);
    });

    testWidgets('Tab moves to the next box', (tester) async {
      await pump(tester, const KeyboardShortcuts());
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(secondFocus.hasPrimaryFocus, isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(secondFocus.hasPrimaryFocus, isFalse);
    });

    testWidgets('a changed key changes it', (tester) async {
      final keys = const KeyboardShortcuts()
          .withBindings(Shortcut.textBottom, [const KeyBinding(LogicalKeyboardKey.f2)]);
      final c = await pump(tester, keys);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(c.selection.baseOffset, c.text.length);
    });

    test('text keys never clash with the drawings\' arrow keys', () {
      const keys = KeyboardShortcuts();
      expect(
        keys.clashWith(
            Shortcut.lineUp, const KeyBinding(LogicalKeyboardKey.arrowUp)),
        isNull,
      );
      expect(
        keys.clashWith(
            Shortcut.moveUp, const KeyBinding(LogicalKeyboardKey.arrowUp)),
        isNull,
      );
      // An app-wide key still clashes.
      expect(
        keys.clashWith(Shortcut.textTop,
            const KeyBinding(LogicalKeyboardKey.keyS, control: true))?.id,
        Shortcut.save,
      );
    });
  });
}
