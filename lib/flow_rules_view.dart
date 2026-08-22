import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_flow_model.dart';
import 'flow_rules.dart';
import 'side_pane.dart';

/// ============================================================================
///  FLOW RULES TAB
/// ============================================================================
///  How a room turns into a drawing, as a document somebody can edit.
///
///  The AV Flow tab reads the config and draws the room: every source on the
///  switcher input its number names, every display on the output that feeds
///  it, the boxes the config never mentions because everybody knows they are
///  there — the receiver behind the display, the transmitter beside the
///  camera, the leads into the USB switcher. Which box, and when, used to be
///  constants compiled into the routing pass, so a new model or a differently
///  wired room meant a code change.
///
///  This is that table, with an editor around it. Every rule family has the
///  same shape: a list, an Add, and a dialog per entry. Nothing here draws
///  anything by itself — press **Recreate from config** on the AV Flow tab (or
///  edit the room) and the drawing is built again with the rules as they now
///  stand.
///
///  SAVE is deliberate. An edit changes the rules in memory immediately, so
///  the next drawing follows it; the file is only written when you press Save,
///  and **Reset to built-in** puts back exactly what the app ships with.
/// ============================================================================

/// The families, in the order the routing pass uses them.
enum _RuleSection {
  sourceBoxes('Source boxes', Icons.input,
      'Boxes the config mentions but never describes — the room PC, the doc '
          'cam, the laptop at a plate. Each rule says what one of them is.'),
  sourceDevices('Source devices', Icons.videocam,
      'An input the config already has a device block for. The box is on the '
          'canvas; only the cable is missing.'),
  destinationDevices('Display outputs', Icons.tv,
      'Which display block an output key feeds.'),
  destinationBoxes('Destination boxes', Icons.speaker,
      'The same idea at the other end of the matrix: a confidence monitor, '
          'the assisted-listening transmitter.'),
  captureDestinations('Capture', Icons.cameraswitch,
      'Where the capture feed lands — whichever of these boxes this room was '
          'built with.'),
  extenders('Extenders', Icons.settings_ethernet,
      'When the two ends of a run do not take the same cable, this is the box '
          'that goes between them.'),
  usbSwitchers('USB switchers', Icons.usb,
      'What is plugged into each port of a USB switcher. Nothing in the '
          'config says, so this does.'),
  expansion('Expansion bus', Icons.link,
      'Words on a connector label that mean "expansion bus".'),
  outletAliases('Outlet names', Icons.power,
      'Outlet labels that name a device outright, whatever else on the '
          'drawing answers to the word.');

  final String label;
  final IconData icon;
  final String blurb;
  const _RuleSection(this.label, this.icon, this.blurb);
}

class FlowRulesView extends StatefulWidget {
  const FlowRulesView({super.key});

  @override
  State<FlowRulesView> createState() => _FlowRulesViewState();
}

class _FlowRulesViewState extends State<FlowRulesView> {
  _RuleSection _section = _RuleSection.sourceBoxes;

  /// True when the rules have been edited since the last write to disk.
  bool _dirty = false;

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: error ? snackErrorFill(context) : null),
    );
  }

  /// Every edit goes through here: the rules change in memory, the drawing is
  /// allowed to be built again, and the tab remembers that the file is behind.
  void _apply(FlowRules rules) {
    context.read<AppStateProvider>().applyFlowRules(rules);
    setState(() => _dirty = true);
  }

  Future<void> _save() async {
    final provider = context.read<AppStateProvider>();
    final saved = await provider.saveFlowRules();
    if (saved.isEmpty) {
      _snack('Could not save the flow rules.', error: true);
      return;
    }
    setState(() => _dirty = false);
    _snack('Flow rules saved to $saved');
  }

  Future<void> _resetToBuiltIn() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Back to the built-in rules?'),
        content: const Text(
          'Every family goes back to the rules the app ships with, and '
          'anything you have added or changed here is lost.\n\n'
          'Nothing is written to disk until you press Save — so if this turns '
          'out to be the wrong idea, Reload from file brings your own rules '
          'back.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _apply(FlowRules.builtIn());
    _snack('Back to the built-in rules.');
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final rules = provider.flowRules;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _toolbar(provider, rules, theme),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SidePane(
                side: PaneSide.left,
                title: 'Rules',
                storageKey: 'flow_rules_sections',
                initialWidth: 260,
                child: ListView(
                  children: [
                    for (final s in _RuleSection.values)
                      ListTile(
                        key: ValueKey('flow_rules_section_${s.name}'),
                        dense: true,
                        selected: s == _section,
                        leading: Icon(s.icon, size: 20),
                        title: Text(s.label,
                            style: const TextStyle(fontSize: 13)),
                        trailing: Text('${_countFor(rules, s)}',
                            style: theme.textTheme.bodySmall),
                        onTap: () => setState(() => _section = s),
                      ),
                  ],
                ),
              ),
              Expanded(child: _sectionBody(provider, rules, theme)),
            ],
          ),
        ),
      ],
    );
  }

  int _countFor(FlowRules r, _RuleSection s) => switch (s) {
        _RuleSection.sourceBoxes => r.sourceBoxes.length,
        _RuleSection.sourceDevices => r.sourceDevices.length,
        _RuleSection.destinationDevices => r.destinationDevices.length,
        _RuleSection.destinationBoxes => r.destinationBoxes.length,
        _RuleSection.captureDestinations => r.captureDestinations.length,
        _RuleSection.extenders => r.extenders.length,
        _RuleSection.usbSwitchers => r.usbSwitchers.length,
        _RuleSection.expansion => r.expansionKeywords.length,
        _RuleSection.outletAliases => r.outletAliases.length,
      };

  Widget _toolbar(AppStateProvider provider, FlowRules rules, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('AV Flow Rules', style: theme.textTheme.titleLarge),
          Text(
            _dirty ? 'Edited — not saved yet' : rules.source,
            style: theme.textTheme.bodySmall?.copyWith(
              color: _dirty ? theme.colorScheme.error : theme.disabledColor,
            ),
          ),
          ElevatedButton.icon(
            key: const ValueKey('flow_rules_save'),
            icon: const Icon(Icons.save, size: 18),
            label: const Text('Save'),
            onPressed: _save,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Reload from file'),
            onPressed: () async {
              await provider.loadFlowRules();
              if (!mounted) return;
              setState(() => _dirty = false);
              _snack('Flow rules re-read from ${provider.flowRules.source}');
            },
          ),
          OutlinedButton.icon(
            key: const ValueKey('flow_rules_reset'),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Reset to built-in'),
            onPressed: _resetToBuiltIn,
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  //  ONE FAMILY
  // --------------------------------------------------------------------------

  Widget _sectionBody(
      AppStateProvider provider, FlowRules rules, ThemeData theme) {
    final rows = switch (_section) {
      _RuleSection.sourceBoxes => [
          for (final r in rules.sourceBoxes)
            _boxTile(provider, rules, r, isSource: true),
        ],
      _RuleSection.destinationBoxes => [
          for (final r in rules.destinationBoxes)
            _boxTile(provider, rules, r, isSource: false),
        ],
      _RuleSection.sourceDevices => [
          for (final r in rules.sourceDevices)
            _deviceTile(rules, r, _DeviceFamily.source),
        ],
      _RuleSection.destinationDevices => [
          for (final r in rules.destinationDevices)
            _deviceTile(rules, r, _DeviceFamily.destination),
        ],
      _RuleSection.captureDestinations => [
          for (final r in rules.captureDestinations)
            _deviceTile(rules, r, _DeviceFamily.capture),
        ],
      _RuleSection.extenders => [
          for (final r in rules.extenders) _extenderTile(provider, rules, r),
        ],
      _RuleSection.usbSwitchers => [
          for (final r in rules.usbSwitchers) _usbTile(rules, r),
        ],
      _RuleSection.expansion => [
          for (final k in rules.expansionKeywords) _keywordTile(rules, k),
        ],
      _RuleSection.outletAliases => [
          for (final e in rules.outletAliases.entries)
            _aliasTile(rules, e.key, e.value),
        ],
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_section.label, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(_section.blurb, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                key: const ValueKey('flow_rules_add'),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
                onPressed: () => _add(provider, rules),
              ),
            ],
          ),
        ),
        const Divider(height: 16),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    'Nothing here yet, so the drawing does nothing for this '
                    'family. Press Add to write the first rule.',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  children: rows,
                ),
        ),
      ],
    );
  }

  // --- the tiles ------------------------------------------------------------

  Widget _tile({
    required Key key,
    required String title,
    required String subtitle,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
    String? warning,
  }) =>
      Card(
        key: key,
        margin: const EdgeInsets.only(bottom: 6),
        child: ListTile(
          dense: true,
          title: Text(title),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(subtitle),
              if (warning != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    warning,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.edit, size: 18),
                tooltip: 'Edit',
                onPressed: onEdit,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: 'Remove',
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      );

  /// The catalog line for a model a rule would place, or the warning that the
  /// catalog has never heard of it — which is not fatal (the family template
  /// stands in) but is nearly always a typo.
  String? _modelWarning(AppStateProvider provider, String model) {
    if (model.trim().isEmpty) {
      return 'No model yet, so this box will be drawn with no connectors '
          'on it.';
    }
    if (provider.avDeviceLibrary.templateForModel(model) != null) return null;
    return 'The catalog does not carry "$model" yet. The box still draws, '
        'using the generic connectors for its family, but it will not be '
        'priced.';
  }

  Widget _boxTile(
    AppStateProvider provider,
    FlowRules rules,
    FlowBoxRule rule, {
    required bool isSource,
  }) =>
      _tile(
        key: ValueKey('flow_rule_box_${rule.configKey}'),
        title: rule.configKey,
        subtitle: '${rule.label} • ${rule.model} • ${rule.zone}'
            '${rule.excludeFromCost ? ' • not quoted' : ''}'
            '${rule.signals == 'video' ? '' : ' • ${rule.signals}'}',
        warning: _modelWarning(provider, rule.model),
        onEdit: () => _editBox(rules, rule, isSource: isSource),
        onDelete: () => _apply(isSource
            ? rules.copyWith(
                sourceBoxes: [
                  for (final r in rules.sourceBoxes)
                    if (r.configKey != rule.configKey) r,
                ],
              )
            : rules.copyWith(
                destinationBoxes: [
                  for (final r in rules.destinationBoxes)
                    if (r.configKey != rule.configKey) r,
                ],
              )),
      );

  Widget _deviceTile(
          FlowRules rules, FlowDeviceRule rule, _DeviceFamily family) =>
      _tile(
        key: ValueKey('flow_rule_device_${rule.configKey}'),
        title: rule.configKey,
        subtitle: rule.target,
        onEdit: () => _editDevice(rules, rule, family),
        onDelete: () => _apply(_withDevices(
          rules,
          family,
          [
            for (final r in _devicesOf(rules, family))
              if (r.configKey != rule.configKey) r,
          ],
        )),
      );

  Widget _extenderTile(
          AppStateProvider provider, FlowRules rules, FlowExtenderRule rule) =>
      _tile(
        key: ValueKey('flow_rule_extender_${rule.id}'),
        title: rule.label,
        subtitle: 'switcher ${rule.switcherSignal} '
            '${rule.onOutput ? 'output' : 'input'} → far end '
            '${rule.farSignal} • ${rule.model}',
        warning: _modelWarning(provider, rule.model),
        onEdit: () => _editExtender(rules, rule),
        onDelete: () => _apply(rules.copyWith(
          extenders: [
            for (final r in rules.extenders)
              if (r.id != rule.id) r,
          ],
        )),
      );

  Widget _usbTile(FlowRules rules, FlowUsbRule rule) => _tile(
        key: ValueKey('flow_rule_usb_${rule.switcher}'),
        title: rule.switcher,
        subtitle: [
          for (int i = 0; i < rule.devicePorts.length; i++)
            'DEVICE ${i + 1} ← ${rule.devicePorts[i]}',
          for (int i = 0; i < rule.hostPorts.length; i++)
            'HOST ${i + 1} → ${rule.hostPorts[i]}',
        ].join('\n'),
        onEdit: () => _editUsb(rules, rule),
        onDelete: () => _apply(rules.copyWith(
          usbSwitchers: [
            for (final r in rules.usbSwitchers)
              if (r.switcher != rule.switcher) r,
          ],
        )),
      );

  Widget _keywordTile(FlowRules rules, String keyword) => _tile(
        key: ValueKey('flow_rule_keyword_$keyword'),
        title: keyword,
        subtitle: 'A connector whose label carries this word is an expansion '
            'bus.',
        onEdit: () => _editKeyword(rules, keyword),
        onDelete: () => _apply(rules.copyWith(
          expansionKeywords: [
            for (final k in rules.expansionKeywords)
              if (k != keyword) k,
          ],
        )),
      );

  Widget _aliasTile(FlowRules rules, String name, String prefix) => _tile(
        key: ValueKey('flow_rule_alias_$name'),
        title: '"$name"',
        subtitle: 'An outlet with this name is $prefix — no scoring, no tie.',
        onEdit: () => _editAlias(rules, name, prefix),
        onDelete: () => _apply(rules.copyWith(
          outletAliases: {
            for (final e in rules.outletAliases.entries)
              if (e.key != name) e.key: e.value,
          },
        )),
      );

  // --- adding ---------------------------------------------------------------

  void _add(AppStateProvider provider, FlowRules rules) {
    switch (_section) {
      case _RuleSection.sourceBoxes:
        _editBox(rules, null, isSource: true);
      case _RuleSection.destinationBoxes:
        _editBox(rules, null, isSource: false);
      case _RuleSection.sourceDevices:
        _editDevice(rules, null, _DeviceFamily.source);
      case _RuleSection.destinationDevices:
        _editDevice(rules, null, _DeviceFamily.destination);
      case _RuleSection.captureDestinations:
        _editDevice(rules, null, _DeviceFamily.capture);
      case _RuleSection.extenders:
        _editExtender(rules, null);
      case _RuleSection.usbSwitchers:
        _editUsb(rules, null);
      case _RuleSection.expansion:
        _editKeyword(rules, null);
      case _RuleSection.outletAliases:
        _editAlias(rules, null, '');
    }
  }

  // --- the dialogs ----------------------------------------------------------

  Future<void> _editBox(
    FlowRules rules,
    FlowBoxRule? existing, {
    required bool isSource,
  }) async {
    final key = TextEditingController(text: existing?.configKey ?? '');
    final label = TextEditingController(text: existing?.label ?? '');
    final model = TextEditingController(text: existing?.model ?? '');
    String zone = existing?.zone ?? 'lectern';
    String signals = existing?.signals ?? 'video';
    bool excluded = existing?.excludeFromCost ?? false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(existing == null ? 'New box rule' : 'Edit box rule'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _field(key, 'Config key',
                      'The SYSTEM_SETUP key this box belongs to, like '
                          'input_pc or output_monitor_1.'),
                  _field(label, 'Name on the drawing', ''),
                  _field(model, 'Catalog model',
                      'The catalog entry to use — that is where its '
                          'connectors, price and rack height come from.'),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: zone,
                    decoration: const InputDecoration(
                      labelText: 'Where it lives',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final z in kFlowZones)
                        DropdownMenuItem(value: z, child: Text(z)),
                    ],
                    onChanged: (v) => setLocal(() => zone = v ?? 'lectern'),
                  ),
                  if (!isSource) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: signals,
                      decoration: const InputDecoration(
                        labelText: 'Connectors the lead may land on',
                        helperText:
                            'Assisted listening is line audio; most things '
                            'here are video.',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final s in kFlowSignalGroups)
                          DropdownMenuItem(value: s, child: Text(s)),
                      ],
                      onChanged: (v) => setLocal(() => signals = v ?? 'video'),
                    ),
                  ],
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Not on the quote'),
                    subtitle: const Text(
                        'Tick this for something the room is not buying, like '
                        'the presenter’s own laptop.'),
                    value: excluded,
                    onChanged: (v) => setLocal(() => excluded = v),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    if (key.text.trim().isEmpty) {
      _snack('Give the rule a config key — without one it never does '
          'anything.', error: true);
      return;
    }

    final rule = FlowBoxRule(
      configKey: key.text.trim(),
      label: label.text.trim().isEmpty ? key.text.trim() : label.text.trim(),
      model: model.text.trim(),
      zone: zone,
      excludeFromCost: excluded,
      signals: isSource ? 'video' : signals,
    );
    final list = [
      for (final r in isSource ? rules.sourceBoxes : rules.destinationBoxes)
        if (r.configKey != (existing?.configKey ?? rule.configKey) &&
            r.configKey != rule.configKey)
          r,
      rule,
    ];
    _apply(isSource
        ? rules.copyWith(sourceBoxes: list)
        : rules.copyWith(destinationBoxes: list));
  }

  Future<void> _editDevice(
    FlowRules rules,
    FlowDeviceRule? existing,
    _DeviceFamily family,
  ) async {
    final key = TextEditingController(text: existing?.configKey ?? '');
    final target = TextEditingController(text: existing?.target ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New device rule' : 'Edit device rule'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(key, 'Config key',
                  'input_wireless, output_proj_1, output_cc.'),
              _field(target, 'The box it means', kFlowTargetHelp),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    if (key.text.trim().isEmpty || target.text.trim().isEmpty) {
      _snack('This one needs both halves: which config key, and which box it '
          'means.', error: true);
      return;
    }
    final rule = FlowDeviceRule(
      configKey: key.text.trim(),
      target: target.text.trim(),
    );
    _apply(_withDevices(rules, family, [
      for (final r in _devicesOf(rules, family))
        if (r.configKey != (existing?.configKey ?? rule.configKey) &&
            r.configKey != rule.configKey)
          r,
      rule,
    ]));
  }

  Future<void> _editExtender(
      FlowRules rules, FlowExtenderRule? existing) async {
    final id = TextEditingController(text: existing?.id ?? '');
    final label = TextEditingController(text: existing?.label ?? '');
    final model = TextEditingController(text: existing?.model ?? '');
    String switcherSignal = existing?.switcherSignal ?? 'hdbaset';
    String farSignal = existing?.farSignal ?? 'hdmi';
    bool onOutput = existing?.onOutput ?? true;
    String zone = existing?.zone ?? 'wall';

    final signalNames = [for (final s in SignalType.values) s.name];

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(
              existing == null ? 'New extender rule' : 'Edit extender rule'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'When a run leaves the switcher on one kind of connector '
                    'and arrives at the far end on another, this is the box '
                    'that goes between them. The run becomes two cables and a '
                    'box on the quote.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  _field(id, 'Rule id',
                      'Something short that will not change — the box this '
                          'places is named after it (rx, tx).'),
                  _field(label, 'Name on the drawing', ''),
                  _field(model, 'Catalog model', ''),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: signalNames.contains(switcherSignal)
                              ? switcherSignal
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'At the switcher',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final s in signalNames)
                              DropdownMenuItem(value: s, child: Text(s)),
                          ],
                          onChanged: (v) =>
                              setLocal(() => switcherSignal = v ?? 'hdbaset'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue:
                              signalNames.contains(farSignal) ? farSignal : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'At the far end',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final s in signalNames)
                              DropdownMenuItem(value: s, child: Text(s)),
                          ],
                          onChanged: (v) =>
                              setLocal(() => farSignal = v ?? 'hdmi'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<bool>(
                    initialValue: onOutput,
                    decoration: const InputDecoration(
                      labelText: 'Which end of the matrix',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                          value: true,
                          child: Text('An output — a receiver at the display')),
                      DropdownMenuItem(
                          value: false,
                          child: Text('An input — a transmitter at the source')),
                    ],
                    onChanged: (v) => setLocal(() => onOutput = v ?? true),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: zone,
                    decoration: const InputDecoration(
                      labelText: 'Where it lives',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final z in kFlowZones)
                        DropdownMenuItem(value: z, child: Text(z)),
                    ],
                    onChanged: (v) => setLocal(() => zone = v ?? 'wall'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    if (id.text.trim().isEmpty || model.text.trim().isEmpty) {
      _snack('An extender rule needs an id, and a model to place.',
          error: true);
      return;
    }
    if (switcherSignal == farSignal) {
      _snack(
        'Both ends take the same kind of connector, so nothing needs to go '
        'between them. This rule would never do anything.',
        error: true,
      );
      return;
    }
    final rule = FlowExtenderRule(
      id: id.text.trim(),
      switcherSignal: switcherSignal,
      farSignal: farSignal,
      onOutput: onOutput,
      model: model.text.trim(),
      label: label.text.trim().isEmpty ? id.text.trim() : label.text.trim(),
      zone: zone,
    );
    _apply(rules.copyWith(extenders: [
      for (final r in rules.extenders)
        if (r.id != (existing?.id ?? rule.id) && r.id != rule.id) r,
      rule,
    ]));
  }

  Future<void> _editUsb(FlowRules rules, FlowUsbRule? existing) async {
    final switcher =
        TextEditingController(text: existing?.switcher ?? 'USBDEVICE_1');
    final devices = TextEditingController(
        text: (existing?.devicePorts ?? const <String>[]).join('\n'));
    final hosts = TextEditingController(
        text: (existing?.hostPorts ?? const <String>[]).join('\n'));

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null
            ? 'New USB switcher rule'
            : 'Edit USB switcher rule'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'One line per port, in port order: the first line is '
                  'DEVICE 1 (or HOST 1), the second is DEVICE 2, and so on. '
                  'Leave a line blank to leave that port empty — the ports '
                  'below it stay where they are.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                _field(switcher, 'The USB switcher', kFlowTargetHelp),
                _field(devices, 'DEVICE ports — what feeds them',
                    'The room’s peripherals: the DSP, the AV Bridge, the '
                        'doc cam.',
                    lines: 4),
                _field(hosts, 'HOST ports — what they feed',
                    'The machines that can take the room: the PC, or a laptop '
                        'at a plate.',
                    lines: 3),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    if (switcher.text.trim().isEmpty) {
      _snack('Say which USB switcher this rule is about.', error: true);
      return;
    }
    List<String> lines(String raw) => [
          for (final l in raw.split('\n')) l.trim(),
        ]..removeWhere((l) => l.isEmpty && raw.trim().isEmpty);

    final rule = FlowUsbRule(
      switcher: switcher.text.trim(),
      devicePorts: lines(devices.text),
      hostPorts: lines(hosts.text),
    );
    _apply(rules.copyWith(usbSwitchers: [
      for (final r in rules.usbSwitchers)
        if (r.switcher != (existing?.switcher ?? rule.switcher) &&
            r.switcher != rule.switcher)
          r,
      rule,
    ]));
  }

  Future<void> _editKeyword(FlowRules rules, String? existing) async {
    final word = TextEditingController(text: existing ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Expansion-bus word'),
        content: SizedBox(
          width: 420,
          child: _field(word, 'Word on the connector label',
              'Matched as a whole word, so EXP does not also match EXPO.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final value = word.text.trim().toUpperCase();
    if (value.isEmpty) return;
    _apply(rules.copyWith(expansionKeywords: [
      for (final k in rules.expansionKeywords)
        if (k != existing && k != value) k,
      value,
    ]));
  }

  Future<void> _editAlias(
      FlowRules rules, String? existingName, String prefix) async {
    final name = TextEditingController(text: existingName ?? '');
    final target = TextEditingController(text: prefix);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Outlet name'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(name, 'The whole outlet label',
                  'Matched in full, and case does not matter. "Switch" '
                      'settles that word and leaves "USB Switch" alone.'),
              _field(target, 'The device it means',
                  'A family prefix like SWITCHERDEVICE_, or one block.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    if (name.text.trim().isEmpty || target.text.trim().isEmpty) return;
    _apply(rules.copyWith(outletAliases: {
      for (final e in rules.outletAliases.entries)
        if (e.key != existingName && e.key != name.text.trim().toLowerCase())
          e.key: e.value,
      name.text.trim().toLowerCase(): target.text.trim(),
    }));
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String helper, {
    int lines = 1,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: controller,
          maxLines: lines,
          decoration: InputDecoration(
            labelText: label,
            helperText: helper.isEmpty ? null : helper,
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  // --- the three device-rule families, addressed by name --------------------

  List<FlowDeviceRule> _devicesOf(FlowRules r, _DeviceFamily f) => switch (f) {
        _DeviceFamily.source => r.sourceDevices,
        _DeviceFamily.destination => r.destinationDevices,
        _DeviceFamily.capture => r.captureDestinations,
      };

  FlowRules _withDevices(
          FlowRules r, _DeviceFamily f, List<FlowDeviceRule> list) =>
      switch (f) {
        _DeviceFamily.source => r.copyWith(sourceDevices: list),
        _DeviceFamily.destination => r.copyWith(destinationDevices: list),
        _DeviceFamily.capture => r.copyWith(captureDestinations: list),
      };
}

enum _DeviceFamily { source, destination, capture }

/// Explains the one syntax every "which box" field uses.
const String kFlowTargetHelp =
    'Write DSPDEVICE_ for the family (the first block of it that fits), '
    'RECORDERDEVICE_1 for one block, input_doc_cam for the box that key '
    'places, or "AV Bridge 2x1" for a catalog model. Separate alternatives '
    'with | and they are tried in order.';
