import 'dart:io';

import 'package:file_picker/file_picker.dart' show FileType;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'file_dialogs.dart';

/// The room's photos: the pictures in `<room folder>\photos`, shown as a grid,
/// opened large with the arrow keys to step through them.
///
/// The folder is the record. Nothing is stored in the config, so a photo
/// copied in with Explorer shows up here, and the room folder carries its
/// photos wherever it is zipped or copied.
class RoomPhotosView extends StatefulWidget {
  const RoomPhotosView({super.key});

  @override
  State<RoomPhotosView> createState() => _RoomPhotosViewState();
}

class _RoomPhotosViewState extends State<RoomPhotosView> {
  List<File> _photos = const [];
  bool _loading = true;
  String _folder = '';

  // Read once: the tab is rebuilt from scratch when another room is opened.
  @override
  void initState() {
    super.initState();
    _folder = context.read<AppStateProvider>().roomPhotosFolder;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reload();
    });
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final photos = await context.read<AppStateProvider>().listRoomPhotos();
    if (!mounted) return;
    setState(() {
      _photos = photos;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final provider = context.read<AppStateProvider>();
    final picked = await pickFilesCompat(
      dialogTitle: 'Add photos to this room',
      type: FileType.custom,
      allowedExtensions: [
        for (final e in AppStateProvider.kPhotoExtensions) e.substring(1),
      ],
      allowMultiple: true,
    );
    if (picked == null) return;
    final sources = [
      for (final f in picked.files)
        if (f.path != null) f.path!,
    ];
    final copied = await provider.addRoomPhotos(sources);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          copied == sources.length
              ? '$copied photo${copied == 1 ? '' : 's'} added.'
              : '$copied of ${sources.length} photos added - see the log '
                    'for the rest.',
        ),
      ),
    );
    await _reload();
  }

  Future<void> _openFolder() async {
    final provider = context.read<AppStateProvider>();
    try {
      await Directory(_folder).create(recursive: true);
    } catch (_) {}
    final error = await provider.openInDesktop(_folder);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _view(int index) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _PhotoViewer(photos: _photos, start: index),
    );
    if (changed == true) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_folder.isEmpty) {
      return const Center(
        child: Text(
          'Save the room first - photos are kept in its folder.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                key: const ValueKey('room_photos_add'),
                onPressed: _add,
                icon: const Icon(Icons.add_photo_alternate),
                label: const Text('Add photos'),
              ),
              OutlinedButton.icon(
                onPressed: _openFolder,
                icon: const Icon(Icons.folder_open),
                label: const Text('Open folder'),
              ),
              IconButton(
                tooltip: 'Read the folder again',
                onPressed: _reload,
                icon: const Icon(Icons.refresh),
              ),
              Text(
                '${_photos.length} photo${_photos.length == 1 ? '' : 's'} in '
                '$_folder',
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            // Words rather than a spinner: a share can take a moment, and a
            // spinner never settles while the folder read is pending.
            child: _loading
                ? const Center(child: Text('Reading the folder...'))
                : _photos.isEmpty
                ? const Center(
                    child: Text(
                      'No photos yet. Add some, or copy them into the folder.',
                      textAlign: TextAlign.center,
                    ),
                  )
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 240,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 1,
                        ),
                    itemCount: _photos.length,
                    itemBuilder: (_, i) => _Thumb(
                      file: _photos[i],
                      onTap: () => _view(i),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// True for a file Flutter can draw; HEIC opens in the system viewer instead.
bool _drawable(File f) =>
    path.extension(f.path).toLowerCase() != '.heic';

class _Thumb extends StatelessWidget {
  final File file;
  final VoidCallback onTap;

  const _Thumb({required this.file, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = path.basename(file.path);
    return Tooltip(
      message: name,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: theme.colorScheme.surfaceContainerHighest),
              if (_drawable(file))
                Image.file(
                  file,
                  fit: BoxFit.cover,
                  // Decoded small: a share full of 12 MP photos otherwise
                  // decodes every one at full size for a 240 px tile.
                  cacheWidth: 360,
                  errorBuilder: (_, _, _) =>
                      const Center(child: Icon(Icons.broken_image)),
                )
              else
                const Center(child: Icon(Icons.image, size: 40)),
              Align(
                alignment: Alignment.bottomLeft,
                child: Container(
                  width: double.infinity,
                  color: Colors.black54,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One photo large, zoomable, with Left/Right to step through the rest.
/// Pops true when a photo was deleted, so the grid re-reads the folder.
class _PhotoViewer extends StatefulWidget {
  final List<File> photos;
  final int start;

  const _PhotoViewer({required this.photos, required this.start});

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final List<File> _photos = [...widget.photos];
  late int _index = widget.start;
  bool _changed = false;

  File get _photo => _photos[_index];

  void _step(int by) {
    if (_photos.isEmpty) return;
    setState(() => _index = (_index + by) % _photos.length);
  }

  Future<void> _delete() async {
    final provider = context.read<AppStateProvider>();
    final name = path.basename(_photo.path);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this photo?'),
        content: Text(
          '$name is deleted from the room folder for everyone. This cannot '
          'be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!await provider.deleteRoomPhoto(_photo.path)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete $name.')),
        );
      }
      return;
    }
    _changed = true;
    if (!mounted) return;
    if (_photos.length == 1) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _photos.removeAt(_index);
      if (_index >= _photos.length) _index = _photos.length - 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final name = path.basename(_photo.path);
    final size = MediaQuery.sizeOf(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$name  (${_index + 1} of ${_photos.length})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Open in the system viewer',
                        icon: const Icon(Icons.open_in_new),
                        onPressed: () => provider.openInDesktop(_photo.path),
                      ),
                      IconButton(
                        tooltip: 'Show in folder',
                        icon: const Icon(Icons.folder_open),
                        onPressed: () =>
                            provider.revealInFileManager(_photo.path),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _delete,
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(_changed),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Previous (Left arrow)',
                        icon: const Icon(Icons.chevron_left, size: 36),
                        onPressed: _photos.length > 1 ? () => _step(-1) : null,
                      ),
                      Expanded(
                        child: _drawable(_photo)
                            ? InteractiveViewer(
                                key: ValueKey(_photo.path),
                                maxScale: 8,
                                child: Center(
                                  child: Image.file(
                                    _photo,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, _, _) => const Text(
                                      'This picture could not be read.',
                                    ),
                                  ),
                                ),
                              )
                            : Center(
                                child: TextButton.icon(
                                  onPressed: () =>
                                      provider.openInDesktop(_photo.path),
                                  icon: const Icon(Icons.open_in_new),
                                  label: const Text(
                                    'HEIC photos open in the system viewer',
                                  ),
                                ),
                              ),
                      ),
                      IconButton(
                        tooltip: 'Next (Right arrow)',
                        icon: const Icon(Icons.chevron_right, size: 36),
                        onPressed: _photos.length > 1 ? () => _step(1) : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
