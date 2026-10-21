import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_state.dart';
import 'device_manuals.dart';
import 'in_app_browser.dart' show openWebLink;
import 'manuals_catalog.dart';
import 'pdf_viewer_dialog.dart';

/// Opens one document: a PDF in the in-app viewer, a link in the browser.
Future<void> openManualDocument(BuildContext context, AppStateProvider provider,
    ManualsCatalog catalog, ManualDocument doc, String model) async {
  final messenger = ScaffoldMessenger.of(context);
  final uri = doc.uri(catalog.root);
  if (uri == null) return;
  if (uri.scheme == 'file') {
    final file = uri.toFilePath(windows: true);
    if (!await File(file).exists()) {
      messenger.showSnackBar(SnackBar(content: Text('Not there: $file')));
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => PdfViewerDialog(
        filePath: file,
        title: '$model - ${doc.title}',
        onOpenExternally: () => provider.openInDesktop(file),
      ),
    );
    return;
  }
  if (!await openWebLink(context, uri.toString(), title: doc.title)) {
    messenger.showSnackBar(SnackBar(content: Text('Could not open $uri')));
  }
}

IconData _docIcon(ManualDocument d) =>
    d.file?.isNotEmpty == true ? Icons.picture_as_pdf : Icons.open_in_new;

/// Why there is nothing to show, or null when [catalog] has manuals in it.
/// A missing catalog and an empty one are the same answer to the reader:
/// there is nothing here yet, and here is where to put it.
String? _noCatalogText(AppStateProvider provider, ManualsCatalog? catalog) =>
    catalog != null && catalog.models.isNotEmpty
        ? null
        : 'No manuals found in ${provider.effectiveManualsFolder}. Please add '
            'manuals to the folder (catalog\\manuals.json and files\\), or '
            'set App Config > Manuals Folder.';

/// The device manuals for one model, from the Devices tab.
Future<void> showDeviceManualsDialog(
    BuildContext context, AppStateProvider provider, String model) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(model.isEmpty ? 'Device manuals' : 'Device manuals - $model'),
      content: SizedBox(
        width: 560,
        child: FutureBuilder<ManualsCatalog?>(
          future: ManualsCatalogCache.load(provider.effectiveManualsFolder),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                  height: 80, child: Center(child: CircularProgressIndicator()));
            }
            final catalog = snap.data;
            final none = _noCatalogText(provider, catalog);
            if (none != null) return Text(none);
            if (model.trim().isEmpty) {
              return const Text('Pick a model first.');
            }
            final entry = catalog!.forModel(model);
            if (entry == null) {
              return Text('"$model" is not in the manuals catalog yet. '
                  'Running the Manuals tool\'s sync adds models GVE reports.');
            }
            if (!entry.hasDocuments) {
              return Text('${entry.displayName} is in the catalog, but no '
                  'manuals are filed for it yet (${entry.folder}).');
            }
            return ListView(
              shrinkWrap: true,
              children: [
                Text(entry.displayName,
                    style: Theme.of(context).textTheme.titleMedium),
                if (entry.notes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(entry.notes,
                        style: const TextStyle(fontStyle: FontStyle.italic)),
                  ),
                const SizedBox(height: 8),
                for (final doc in entry.documents)
                  ListTile(
                    dense: true,
                    leading: Icon(_docIcon(doc)),
                    title: Text(doc.title.isEmpty ? doc.kind : doc.title),
                    subtitle: Text(doc.kind),
                    onTap: () => openManualDocument(
                        context, provider, catalog, doc, entry.displayName),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close')),
      ],
    ),
  );
}

/// The room's devices with their manuals, and what is missing across every
/// driver: device manuals and module manuals.
Future<void> showManualsDialog(BuildContext context, AppStateProvider provider,
    {int initialTab = 0}) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        _ManualsDialog(provider: provider, initialTab: initialTab),
  );
}

class _ManualsDialog extends StatefulWidget {
  final AppStateProvider provider;
  final int initialTab;

  const _ManualsDialog({required this.provider, required this.initialTab});

  @override
  State<_ManualsDialog> createState() => _ManualsDialogState();
}

class _ManualsDialogState extends State<_ManualsDialog> {
  late Future<ManualsCatalog?> _catalog;
  bool _missingOnly = true;

  AppStateProvider get provider => widget.provider;

  @override
  void initState() {
    super.initState();
    _catalog = ManualsCatalogCache.load(provider.effectiveManualsFolder);
  }

  void _reload() {
    ManualsCatalogCache.clear();
    setState(() {
      _catalog = ManualsCatalogCache.load(provider.effectiveManualsFolder);
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: size.width.clamp(400.0, 1100.0),
        height: size.height * 0.85,
        child: DefaultTabController(
          length: 3,
          initialIndex: widget.initialTab,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
                child: Row(
                  children: [
                    const Icon(Icons.menu_book),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text('Manuals',
                            style: Theme.of(context).textTheme.titleLarge)),
                    FilterChip(
                      label: const Text('Missing only'),
                      selected: _missingOnly,
                      onSelected: (v) => setState(() => _missingOnly = v),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Read the manuals catalog again',
                      onPressed: _reload,
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const TabBar(tabs: [
                Tab(text: 'This room'),
                Tab(text: 'Device manuals'),
                Tab(text: 'Module manuals'),
              ]),
              Expanded(
                child: FutureBuilder<ManualsCatalog?>(
                  future: _catalog,
                  builder: (context, snap) {
                    final loading =
                        snap.connectionState != ConnectionState.done;
                    final catalog = snap.data;
                    return TabBarView(children: [
                      loading ? _spinner : _roomTab(context, catalog),
                      loading ? _spinner : _deviceTab(context, catalog),
                      _moduleTab(context),
                    ]);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const Widget _spinner = Center(child: CircularProgressIndicator());

  Widget _message(String text) => Center(
      child: Padding(padding: const EdgeInsets.all(24), child: Text(text)));

  Widget _summary(BuildContext context, String text, String copyText) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
        child: Row(children: [
          Expanded(child: Text(text)),
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy missing list'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: copyText));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Missing list copied.')));
              }
            },
          ),
        ]),
      );

  Widget _roomTab(BuildContext context, ManualsCatalog? catalog) {
    final none = _noCatalogText(provider, catalog);
    if (none != null) return _message(none);
    final config = provider.roomConfig;
    final keys = activeDeviceKeysIn(config, provider.uiSchema.deviceCountMap);
    if (keys.isEmpty) return _message('No devices in this room.');
    final rows = [
      for (final k in keys)
        (
          name: (config[k] as Map?)?['name']?.toString() ?? k,
          model: (config[k] as Map?)?['model']?.toString().trim() ?? '',
        )
    ];
    final shown = _missingOnly
        ? rows.where((r) => !(catalog!.forModel(r.model)?.hasDocuments ?? false))
        : rows;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final r in shown)
          _roomRow(context, catalog!, r.name, r.model),
        if (shown.isEmpty)
          _message('Every device in this room has a manual.'),
      ],
    );
  }

  Widget _roomRow(
      BuildContext context, ManualsCatalog catalog, String name, String model) {
    final entry = catalog.forModel(model);
    final docs = entry?.documents ?? const <ManualDocument>[];
    final why = model.isEmpty
        ? 'No model set'
        : entry == null
            ? 'Not in the manuals catalog'
            : docs.isEmpty
                ? 'No manuals filed yet'
                : null;
    return ExpansionTile(
      leading: Icon(why == null ? Icons.check_circle : Icons.error_outline,
          color: why == null ? Colors.green : Colors.orange),
      title: Text(name),
      subtitle: Text(why == null ? '$model - ${docs.length} document(s)' : '$model  ($why)'),
      initiallyExpanded: false,
      children: [
        for (final doc in docs)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 72, right: 16),
            leading: Icon(_docIcon(doc), size: 18),
            title: Text(doc.title.isEmpty ? doc.kind : doc.title),
            onTap: () => openManualDocument(
                context, provider, catalog, doc, entry!.displayName),
          ),
      ],
    );
  }

  Widget _deviceTab(BuildContext context, ManualsCatalog? catalog) {
    final none = _noCatalogText(provider, catalog);
    if (none != null) return _message(none);
    final rows = deviceManualRows(catalog!, {
      for (final e in provider.modelRegistry.entries) e.key: e.value.module,
    });
    final missing = rows.where((r) => r.missing).length;
    final shown = _missingOnly ? rows.where((r) => r.missing).toList() : rows;
    return Column(children: [
      _summary(
          context,
          '$missing of ${rows.length} models the drivers support have no '
          'device manual. From ${catalog.root}.',
          missingDeviceManualsText(rows)),
      Expanded(
        child: ListView.builder(
          itemCount: shown.length,
          itemBuilder: (context, i) {
            final r = shown[i];
            return ListTile(
              dense: true,
              leading: Icon(
                  r.missing ? Icons.error_outline : Icons.check_circle,
                  color: r.missing ? Colors.orange : Colors.green),
              title: Text(r.model),
              subtitle: Text('${r.module}  -  ${switch (r.status) {
                DeviceManualStatus.found =>
                  '${r.entry!.documents.length} document(s)',
                DeviceManualStatus.noDocuments =>
                  'in the catalog, no manuals filed (${r.entry!.folder})',
                DeviceManualStatus.notInCatalog => 'not in the manuals catalog',
              }}'),
              onTap: r.missing
                  ? null
                  : () => showDeviceManualsDialog(context, provider, r.model),
            );
          },
        ),
      ),
    ]);
  }

  Widget _moduleTab(BuildContext context) {
    final docs = provider.effectiveDocumentationPath;
    final rows = moduleManualRows(provider.availableModules, docs);
    if (rows.isEmpty) return _message('No python modules found.');
    final missing = rows.where((r) => !r.exists).length;
    final shown = _missingOnly ? rows.where((r) => !r.exists).toList() : rows;
    return Column(children: [
      _summary(
          context,
          '$missing of ${rows.length} python modules have no manual in $docs.',
          missingModuleManualsText(rows)),
      Expanded(
        child: ListView.builder(
          itemCount: shown.length,
          itemBuilder: (context, i) {
            final r = shown[i];
            return ListTile(
              dense: true,
              leading: Icon(r.exists ? Icons.check_circle : Icons.error_outline,
                  color: r.exists ? Colors.green : Colors.orange),
              title: Text(r.module),
              subtitle: Text(r.exists
                  ? r.expectedName
                  : 'Missing: save the manual as ${r.expectedName}'),
              onTap: r.exists
                  ? () => PdfViewerDialog.open(context, provider, r.module)
                  : null,
            );
          },
        ),
      ),
    ]);
  }
}
