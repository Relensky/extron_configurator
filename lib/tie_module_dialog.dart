import 'package:material_ui/material_ui.dart';

import 'app_state.dart';
import 'control_prefill.dart' show familyForModel;
import 'responsive.dart';
import 'search_match.dart';
import 'ui_schema.dart';

/// Ties a catalog model to a python driver by adding it to the "models" list in
/// that driver's DEVICE_INFO.
///
/// For a product no driver lists - a new SKU, a kit under a name nothing ends
/// with - the driver file is the one place that can say "this one too", and
/// saying it there means every room after this one finds the module on its
/// own. The file is shared, so the dialog names it before anything is written.
///
/// Returns true once the model is listed (written now, or already there).
Future<bool> showTieToModuleDialog(
  BuildContext context,
  AppStateProvider provider,
  String model,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => _TieToModuleDialog(provider: provider, model: model.trim()),
  );
  return result ?? false;
}

class _TieToModuleDialog extends StatefulWidget {
  final AppStateProvider provider;
  final String model;

  const _TieToModuleDialog({required this.provider, required this.model});

  @override
  State<_TieToModuleDialog> createState() => _TieToModuleDialogState();
}

class _TieToModuleDialogState extends State<_TieToModuleDialog> {
  final _searchCtl = TextEditingController();
  String _filter = '';
  String _picked = '';
  DeviceTypeSpec? _family;
  bool _busy = false;
  String _error = '';

  AppStateProvider get _provider => widget.provider;

  @override
  void initState() {
    super.initState();
    // The driver already claiming it (a kit of a listed model), if any.
    final claimed = _provider.moduleForModel(widget.model);
    if (claimed.isNotEmpty) _picked = AppStateProvider.moduleStem(claimed);
    _family = familyForModel(_provider, widget.model);
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  /// The families [stem]'s DEVICE_INFO already names, read off the registry.
  List<String> _declaredTypes(String stem) {
    for (final entry in _provider.modelRegistry.values) {
      if (AppStateProvider.moduleStem(entry.module) != stem) continue;
      if (entry.deviceTypes.isNotEmpty) return entry.deviceTypes;
    }
    return const [];
  }

  Future<void> _write() async {
    final declared = _declaredTypes(_picked);
    setState(() {
      _busy = true;
      _error = '';
    });
    final result = await _provider.addModelToModule(
      _picked,
      widget.model,
      deviceType: declared.isEmpty && _family != null
          ? AppStateProvider.normalizeDeviceTypeToken(_family!.prefix)
          : '',
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _busy = false;
        _error = result.message;
      });
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message)),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final modules = [
      for (final m in _provider.availableModules) AppStateProvider.moduleStem(m),
    ];
    final visible =
        _filter.isEmpty ? modules : searchFilter(modules, _filter).toList();
    final declared = _picked.isEmpty ? const <String>[] : _declaredTypes(_picked);
    final needsFamily = _picked.isNotEmpty && declared.isEmpty;

    return AlertDialog(
      title: Text('Tie ${widget.model} to a module'),
      content: SizedBox(
        width: 560,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              autofocus: true,
              controller: _searchCtl,
              decoration: InputDecoration(
                labelText: 'Search modules',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: ClearFieldButton(
                  controller: _searchCtl,
                  onCleared: () => setState(() => _filter = ''),
                ),
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: modules.isEmpty
                  ? const Center(
                      child: Text(
                        'No modules found. Check the Python Modules Path in '
                        'App Config.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (ctx, i) {
                        final stem = visible[i];
                        final models = _provider.moduleModels[stem] ?? const [];
                        return ListTile(
                          dense: true,
                          selected: stem == _picked,
                          title: Text(stem),
                          subtitle: models.isEmpty
                              ? null
                              : Text(
                                  models.join(', '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          onTap: () => setState(() => _picked = stem),
                        );
                      },
                    ),
            ),
            if (needsFamily) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<DeviceTypeSpec>(
                initialValue: _family,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Device family (this module names none)',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final spec in _provider.uiSchema.deviceTypes)
                    DropdownMenuItem(value: spec, child: Text(spec.label)),
                ],
                onChanged: (v) => setState(() => _family = v),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              _picked.isEmpty
                  ? 'Pick the driver that talks to this product.'
                  : 'Writes into ${_provider.modulePyPath(_picked)}. Only the '
                        'DEVICE_INFO models list changes, and every room that '
                        'uses this folder will find the module for '
                        '${widget.model}.',
              style: theme.textTheme.bodySmall,
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                _error,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          key: const ValueKey('tie_module_write'),
          onPressed: _busy || _picked.isEmpty || (needsFamily && _family == null)
              ? null
              : _write,
          child: const Text('Add and tie'),
        ),
      ],
    );
  }
}
