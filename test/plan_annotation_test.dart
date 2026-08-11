import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/plan_annotations.dart';
import 'package:extron_configurator/room_locations.dart';

/// A callout says "this spot is that thing". Notation says everything else a
/// drawing has to say and a marker cannot — which way the cable leaves, which
/// corner is out of scope, "core drill here".
void main() {
  PlanAnnotation note({
    String id = 'NOTE_1',
    PlanShape shape = PlanShape.arrow,
    Offset start = const Offset(100, 100),
    Offset end = const Offset(200, 100),
  }) => PlanAnnotation(id: id, shape: shape, start: start, end: end);

  group('shape maths', () {
    test('an arrow is grabbed anywhere along it, not just at the ends', () {
      final a = note();
      expect(annotationHit(a, const Offset(150, 100)), isTrue);
      expect(annotationHit(a, const Offset(150, 104)), isTrue);
      expect(annotationHit(a, const Offset(150, 140)), isFalse);
      // Past either end is a miss, however close to the line it is.
      expect(annotationHit(a, const Offset(400, 100)), isFalse);
    });

    test('a box is grabbed by its edge, not its middle', () {
      // Filled hit areas would make the markers a box was drawn AROUND
      // unclickable, which defeats the point of drawing it.
      final b = note(
        shape: PlanShape.rectangle,
        start: const Offset(100, 100),
        end: const Offset(300, 200),
      );
      expect(annotationHit(b, const Offset(100, 150)), isTrue);
      expect(annotationHit(b, const Offset(200, 100)), isTrue);
      expect(annotationHit(b, const Offset(200, 150)), isFalse);
    });

    test('a text block is grabbed anywhere inside it', () {
      final t = note(
        shape: PlanShape.text,
        start: const Offset(100, 100),
        end: const Offset(300, 160),
      );
      expect(annotationHit(t, const Offset(200, 130)), isTrue);
    });

    test('the topmost shape wins, the way the eye reads it', () {
      final under = note(id: 'A');
      final over = note(id: 'B');
      expect(annotationAt([under, over], const Offset(150, 100))?.id, 'B');
      expect(annotationAt([under, over], const Offset(0, 0)), isNull);
    });

    test('the ends grab before the body does', () {
      final a = note();
      expect(gripAt(a, const Offset(100, 100)), AnnotationGrip.start);
      expect(gripAt(a, const Offset(200, 100)), AnnotationGrip.end);
      expect(gripAt(a, const Offset(150, 100)), AnnotationGrip.body);
      expect(gripAt(a, const Offset(150, 300)), AnnotationGrip.none);
    });

    test('dragging an end moves that end; dragging the body moves both', () {
      final a = note();
      const delta = Offset(10, 5);

      final byEnd = dragAnnotation(a, AnnotationGrip.end, delta);
      expect(byEnd.start, a.start);
      expect(byEnd.end, a.end + delta);

      final byBody = dragAnnotation(a, AnnotationGrip.body, delta);
      expect(byBody.start, a.start + delta);
      expect(byBody.end, a.end + delta);

      expect(dragAnnotation(a, AnnotationGrip.none, delta).start, a.start);
    });

    test('a click rather than a drag draws nothing — except text', () {
      const at = Offset(50, 50);
      expect(note(start: at, end: at).isDegenerate, isTrue);
      expect(
        note(shape: PlanShape.text, start: at, end: at).isDegenerate,
        isFalse,
        reason: 'a text block sizes itself to what gets typed',
      );
    });

    test('bounds do not care which corner was dragged from', () {
      final a = note(start: const Offset(300, 200), end: const Offset(100, 100));
      expect(a.bounds, const Rect.fromLTRB(100, 100, 300, 200));
    });
  });

  group('notation on a sheet', () {
    AppStateProvider room() => AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };

    test('is added to the sheet it was drawn on, and only that one', () {
      final p = room();
      final one = p.addFloorPlanSheet(name: 'Level 1');
      final two = p.addFloorPlanSheet(name: 'Level 2');

      p.addAvAnnotation(one.id, note(id: ''));
      expect(p.avFloorPlanById(one.id)!.annotations.length, 1);
      // An arrow saying which way the conduit leaves would be nonsense on the
      // reflected ceiling plan.
      expect(p.avFloorPlanById(two.id)!.annotations, isEmpty);
    });

    test('ids do not collide across sheets', () {
      final p = room();
      final one = p.addFloorPlanSheet(name: 'Level 1');
      final two = p.addFloorPlanSheet(name: 'Level 2');

      final a = p.addAvAnnotation(one.id, note(id: ''))!;
      final b = p.addAvAnnotation(two.id, note(id: ''))!;
      expect(a.id, isNot(b.id));
    });

    test('edits and deletes reach the right one', () {
      final p = room();
      final sheet = p.addFloorPlanSheet(name: 'Level 1');
      final a = p.addAvAnnotation(sheet.id, note(id: ''))!;
      final b = p.addAvAnnotation(sheet.id, note(id: ''))!;

      p.updateAvAnnotation(sheet.id, a.copyWith(text: 'Core drill here'));
      expect(
        p.avFloorPlanById(sheet.id)!.annotations
            .firstWhere((n) => n.id == a.id)
            .text,
        'Core drill here',
      );

      p.removeAvAnnotation(sheet.id, a.id);
      expect(p.avFloorPlanById(sheet.id)!.annotations.single.id, b.id);
    });

    test('duplicating a sheet carries its notation', () {
      final p = room();
      final source = p.addFloorPlanSheet(name: 'Level 1');
      p.addAvAnnotation(source.id, note(id: '', shape: PlanShape.rectangle));

      final copy = p.duplicateFloorPlanSheet(source.id)!;
      expect(copy.annotations.single.shape, PlanShape.rectangle);
    });

    test('round trips through the floor plan file with its sheet', () async {
      final dir = Directory.systemTemp.createTempSync('plan_annotation_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final configPath = path.join(dir.path, 'BSS103_config.json');
      File(configPath).writeAsStringSync('{}');

      final p = room()..currentConfigPath = configPath;
      final sheet = p.addFloorPlanSheet(name: 'Level 1');
      p.addAvAnnotation(
        sheet.id,
        const PlanAnnotation(
          id: '',
          shape: PlanShape.arrow,
          start: Offset(10, 20),
          end: Offset(120, 60),
          text: 'Conduit up to ceiling',
          color: 0xFF1E88E5,
          strokeWidth: 5,
        ),
      );
      await p.saveAvFlow();

      final back = AppStateProvider(autoLoadSettings: false)
        ..currentConfigPath = configPath
        ..loadAvFlowForCurrentConfig();
      final restored = back.avFloorPlans.single.annotations.single;
      expect(restored.shape, PlanShape.arrow);
      expect(restored.start, const Offset(10, 20));
      expect(restored.end, const Offset(120, 60));
      expect(restored.text, 'Conduit up to ceiling');
      expect(restored.color, 0xFF1E88E5);
      expect(restored.strokeWidth, 5);
    });

    test('a new note after a reload does not reuse a saved id', () async {
      final dir = Directory.systemTemp.createTempSync('plan_annotation_ids_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final configPath = path.join(dir.path, 'BSS103_config.json');
      File(configPath).writeAsStringSync('{}');

      final p = room()..currentConfigPath = configPath;
      final sheet = p.addFloorPlanSheet(name: 'Level 1');
      p.addAvAnnotation(sheet.id, note(id: ''));
      p.addAvAnnotation(sheet.id, note(id: ''));
      await p.saveAvFlow();

      final back = AppStateProvider(autoLoadSettings: false)
        ..currentConfigPath = configPath
        ..loadAvFlowForCurrentConfig();
      final existing =
          back.avFloorPlans.single.annotations.map((a) => a.id).toSet();
      final fresh = back.addAvAnnotation(
        back.avFloorPlans.single.id,
        note(id: ''),
      )!;
      expect(existing.contains(fresh.id), isFalse);
    });

    test('a sheet saved before notation existed still reads', () {
      // No 'annotations' key at all, which is every plan on disk today.
      final plan = FloorPlan.fromJson({
        'id': 'PLAN_1',
        'name': 'Level 1',
        'callouts': [],
      });
      expect(plan.annotations, isEmpty);
      // And writing it back adds no noise.
      expect(plan.toJson().containsKey('annotations'), isFalse);
    });
  });
}
