import 'app_state.dart';

/// ============================================================================
///  THE DEVICE_INFO BLOCK, READ AND WRITTEN
/// ============================================================================
///  Everything the app knows about a python driver beyond its command list is
///  in one dict at the top of the file - see the long note above
///  [AppStateProvider.parseDeviceInfo]. Which models the driver covers, which
///  device family they belong to, how the box is reached, and what a device
///  block should be filled in with when somebody picks one of those models.
///
///  Until now that dict was written by hand, or by a script run once. A driver
///  dropped into the folder without one is a driver whose models never reach
///  the Model dropdown, whose connection settings nothing can review a room
///  against, and whose absence is invisible - the file parses, it just says
///  nothing. This is the other half: read what a driver DOES say about itself,
///  write the block, and let it be edited afterwards.
///
///  ---------------------------------------------------------------------------
///  WHAT A FILE CAN AND CANNOT SAY ABOUT ITSELF
///  ---------------------------------------------------------------------------
///  READ FROM THE FILE, always:
///    * the models, from `self.Models`;
///    * which connection styles exist, from the wrapper classes at the bottom
///      (SerialClass, SerialOverEthernetClass, EthernetClass, SSHClass, ...);
///    * the baud rate, protocol and service port those classes DEFAULT to,
///      out of their `__init__` signatures;
///    * the keep-alive candidates, from the driver's own Update methods.
///
///  NOT IN THE FILE, ever: the TCP port. `IPPort` is a positional argument in
///  every one of these wrappers - the driver is told which port to use, it
///  does not declare one - so a scan CANNOT know that an Epson answers on
///  3629. That is on the communication sheet, and the editor asks for it
///  rather than inventing one. The same goes for an IP address, a COM port and
///  a site password: those are facts about an installation, not about a
///  driver, and they are deliberately left blank.
///
///  A HOUSE CONVENTION IS NOT A FACT EITHER, but it is a good first answer:
///  every projector in the folder is Btn_Con_Projector1 on a ten-second Power
///  poll, so a new projector driver is seeded with that and corrected if it is
///  wrong. See [kDeviceInfoFamilyDefaults], which is the folder's own habits
///  written down.
/// ============================================================================

/// A word in a module's filename -> the DEVICE_INFO "device_type" it implies.
///
/// The shop's filenames are `<maker>_<kind>_<model>`, and the kind is nearly
/// always enough. AMBIGUOUS TOKENS ARE LEFT OUT rather than guessed: `sm` is
/// the SMP recorder in one file and the NAVigator switcher in the next, and a
/// family filled in wrong is worse than one left for somebody to pick - it
/// puts the models on the wrong tab, where nobody looking for them will think
/// to check.
const Map<String, String> kModuleTokenFamily = {
  'vp': 'projector',
  'projector': 'projector',
  'display': 'display',
  'tdisplay': 'display',
  'camera': 'camera',
  'doccam': 'doccam',
  'dsp': 'dsp',
  'switcher': 'switcher',
  'matrix': 'switcher',
  'scaler': 'switcher',
  'mediaport': 'mediaport',
  'power': 'power',
  'recorder': 'recorder',
  'screen': 'screen',
  'wireless': 'wireless',
  'usb': 'usb',
};

/// A module filename prefix -> the manufacturer, for the device `name`.
/// The convention is the shop's own and is stable across the device folder.
const Map<String, String> kModuleTokenMaker = {
  'apc': 'APC',
  'avr': 'AVer',
  'dali': 'Extron',
  'dyds': 'Da-Lite',
  'epsn': 'Epson',
  'extr': 'Extron',
  'hcam': 'HoverCam',
  'igen': 'iGen',
  'infc': 'InFocus',
  'krmr': 'Kramer',
  'nec': 'NEC',
  'pana': 'Panasonic',
  'poly': 'Poly',
  'ptz': 'PTZOptics',
  'shrp': 'Sharp',
  'shur': 'Shure',
  'smsg': 'Samsung',
  'sony': 'Sony',
  'vadd': 'Vaddio',
};

/// What a family's device is called at the front of a `name` value.
const Map<String, String> kDeviceInfoFamilyLabels = {
  'projector': 'Projector',
  'display': 'Display',
  'camera': 'Camera',
  'doccam': 'Document Camera',
  'dsp': 'DSP',
  'switcher': 'Switcher',
  'mediaport': 'MediaPort',
  'power': 'Power',
  'recorder': 'Recorder',
  'screen': 'Screen',
  'wireless': 'Wireless',
  'usb': 'USB',
};

/// THE DEVICE FOLDER'S OWN HABITS, WRITTEN DOWN.
///
/// Read off the seventy-odd drivers that already carry a block: every
/// projector is Btn_Con_Projector1 / Lbl_Proj_Model_Proj1 / Proj1 on a
/// ten-second Power poll, every Extron switcher is admin + ATEC2007, and so
/// on. A new driver of a known family starts here rather than blank, because
/// a blank field is one nobody fills in and a wrong-but-visible one gets
/// corrected.
///
/// NOT A FACT ABOUT THE PRODUCT - a convention about how this shop names and
/// polls it. Anything here can be edited before it is written, and the
/// keep-alive is checked against the driver's own commands first.
const Map<String, Map<String, dynamic>> kDeviceInfoFamilyDefaults = {
  'projector': {
    'btn_name': 'Btn_Con_Projector1',
    'lbl_name': 'Lbl_Proj_Model_Proj1',
    'gve_id': 'Proj1',
    'keep_alive_command': 'Power',
    'keep_alive_interval': 10,
    'user': '',
    'password': 'ATEC2008',
  },
  'display': {
    'btn_name': 'Btn_Con_Projector1',
    'lbl_name': 'Lbl_Proj_Model_Proj1',
    'gve_id': 'Proj1',
    'keep_alive_command': 'Power',
    'keep_alive_interval': 30,
    'user': '',
    'password': 'ATEC2008',
  },
  'camera': {
    'btn_name': 'Btn_Con_Cam1',
    'lbl_name': 'Lbl_InstCam_Model',
    'gve_id': 'Cam1',
    'keep_alive_command': 'Power',
    'keep_alive_interval': 10,
    'user': 'admin',
    'password': 'ATEC2008',
  },
  'doccam': {
    'keep_alive_command': 'Power',
    'keep_alive_interval': 10,
    'user': '',
    'password': 'ATEC2008',
  },
  'dsp': {
    'btn_name': 'Btn_Con_DSP1',
    'lbl_name': 'Lbl_DSP_Name_Status',
    'gve_id': 'DSP1',
    'keep_alive_command': 'PartNumber',
    'keep_alive_interval': 30,
    'user': 'admin',
    'password': 'ATEC2007',
  },
  'switcher': {
    'btn_name': 'Btn_Con_Switcher1',
    'lbl_name': 'Lbl_Switcher_Model',
    'gve_id': 'Switch1',
    'keep_alive_command': 'Temperature',
    'keep_alive_interval': 30,
    'user': 'admin',
    'password': 'ATEC2007',
  },
  'mediaport': {
    'btn_name': 'Btn_Con_MediaPort1',
    'lbl_name': 'Lbl_MediaPort_Model',
    'gve_id': 'MediaPort1',
    'keep_alive_command': 'USBHostStatus',
    'keep_alive_interval': 60,
    'user': 'admin',
    'password': 'ATEC2007',
  },
  'power': {
    'btn_name': 'Btn_Con_Power1',
    'lbl_name': 'Lbl_Pwr_Connection',
    'gve_id': 'Power1',
    'keep_alive_command': 'SerialNumber',
    'keep_alive_interval': 30,
    'user': 'admin',
    'password': 'ATEC2007',
  },
  'recorder': {
    'btn_name': 'Btn_Con_Recorder1',
    'lbl_name': 'Lbl_Recorder_Model',
    'gve_id': 'Record1',
    'keep_alive_command': 'InputStatus',
    'keep_alive_interval': 30,
    'user': 'admin',
    'password': 'ATEC2007',
  },
  'screen': {
    'btn_name': 'Btn_Con_Screen1',
    'lbl_name': 'Lbl_Screen1_Model',
    'gve_id': 'Screen1',
    'keep_alive_interval': 30,
    'user': 'admin',
    'password': 'ATEC2008',
  },
  'usb': {
    'btn_name': 'Btn_Con_USB1',
    'lbl_name': 'Lbl_USB_Name_Status',
    'gve_id': 'USB1',
    'keep_alive_command': 'Input',
    'keep_alive_interval': 10,
    'user': '',
    'password': 'ATEC2008',
  },
  'wireless': {
    'btn_name': 'Btn_Con_Wireless1',
    'lbl_name': 'Lbl_Wireless_Model',
    'gve_id': 'Wireless1',
    'keep_alive_command': 'RoomCode',
    'keep_alive_interval': 30,
    'user': 'admin',
    'password': 'ATEC2007',
  },
};

/// The keys a "connection" block carries, in the order the folder writes them.
/// The editor offers these first; anything else can still be typed in.
const List<String> kConnectionKeys = [
  'com_type',
  'protocol',
  'net_port',
  'service_port',
  'host',
  'ip_address',
  'serial_port',
  'baud',
];

/// The keys a "defaults" block carries, in the order the folder writes them.
const List<String> kDefaultsKeys = [
  'btn_name',
  'lbl_name',
  'gve_id',
  'name',
  'device_id',
  'input',
  'keep_alive_command',
  'keep_alive_interval',
  'keep_alive_qualifier',
  'keep_alive_trigger',
  'manual_disconnect',
  'user',
  'password',
];

/// The gateway a SerialOverEthernet device is actually reached through - an
/// Extron IPL box in the rack, not the device. Its address and password are
/// the same on every one of them, which is why they are written into the
/// block rather than asked for per room.
const String kSerialOverEthernetGateway = '192.168.254.254';
const String kSerialOverEthernetPassword = 'ATEC2007';
const int kSerialOverEthernetPort = 2001;

/// One DEVICE_INFO block, in the shape the editor holds it.
///
/// Deliberately mutable and deliberately loose: every value is whatever the
/// file said or whatever was typed, and it is [formatDeviceInfo] that decides
/// how each one is spelled in python. A driver that carries a key nothing here
/// has heard of keeps it - see [extras] - because a block round-tripped
/// through this editor must never come back smaller than it went in.
class DeviceInfoDraft {
  /// "device_type": one family, or several.
  List<String> deviceTypes;

  /// "models": every model this driver covers.
  List<String> models;

  /// "connection" + "defaults": the device-block properties a model pick
  /// writes. Two maps for readability, exactly as the files spell them.
  Map<String, dynamic> connection;
  Map<String, dynamic> defaults;

  /// "network" / "serial" / "serialoverethernet" / "http" / "spi": what this
  /// driver wants on each connection style, keyed by the normalized name.
  Map<String, Map<String, dynamic>> comTypes;

  /// "omit": key patterns this model does not use.
  List<String> omit;

  /// Top-level keys the block carried that are none of the above. Kept so an
  /// edit never silently drops something a driver author put there.
  Map<String, dynamic> extras;

  DeviceInfoDraft({
    List<String>? deviceTypes,
    List<String>? models,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? defaults,
    Map<String, Map<String, dynamic>>? comTypes,
    List<String>? omit,
    Map<String, dynamic>? extras,
  })  : deviceTypes = deviceTypes ?? [],
        models = models ?? [],
        connection = connection ?? {},
        defaults = defaults ?? {},
        comTypes = comTypes ?? {},
        omit = omit ?? [],
        extras = extras ?? {};

  /// True when there is nothing here worth writing.
  bool get isEmpty =>
      deviceTypes.isEmpty &&
      models.isEmpty &&
      connection.isEmpty &&
      defaults.isEmpty &&
      comTypes.isEmpty &&
      omit.isEmpty &&
      extras.isEmpty;

  DeviceInfoDraft copy() => DeviceInfoDraft(
        deviceTypes: [...deviceTypes],
        models: [...models],
        connection: {...connection},
        defaults: {...defaults},
        comTypes: {
          for (final e in comTypes.entries) e.key: {...e.value},
        },
        omit: [...omit],
        extras: {...extras},
      );

  /// The draft a parsed DEVICE_INFO dict describes.
  factory DeviceInfoDraft.fromInfo(Map<String, dynamic> info) {
    final draft = DeviceInfoDraft();
    const known = {
      'device_type',
      'device_types',
      'models',
      'connection',
      'defaults',
      'omit',
      'omit_keys',
      'com_types',
      'connections',
    };

    final dt = info['device_type'] ?? info['device_types'];
    if (dt is String && dt.trim().isNotEmpty) draft.deviceTypes = [dt.trim()];
    if (dt is List) {
      draft.deviceTypes = [
        for (final e in dt)
          if (e.toString().trim().isNotEmpty) e.toString().trim(),
      ];
    }

    final models = info['models'];
    if (models is List) {
      draft.models = [
        for (final e in models)
          if (e.toString().trim().isNotEmpty) e.toString().trim(),
      ];
    }

    for (final section in ['connection', 'defaults']) {
      final block = info[section];
      if (block is! Map) continue;
      final into = section == 'connection' ? draft.connection : draft.defaults;
      block.forEach((k, v) => into[k.toString()] = v);
    }

    void takeComTypeBlock(dynamic rawName, dynamic value) {
      if (value is! Map) return;
      final name = AppStateProvider.normalizeComTypeName(rawName.toString());
      if (!kComTypeDefaultNames.contains(name)) return;
      draft.comTypes[name] = {
        for (final e in value.entries) e.key.toString(): e.value,
      };
    }

    info.forEach(takeComTypeBlock);
    final nested = info['com_types'] ?? info['connections'];
    if (nested is Map) nested.forEach(takeComTypeBlock);

    final omit = info['omit'] ?? info['omit_keys'];
    if (omit is List) {
      draft.omit = [
        for (final e in omit)
          if (e.toString().trim().isNotEmpty) e.toString().trim(),
      ];
    }

    info.forEach((key, value) {
      if (known.contains(key)) return;
      if (draft.comTypes.containsKey(
          AppStateProvider.normalizeComTypeName(key))) {
        return;
      }
      draft.extras[key] = value;
    });
    return draft;
  }
}

/// What a scan of a driver file found, and what it could not find.
typedef ModuleScan = ({
  /// The block a scan of this file proposes.
  DeviceInfoDraft draft,

  /// One line each, for the editor to show: what was read out of the file,
  /// and - the important half - what the file does not say and somebody has
  /// to fill in.
  List<String> notes,
});

/// READS A DRIVER AND PROPOSES A BLOCK FOR IT.
///
/// [fileName] is the module's file name or stem; it is where the device family
/// and the manufacturer come from - see [kModuleTokenFamily].
///
/// Everything proposed here is a starting point. Nothing is written by this
/// function; see [formatDeviceInfo] and [applyDeviceInfoBlock].
ModuleScan scanModuleSource(String content, {required String fileName}) {
  final notes = <String>[];
  final draft = DeviceInfoDraft();

  // --- the models -----------------------------------------------------------
  draft.models = AppStateProvider.parseSelfModels(content)..sort();
  if (draft.models.isEmpty) {
    notes.add('This driver has no self.Models dict, so it does not say which '
        'models it covers. Type them in - without them the models never '
        'reach the Model dropdown.');
  } else {
    notes.add('${draft.models.length} model'
        '${draft.models.length == 1 ? '' : 's'} read from self.Models.');
  }

  // --- the family -----------------------------------------------------------
  final tokens = fileName
      .toLowerCase()
      .replaceAll(RegExp(r'\.py$'), '')
      .split(RegExp(r'[^a-z0-9]+'));
  for (final token in tokens) {
    final family = kModuleTokenFamily[token];
    if (family != null && family.isNotEmpty) {
      draft.deviceTypes = [family];
      notes.add('Device family read as "$family" from the file name.');
      break;
    }
  }
  if (draft.deviceTypes.isEmpty) {
    notes.add('The file name does not say which device family this is. Pick '
        'one - a driver with no device_type shows on no tab.');
  }
  final family = draft.deviceTypes.isEmpty ? '' : draft.deviceTypes.first;
  final maker = tokens.isEmpty ? '' : (kModuleTokenMaker[tokens.first] ?? '');

  // --- the connection styles ------------------------------------------------
  final classes = _wrapperClasses(content);
  final serial = classes['SerialClass'] ?? classes['DeviceSerialClass'];
  final overEthernet = classes['SerialOverEthernetClass'];
  final ethernet = classes['EthernetClass'] ?? classes['DeviceEthernetClass'];
  final ssh = classes['SSHClass'];
  final http = classes['HTTPClass'];
  final spi = classes['SPIClass'];

  if (ethernet != null || ssh != null) {
    final block = <String, dynamic>{
      'protocol': (ssh ?? ethernet)!['Protocol'] ?? 'TCP',
      'service_port': (ssh ?? ethernet)!['ServicePort'] ?? 0,
    };
    draft.comTypes['network'] = block;
  }
  if (overEthernet != null) {
    // The Extron gateway in the rack, not the device - see
    // [kSerialOverEthernetGateway]. Its port and password are the same on
    // every one, so they are known even though the device's own port is not.
    draft.comTypes['serialoverethernet'] = {
      'protocol': overEthernet['Protocol'] ?? 'TCP',
      'net_port': kSerialOverEthernetPort,
      'service_port': overEthernet['ServicePort'] ?? 0,
      'ip_address': kSerialOverEthernetGateway,
      'password': kSerialOverEthernetPassword,
      'host': 'processor1',
    };
  }
  if (serial != null) {
    draft.comTypes['serial'] = {
      'baud': serial['Baud'] ?? 9600,
      'host': 'processor1',
    };
  }
  if (http != null) draft.comTypes['http'] = {'protocol': 'TCP'};
  if (spi != null) draft.comTypes['spi'] = {'host': 'spdevice1'};

  if (draft.comTypes.isEmpty) {
    notes.add('No connection wrapper classes found at the bottom of this '
        'file, so nothing could be read about how the box is reached.');
  } else {
    notes.add('Connection styles read from the wrapper classes: '
        '${draft.comTypes.keys.join(', ')}.');
  }

  // The style the block leads with: a network driver is reached over the
  // network, and a driver that only has a COM port is not.
  final leading = draft.comTypes.containsKey('network')
      ? 'Network'
      : draft.comTypes.containsKey('serialoverethernet')
          ? 'SerialOverEthernet'
          : draft.comTypes.containsKey('http')
              ? 'HTTP'
              : draft.comTypes.containsKey('spi')
                  ? 'SPI'
                  : draft.comTypes.containsKey('serial')
                      ? 'Serial'
                      : '';

  // --- the connection block -------------------------------------------------
  //  Site-specific values are written as empty rather than left out: a key
  //  that is present and blank is a slot the device editor shows and somebody
  //  fills in, and one that is absent is a question nobody is asked.
  if (leading.isNotEmpty) {
    draft.connection['com_type'] = leading;
    final block = draft.comTypes[
        AppStateProvider.normalizeComTypeName(leading)]!;
    for (final key in ['protocol', 'net_port', 'service_port', 'baud']) {
      if (block.containsKey(key)) draft.connection[key] = block[key];
    }
    draft.connection['host'] = 'processor1';
    if (leading != 'Serial' && leading != 'SPI') {
      draft.connection['ip_address'] = '';
    }
    if (serial != null) draft.connection['serial_port'] = '';
  }
  if (!draft.connection.containsKey('net_port') &&
      leading != 'Serial' &&
      leading != 'SPI' &&
      leading.isNotEmpty) {
    // THE ONE THING A DRIVER NEVER DECLARES. IPPort is passed IN to every
    // wrapper class in the folder - the module is told which port to use and
    // has no opinion - so it is on the communication sheet and nowhere else.
    notes.add('The network port is not in the file: every wrapper takes '
        'IPPort as an argument rather than declaring one. Take it off the '
        'module’s communication sheet.');
  }

  // --- the defaults block ---------------------------------------------------
  final houseStyle = kDeviceInfoFamilyDefaults[family];
  if (houseStyle != null) {
    draft.defaults.addAll(houseStyle);
    notes.add('Panel names, keep-alive and credentials seeded from what every '
        'other $family driver in the folder uses. Check them.');
  }
  // Present and empty rather than absent: a key the block carries is a slot
  // the device editor shows, and one it leaves out is a question nobody asks.
  draft.defaults.putIfAbsent('keep_alive_trigger', () => null);
  draft.defaults.putIfAbsent('manual_disconnect', () => false);
  if (draft.models.isNotEmpty) {
    // 'Projector - Epson EB-L610W', the way the logger prints it.
    final label = kDeviceInfoFamilyLabels[family] ?? '';
    draft.defaults['name'] = label.isEmpty
        ? draft.models.first
        : '$label - ${maker.isEmpty ? '' : '$maker '}${draft.models.first}';
  }

  // The keep-alive the house uses only counts if this driver HAS it.
  final commands = updateCommandsIn(content);
  final wanted = draft.defaults['keep_alive_command'];
  if (wanted is String && wanted.isNotEmpty && !commands.contains(wanted)) {
    draft.defaults['keep_alive_command'] = commands.isEmpty ? '' : commands.first;
    notes.add('This driver has no "$wanted" command, so the keep-alive was '
        'set to ${commands.isEmpty ? 'blank' : '"${commands.first}"'} '
        'instead. Pick the one that suits it.');
  }

  return (draft: draft, notes: notes);
}

/// The commands a driver can be polled with: every `UpdateX` method on it.
///
/// The keep-alive dropdown on a device reads the Commands dict; this reads the
/// methods, because a driver being annotated for the first time is exactly the
/// case where nothing has parsed it yet.
List<String> updateCommandsIn(String content) {
  final names = <String>{};
  for (final m
      in RegExp(r'def\s+Update(\w+)\s*\(').allMatches(content)) {
    names.add(m.group(1)!);
  }
  final ordered = names.toList()..sort();
  // The ones a room is actually polled on, first: a connection check wants
  // something cheap the device always answers.
  for (final preferred in ['PartNumber', 'Temperature', 'Power']) {
    if (ordered.remove(preferred)) ordered.insert(0, preferred);
  }
  return ordered;
}

/// The `__init__` keyword defaults of each wrapper class in [content], keyed
/// by class name: `{'SerialClass': {'Baud': 9600, 'Parity': 'None'}}`.
Map<String, Map<String, dynamic>> _wrapperClasses(String content) {
  final out = <String, Map<String, dynamic>>{};
  final classes =
      RegExp(r'^class\s+(\w+)\s*\(', multiLine: true).allMatches(content).toList();
  for (var i = 0; i < classes.length; i++) {
    final name = classes[i].group(1)!;
    final from = classes[i].end;
    final to = i + 1 < classes.length ? classes[i + 1].start : content.length;
    final body = content.substring(from, to);
    final init = RegExp(r'def\s+__init__\s*\(([^)]*)\)').firstMatch(body);
    if (init == null) continue;
    final args = <String, dynamic>{};
    for (final arg in _splitArgs(init.group(1)!)) {
      final eq = arg.indexOf('=');
      if (eq < 0) continue;
      final key = arg.substring(0, eq).trim();
      final value = arg.substring(eq + 1).trim();
      if (key.isEmpty || value.isEmpty) continue;
      args[key] = pythonScalarOf(value);
    }
    out[name] = args;
  }
  return out;
}

/// Splits an argument list on the commas that separate arguments, leaving the
/// ones inside quotes and brackets alone.
List<String> _splitArgs(String src) {
  final out = <String>[];
  final buf = StringBuffer();
  int depth = 0;
  String? quote;
  for (var i = 0; i < src.length; i++) {
    final ch = src[i];
    if (quote != null) {
      buf.write(ch);
      if (ch == quote && (i == 0 || src[i - 1] != r'\')) quote = null;
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      buf.write(ch);
      continue;
    }
    if (ch == '(' || ch == '[' || ch == '{') depth++;
    if (ch == ')' || ch == ']' || ch == '}') depth--;
    if (ch == ',' && depth == 0) {
      out.add(buf.toString());
      buf.clear();
      continue;
    }
    buf.write(ch);
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

/// What a typed value MEANS: `22023` is a number, `False` is a boolean, `None`
/// is nothing at all, and `COM3` is a string.
///
/// The editor takes every value as text - one field, whatever the key - and
/// this is what decides how it is spelled in the file. It matters: a port
/// written as `"22023"` is a string the processor cannot open a socket on.
dynamic pythonScalarOf(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return '';
  // Already quoted: the quotes are the answer, whatever is inside them.
  if ((text.startsWith("'") && text.endsWith("'") && text.length > 1) ||
      (text.startsWith('"') && text.endsWith('"') && text.length > 1)) {
    return text.substring(1, text.length - 1);
  }
  if (text == 'None' || text == 'null') return null;
  if (text == 'True' || text == 'true') return true;
  if (text == 'False' || text == 'false') return false;
  final asInt = int.tryParse(text);
  if (asInt != null) return asInt;
  final asDouble = double.tryParse(text);
  if (asDouble != null) return asDouble;
  return text;
}

/// One value as python source.
String pythonLiteralOf(dynamic value) {
  if (value == null) return 'None';
  if (value is bool) return value ? 'True' : 'False';
  if (value is num) return '$value';
  if (value is List) {
    return '[${value.map(pythonLiteralOf).join(', ')}]';
  }
  if (value is Map) {
    return '{${value.entries.map((e) => '${pythonLiteralOf(e.key.toString())}: ${pythonLiteralOf(e.value)}').join(', ')}}';
  }
  final text = value.toString().replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$text"';
}

/// What a value LOOKS like in the editor's single text field - the inverse of
/// [pythonScalarOf], so a value read out of a file and typed straight back in
/// comes out the same on the other side.
String editableValueOf(dynamic value) {
  if (value == null) return 'None';
  if (value is bool) return value ? 'True' : 'False';
  return value.toString();
}

/// THE BLOCK, AS PYTHON.
///
/// Laid out the way the seventy already in the folder are laid out: four-space
/// indent, double quotes, one key per line, the connection styles after the
/// two readable halves. A block that came out looking different from its
/// neighbours would be re-formatted by the next person to open the file, and
/// the diff would be noise on top of whatever they actually changed.
String formatDeviceInfo(DeviceInfoDraft draft) {
  final out = StringBuffer('DEVICE_INFO = {\n');

  if (draft.deviceTypes.length == 1) {
    out.writeln('    "device_type": ${pythonLiteralOf(draft.deviceTypes.first)},');
  } else if (draft.deviceTypes.length > 1) {
    out.writeln('    "device_type": ${pythonLiteralOf(draft.deviceTypes)},');
  }

  // ALWAYS WRITTEN, EVEN EMPTY. A `"models": []` is a statement - this driver
  // is a superseded copy of a sibling that owns those models, so leave the
  // registry to the sibling - and the folder has several that say it on
  // purpose. Dropping the key because the list is empty would erase that.
  final inline = '"models": ${pythonLiteralOf(draft.models)},';
  if (inline.length <= 92) {
    out.writeln('    $inline');
  } else {
    out.writeln('    "models": [');
    for (final model in draft.models) {
      out.writeln('        ${pythonLiteralOf(model)},');
    }
    out.writeln('    ],');
  }

  void writeBlock(String name, Map<String, dynamic> values,
      {List<String> order = const []}) {
    if (values.isEmpty) return;
    out.writeln('    "$name": {');
    for (final key in _orderedKeys(values, order)) {
      out.writeln('        ${pythonLiteralOf(key)}: '
          '${pythonLiteralOf(values[key])},');
    }
    out.writeln('    },');
  }

  writeBlock('connection', draft.connection, order: kConnectionKeys);
  writeBlock('defaults', draft.defaults, order: kDefaultsKeys);

  if (draft.comTypes.isNotEmpty) {
    out.writeln(
        '    # How this driver is reached on each connection style, read by '
        'the app:');
    out.writeln(
        '    # changing com_type loads the matching block, and picking a '
        'model merges');
    out.writeln('    # it over "connection" + "defaults".');
    for (final style in kComTypeStyleLabels.keys) {
      final block = draft.comTypes[style];
      if (block == null || block.isEmpty) continue;
      writeBlock(style, block, order: kConnectionKeys);
    }
  }

  if (draft.omit.isNotEmpty) {
    out.writeln('    "omit": ${pythonLiteralOf(draft.omit)},');
  }
  for (final entry in draft.extras.entries) {
    out.writeln('    ${pythonLiteralOf(entry.key)}: '
        '${pythonLiteralOf(entry.value)},');
  }

  out.write('}');
  return out.toString();
}

/// The block's keys in the folder's order, with anything unrecognized after.
List<String> _orderedKeys(Map<String, dynamic> values, List<String> order) => [
      for (final key in order)
        if (values.containsKey(key)) key,
      for (final key in values.keys)
        if (!order.contains(key)) key,
    ];

/// WRITES [block] INTO A DRIVER, REPLACING WHATEVER WAS THERE.
///
/// A file that already has a DEVICE_INFO gets that one replaced in place -
/// including its comments, which is the point: the block is the app's, and an
/// edit that appended a second one would leave the file with two answers and
/// the parser reading the first.
///
/// A file with none gets it after the imports, on its own, above the first
/// class. Nothing else in the file is touched.
String applyDeviceInfoBlock(String content, String block) {
  final existing =
      RegExp(r'^DEVICE_INFO\s*=\s*\{', multiLine: true).firstMatch(content);
  if (existing != null) {
    final end = bracedBlockEnd(content, existing.end - 1);
    if (end != null) {
      return content.substring(0, existing.start) +
          block +
          content.substring(end);
    }
  }

  // After the import block at the head of the file: the last line of the run
  // of imports and blank lines that starts it.
  final lines = content.split('\n');
  int insertAt = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('import ') || line.startsWith('from ')) {
      insertAt = i + 1;
      continue;
    }
    if (line.isEmpty || line.startsWith('#')) continue;
    break;
  }
  lines.insert(insertAt, '\n$block\n');
  return lines.join('\n');
}

/// The index just past the `}` that closes the brace at [open], or null when
/// it never closes. Quotes and `#` comments inside are stepped over.
int? bracedBlockEnd(String src, int open) {
  int depth = 0;
  String? quote;
  for (var i = open; i < src.length; i++) {
    final ch = src[i];
    if (quote != null) {
      if (ch == r'\') {
        i++;
        continue;
      }
      if (ch == quote) quote = null;
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      continue;
    }
    if (ch == '#') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) return i + 1;
    }
  }
  return null;
}
