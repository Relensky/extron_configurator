import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';
import 'services/ios_share.dart';

// ============================================================================
//  [iOS FILE BROWSER]: the open, save and folder dialogs on an iPhone or iPad
// ============================================================================
//  iOS's own file picker hands an app a one-time COPY of the file picked, in
//  the app's tmp folder - not the file, and nothing beside it. A room is a
//  config plus the folder of drawings, walls, racks and photos next to it, so
//  a room opened that way came up with every tab but the config empty, saves
//  went to the copy, and the next file in the folder couldn't be reached.
//
//  The app CAN read and write, in place, the CTS share folder picked once
//  (services/ios_share.dart) - or its offline copy - and its own Documents
//  folder. So file_dialogs.dart shows this browser of those on iOS instead,
//  and a path from it is the real file, its neighbours and all. "Other
//  location" still offers iOS's picker, for a file from somewhere else.
// ============================================================================

/// What the browser is choosing.
enum IosBrowseMode { open, openMany, save, folder }

class IosFileBrowser {
  IosFileBrowser._();

  /// The context dialogs are shown from - the app's navigator. Set at startup.
  static BuildContext? Function()? contextOf;

  /// Shows the browser. Returns the chosen paths (one, except [IosBrowseMode
  /// .openMany]), [otherLocation] when the person asked for iOS's own picker,
  /// or null when cancelled or there is nothing to show it from.
  static Future<List<String>?> show({
    required IosBrowseMode mode,
    String? title,
    String? initialDirectory,
    List<String>? extensions,
    String? fileName,
  }) async {
    final context = contextOf?.call();
    if (context == null || !context.mounted) return null;
    return showDialog<List<String>>(
      context: context,
      builder: (_) => _BrowserDialog(
        mode: mode,
        title: title,
        initialDirectory: initialDirectory,
        extensions: extensions
            ?.map((e) => e.toLowerCase().replaceFirst(RegExp(r'^\.'), ''))
            .where((e) => e.isNotEmpty)
            .toList(),
        fileName: fileName,
      ),
    );
  }

  /// Returned by [show] for "use iOS's picker instead".
  static const List<String> otherLocation = ['\u0000other'];
}

/// A place the browser starts from.
class _Place {
  const _Place(this.label, this.icon, this.root);
  final String label;
  final IconData icon;
  final String root;
}

class _BrowserDialog extends StatefulWidget {
  const _BrowserDialog({
    required this.mode,
    this.title,
    this.initialDirectory,
    this.extensions,
    this.fileName,
  });

  final IosBrowseMode mode;
  final String? title;
  final String? initialDirectory;
  final List<String>? extensions;
  final String? fileName;

  @override
  State<_BrowserDialog> createState() => _BrowserDialogState();
}

class _BrowserDialogState extends State<_BrowserDialog> {
  late final List<_Place> _places = _placesNow();
  late _Place _place;
  late String _dir;
  List<FileSystemEntity> _entries = const [];
  bool _loading = true;
  String _error = '';
  final Set<String> _chosen = {};
  late final TextEditingController _name = TextEditingController(
    text: widget.fileName ?? '',
  );

  static List<_Place> _placesNow() {
    final places = <_Place>[];
    if (IosShare.active) {
      final root = IosShare.translate(IosShare.localRoot!);
      places.add(
        _Place(
          IosShare.offline ? 'CTS share (offline copy)' : 'CTS share',
          IosShare.offline ? Icons.cloud_off_outlined : Icons.dns_outlined,
          root,
        ),
      );
    }
    final docs = iosDocumentsDirOrNull();
    if (docs != null) {
      places.add(_Place('On this device', Icons.tablet_mac_outlined, docs));
    }
    return places;
  }

  @override
  void initState() {
    super.initState();
    _place = _places.isNotEmpty
        ? _places.first
        : _Place(
            'App folder',
            Icons.folder_outlined,
            Directory.systemTemp.path,
          );
    _dir = _place.root;
    // Start where the caller asked, when that is inside one of the places.
    final start = widget.initialDirectory;
    if (start != null && start.trim().isNotEmpty) {
      var want = IosShare.translate(start.trim());
      if (File(want).existsSync()) want = p.dirname(want);
      for (final place in _places) {
        if (want == place.root || p.isWithin(place.root, want)) {
          _place = place;
          _dir = want;
          break;
        }
      }
    }
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _pickingFiles =>
      widget.mode == IosBrowseMode.open ||
      widget.mode == IosBrowseMode.openMany;

  bool _shown(FileSystemEntity e) {
    final name = p.basename(e.path);
    if (name.startsWith('.') ||
        name.endsWith('.lock') ||
        name.endsWith('.part')) {
      return false;
    }
    if (e is Directory) return true;
    if (widget.mode == IosBrowseMode.folder) return false;
    final exts = widget.extensions;
    if (exts == null || exts.isEmpty) return true;
    return exts.contains(p.extension(name).toLowerCase().replaceFirst('.', ''));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final list = await Directory(_dir)
          .list(followLinks: false)
          .where(_shown)
          .toList()
          .timeout(const Duration(seconds: 15));
      list.sort((a, b) {
        final ad = a is Directory, bd = b is Directory;
        if (ad != bd) return ad ? -1 : 1;
        return p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _entries = const [];
        _loading = false;
        _error =
            'The folder took too long to answer. If this is the CTS '
            'share, check the VPN and open the doit-files server once in the '
            'Files app.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entries = const [];
        _loading = false;
        _error = 'This folder could not be read: $e';
      });
    }
  }

  void _go(String dir) {
    _dir = dir;
    _chosen.clear();
    _load();
  }

  void _up() {
    if (_dir == _place.root) return;
    _go(p.dirname(_dir));
  }

  Future<void> _newFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    final clean = (name ?? '').trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (clean.isEmpty) return;
    try {
      await Directory(p.join(_dir, clean)).create();
      _go(p.join(_dir, clean));
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not make the folder: $e');
    }
  }

  Future<void> _save() async {
    var name = _name.text.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (name.isEmpty) return;
    final exts = widget.extensions;
    if (exts != null &&
        exts.length == 1 &&
        p.extension(name).toLowerCase() != '.${exts.single}') {
      name = '$name.${exts.single}';
    }
    final target = p.join(_dir, name);
    if (File(target).existsSync()) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Replace it?'),
          content: Text('"$name" is already in this folder.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    if (mounted) Navigator.pop(context, [target]);
  }

  String get _where {
    if (_dir == _place.root) return _place.label;
    return '${_place.label} › ${p.relative(_dir, from: _place.root).replaceAll('/', ' › ')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title =
        widget.title ??
        switch (widget.mode) {
          IosBrowseMode.open => 'Open',
          IosBrowseMode.openMany => 'Open',
          IosBrowseMode.save => 'Save as',
          IosBrowseMode.folder => 'Choose a folder',
        };
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      title: Row(
        children: [
          Expanded(child: Text(title, overflow: TextOverflow.ellipsis)),
          if (widget.mode != IosBrowseMode.folder)
            TextButton.icon(
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const Text('Other location'),
              onPressed: () =>
                  Navigator.pop(context, IosFileBrowser.otherLocation),
            ),
        ],
      ),
      content: SizedBox(
        width: size.width < 640 ? size.width : 600,
        height: size.height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_places.length > 1)
              Wrap(
                spacing: 8,
                children: [
                  for (final place in _places)
                    ChoiceChip(
                      avatar: Icon(place.icon, size: 18),
                      label: Text(place.label),
                      selected: identical(place, _place),
                      onSelected: (_) {
                        _place = place;
                        _go(place.root);
                      },
                    ),
                ],
              ),
            if (_places.isEmpty || !IosShare.active)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Connect to the CTS share (the cloud button in the top bar) '
                  'to browse it here.',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Up',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: _dir == _place.root ? null : _up,
                ),
                Expanded(
                  child: Text(
                    _where,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (widget.mode == IosBrowseMode.save ||
                    widget.mode == IosBrowseMode.folder)
                  IconButton(
                    tooltip: 'New folder',
                    icon: const Icon(Icons.create_new_folder_outlined),
                    onPressed: _newFolder,
                  ),
              ],
            ),
            const Divider(height: 1),
            Expanded(child: _list(scheme)),
            if (widget.mode == IosBrowseMode.save)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'File name'),
                  onSubmitted: (_) => _save(),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (widget.mode == IosBrowseMode.folder)
          FilledButton(
            onPressed: () => Navigator.pop(context, [_dir]),
            child: const Text('Use this folder'),
          ),
        if (widget.mode == IosBrowseMode.save)
          FilledButton(onPressed: _save, child: const Text('Save')),
        if (widget.mode == IosBrowseMode.openMany)
          FilledButton(
            onPressed: _chosen.isEmpty
                ? null
                : () => Navigator.pop(context, _chosen.toList()),
            child: Text(_chosen.isEmpty ? 'Open' : 'Open ${_chosen.length}'),
          ),
      ],
    );
  }

  Widget _list(ColorScheme scheme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error, textAlign: TextAlign.center),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text(
          widget.mode == IosBrowseMode.folder || !_pickingFiles
              ? 'No folders here.'
              : 'Nothing here to open.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, i) {
        final e = _entries[i];
        final name = p.basename(e.path);
        if (e is Directory) {
          return ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(name),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _go(e.path),
          );
        }
        final picked = _chosen.contains(e.path);
        return ListTile(
          leading: Icon(_iconFor(name)),
          title: Text(name),
          selected: picked,
          trailing: widget.mode == IosBrowseMode.openMany
              ? Checkbox(value: picked, onChanged: (_) => _toggle(e.path))
              : null,
          onTap: () {
            switch (widget.mode) {
              case IosBrowseMode.open:
                Navigator.pop(context, [e.path]);
              case IosBrowseMode.openMany:
                _toggle(e.path);
              case IosBrowseMode.save:
                _name.text = name;
              case IosBrowseMode.folder:
                break;
            }
          },
        );
      },
    );
  }

  void _toggle(String path) => setState(() {
    if (!_chosen.remove(path)) _chosen.add(path);
  });

  static IconData _iconFor(String name) {
    switch (p.extension(name).toLowerCase()) {
      case '.json':
        return Icons.description_outlined;
      case '.pdf':
        return Icons.picture_as_pdf_outlined;
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.heic':
        return Icons.image_outlined;
      case '.xlsx':
      case '.csv':
        return Icons.table_chart_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}
