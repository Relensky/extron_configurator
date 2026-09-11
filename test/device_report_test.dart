import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/report_tools.dart';
import 'package:extron_configurator/schematic_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// The device report is read by people who did not build the room, so it spells
/// out what the tech-facing config keys mean: "output_proj_1" reports as
/// "Display Device 1" with the actual projector named beside it, and the
/// opt-in ENVIRONMENT block is called out when a room carries it.
void main() {
  /// The AJH125B room after conversion, trimmed to what the report reads.
  Map<String, dynamic> room() => {
        'SYSTEM_SETUP': {
          'gve_bldg': 'AJH',
          'gve_room': '125B',
          'gui_full_room_name': 'Aymer Jay Hamilton Building 125B',
          'processor1': 'MainProcessor',
          // One projector and one camera, so the SECOND of each is configured
          // in SYSTEM_SETUP but not active in the room.
          'dev_projectors': '1',
          'dev_cameras': '1',
          'dev_switchers': '1',
          'input_aud_cam': '8',
          'input_inst_cam': '7',
          'input_doc_cam': '5',
          'output_audio': '1',
          'output_audio_ald': '4',
          'output_cc': '2',
          'output_proj_1': 'C',
          'output_proj_2': '4',
        },
        'PROJECTORDEVICE_1': {
          'name': 'Projector - PT-FW430U',
          'model': 'PT-FW430U',
          'com_type': 'Serial',
          'serial_port': 'COM2',
        },
        'CAMERADEVICE_1': {
          'name': 'Camera - TR311',
          'model': 'TR311',
          'com_type': 'Serial',
          'serial_port': 'COM6',
        },
        'SWITCHERDEVICE_1': {
          'name': 'Switcher - IN1608 SA',
          'model': 'IN1608 SA',
          'com_type': 'Serial',
          'serial_port': 'COM1',
        },
      };

  /// The report sections for [config], built the way every export does.
  Future<List<ReportSection>> sectionsFor(Map<String, dynamic> config) async {
    final provider = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json')
      ..roomConfig = config;
    return reportSections(provider, SchematicModel.build(provider));
  }

  /// The rows of one titled section, as "cell | cell | cell" strings.
  Future<List<String>> rowsOf(
      Map<String, dynamic> config, String title) async {
    final section = (await sectionsFor(config))
        .firstWhere((s) => s.title == title, orElse: () => throw 'no $title');
    return section.rows.map((r) => r.join(' | ')).toList();
  }

  test('inputs report as plain English, with the device on the port', () async {
    final rows = await rowsOf(room(), 'Inputs');

    // The camera shorthand spelled out, and the camera named: CAMERADEVICE_1 is
    // the instructor camera by this project's convention (Lbl_InstCam_Model).
    expect(rows, contains('Instructor Camera | 7 | Camera - TR311'));
    // Aud maps to CAMERADEVICE_2, which this one-camera room doesn't have
    expect(rows, contains('Audience Camera | 8 | '));
    // A key with no rename keeps its existing spelling
    expect(rows, contains('Doc Cam | 5 | '));
    // ...and the shorthand is gone
    expect(rows.join('\n'), isNot(contains('AUD Cam')));
    expect(rows.join('\n'), isNot(contains('INST Cam')));
  });

  test('outputs report as plain English, with the device on the port', () async {
    final rows = await rowsOf(room(), 'Outputs');

    expect(rows, contains('Audio Output (Amplifier) | 1 | '));
    expect(rows, contains('Assisted Listening | 4 | '));
    expect(rows, contains('Capture Card | 2 | '));
    expect(rows, contains('Display Device 1 | C | Projector - PT-FW430U'));
    // output_proj_2 is configured but there is no second projector in the room,
    // so the Device cell stays blank rather than naming a block the report
    // otherwise excludes.
    expect(rows, contains('Display Device 2 | 4 | '));
    expect(rows.join('\n'), isNot(contains('Proj 1')));
  });

  test('the Device column matches the Devices table', () async {
    final sections = await sectionsFor(room());
    final devices = sections.firstWhere((s) => s.title == 'Devices');
    final names = devices.rows.map((r) => r.first.toString()).toSet();
    final outputs = sections.firstWhere((s) => s.title == 'Outputs');
    final referenced = outputs.rows
        .map((r) => r.last.toString())
        .where((n) => n.isNotEmpty)
        .toSet();
    expect(referenced, isNotEmpty);
    expect(names.containsAll(referenced), isTrue,
        reason: 'an I/O row named a device the Devices table does not list');
  });

  group('python tracebacks', () {
    test('no row at all when the room has no ENVIRONMENT block', () async {
      // The state a conversion now leaves the config in.
      final rows = await rowsOf(room(), 'System');
      expect(rows.join('\n'), isNot(contains('Python Tracebacks')));
    });

    test('reported as allowed when the room carries it', () async {
      final rows = await rowsOf(
          room()..['ENVIRONMENT'] = {'traceback_allowed': true}, 'System');
      expect(rows, contains('Python Tracebacks | Allowed'));
    });

    test('reported as not allowed rather than silently dropped', () async {
      final rows = await rowsOf(
          room()..['ENVIRONMENT'] = {'traceback_allowed': false}, 'System');
      expect(rows, contains('Python Tracebacks | Not allowed'));
    });
  });

  group('controlscript profile', () {
    test('reported for a converted room', () async {
      final rows = await rowsOf(
          room()..['ENVIRONMENT'] = {'controlscript_profile': 'pro'}, 'System');
      expect(rows, contains('ControlScript Profile | pro'));
    });

    test('an Xi room reports as xi', () async {
      final rows = await rowsOf(
          room()..['ENVIRONMENT'] = {'controlscript_profile': 'xi'}, 'System');
      expect(rows, contains('ControlScript Profile | xi'));
    });

    test('no row on a file that predates the key', () async {
      final rows = await rowsOf(
          room()..['ENVIRONMENT'] = {'traceback_allowed': true}, 'System');
      expect(rows.join('\n'), isNot(contains('ControlScript Profile')));
    });
  });

  group('the transition timers', () {
    /// [room] with [extra] merged into one of its blocks. The literals in
    /// room() are all strings, so the block has to be rebuilt to take the
    /// numbers a timer is actually stored as.
    Map<String, dynamic> withKeys(
      Map<String, dynamic> config,
      String section,
      Map<String, dynamic> extra,
    ) {
      config[section] = <String, dynamic>{
        ...(config[section] as Map).cast<String, dynamic>(),
        ...extra,
      };
      return config;
    }

    /// The timers a room would actually correct: a tired lamp projector that
    /// needs longer than its driver claims, and a camera whose cool-down is
    /// the only one worth changing.
    Map<String, dynamic> timed() {
      var config = room();
      config = withKeys(config, 'PROJECTORDEVICE_1',
          {'warm_up_time': 45, 'cool_down_time': 12});
      config = withKeys(config, 'CAMERADEVICE_1', {'cool_down_time': 8});
      config = withKeys(
          config, 'SYSTEM_SETUP', {'startup_time': 25, 'shutdown_time': 18});
      return config;
    }

    test('are a table of their own, in seconds', () async {
      final rows = await rowsOf(timed(), 'Transition Times');
      expect(rows, contains('Projector - PT-FW430U | 45 s | 12 s'));
      // Blank against the one the room did not override: the module still
      // answers for it, and that is worth seeing beside the one it did.
      expect(rows, contains('Camera - TR311 |  | 8 s'));
      // The switcher names neither, so it is not in the table at all.
      expect(rows.where((r) => r.contains('IN1608')), isEmpty);
    });

    test('and the room pair reads on the System summary', () async {
      final rows = await rowsOf(timed(), 'System');
      expect(rows, contains('System Startup | 25 s'));
      expect(rows, contains('System Shutdown | 18 s'));
    });

    test('a room that has corrected nothing grows no table', () async {
      // The ordinary case. Every device answers out of its own driver, so
      // there is nothing here the config actually said.
      final sections = await sectionsFor(room());
      expect(sections.where((s) => s.title == 'Transition Times'), isEmpty);

      final rows = await rowsOf(room(), 'System');
      expect(rows.where((r) => r.startsWith('System Startup')), isEmpty);
      expect(rows.where((r) => r.startsWith('System Shutdown')), isEmpty);
    });

    test('zero is a real answer and is printed as one', () async {
      // Not the same as unset: 0 means no wait at all. Reporting it as blank
      // would read as "the driver decides", which is the opposite.
      final config = withKeys(room(), 'PROJECTORDEVICE_1', {'warm_up_time': 0});
      final rows = await rowsOf(config, 'Transition Times');
      expect(rows, contains('Projector - PT-FW430U | 0 s | '));
    });

    test('and something that is not a number is shown, not swallowed',
        () async {
      // A typo the processor would refuse and fall back on. The report is
      // where somebody would notice it.
      final config =
          withKeys(room(), 'PROJECTORDEVICE_1', {'warm_up_time': 'thirty'});
      final rows = await rowsOf(config, 'Transition Times');
      expect(rows, contains('Projector - PT-FW430U | thirty | '));
    });
  });
}
