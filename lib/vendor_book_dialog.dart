import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_port_editor.dart' show avRowIcon;
import 'contrast.dart';
import 'live_text_field.dart';
import 'vendor_book.dart';

/// ============================================================================
///  THE DEFAULT VENDOR EDITOR
/// ============================================================================
///  The companies this shop asks to quote, set up once and then on every job's
///  Packages tab without being retyped. Same shape as the delivery location
///  editor and the rate cards, and for the same reason: who the department
///  buys from is a fact about the department rather than about one job.
///
///  The file is meant to be SHARED. Point the path on App Config at a drive
///  everybody reads and every job starts from one directory, which is what
///  stops the same supplier being spelled three ways across three quote
///  comparisons.
///
///  IT NEVER OWNS A JOB'S VENDOR. What lands on a job is a copy: renaming it
///  there does not touch this list, and this list changing does not rewrite a
///  job that has already been quoted.
/// ============================================================================

Future<void> showVendorBookDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const VendorBookDialog(),
);

class VendorBookDialog extends StatefulWidget {
  const VendorBookDialog({super.key});

  @override
  State<VendorBookDialog> createState() => _VendorBookDialogState();
}

class _VendorBookDialogState extends State<VendorBookDialog> {
  /// Edits are in memory until Save, exactly as the rate cards work, so a
  /// half-typed rep's name is not on everybody's share yet.
  bool _dirty = false;

  final TextEditingController _newName = TextEditingController();

  @override
  void dispose() {
    _newName.dispose();
    super.dispose();
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? snackErrorFill(context) : null,
      ),
    );
  }

  void _edit(AppStateProvider provider, DefaultVendor vendor) {
    provider.vendorBook.upsert(vendor);
    setState(() => _dirty = true);
    provider.vendorBookChanged();
  }

  void _add(AppStateProvider provider) {
    final name = _newName.text.trim();
    if (name.isEmpty) return;
    if (provider.vendorBook.byName(name) != null) {
      _snack('$name is already on the list.');
      return;
    }
    provider.vendorBook.add(name: name);
    _newName.clear();
    setState(() => _dirty = true);
    provider.vendorBookChanged();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final book = provider.vendorBook;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const ValueKey('vendor_book_dialog'),
      title: Row(
        children: [
          const Text('Default vendors'),
          const SizedBox(width: 12),
          if (_dirty)
            Chip(
              // A chip that overrides its fill has to override its ink: the
              // theme's label color was measured against the default fill.
              label: Text(
                'Unsaved',
                style: TextStyle(
                  color: errorTextOn(
                    theme.colorScheme,
                    theme.colorScheme.errorContainer,
                  ),
                ),
              ),
              backgroundColor: theme.colorScheme.errorContainer,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      content: SizedBox(
        width: 880,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The companies this shop asks to quote. A new job starts with '
              'these on its Packages tab, and an older job can take any of '
              'them from the same tab. Editing a vendor on a job does not '
              'change this list.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 260,
                  child: Text('Company', style: theme.textTheme.labelSmall),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 260,
                  child: Text(
                    'Who a request goes to',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Notes', style: theme.textTheme.labelSmall),
                ),
                const SizedBox(width: 108),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView(
                children: [
                  if (book.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'No vendors saved yet. Add the companies the shop asks '
                        'to quote, and every new job starts with them instead '
                        'of the directory being retyped per building.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  for (final vendor in book.vendors)
                    Padding(
                      key: ValueKey('vendor_book_row_${vendor.id}'),
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 260,
                            child: LiveTextField(
                              fieldId: 'vbname_${vendor.id}',
                              initial: vendor.name,
                              hint: 'Extron',
                              onChanged: (v) =>
                                  _edit(provider, vendor.copyWith(name: v)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 260,
                            child: LiveTextField(
                              fieldId: 'vbcontact_${vendor.id}',
                              initial: vendor.contact,
                              hint: 'rep, or the quotes address',
                              onChanged: (v) =>
                                  _edit(provider, vendor.copyWith(contact: v)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: LiveTextField(
                              fieldId: 'vbnote_${vendor.id}',
                              initial: vendor.notes,
                              hint: 'account number, terms, what they are slow on',
                              onChanged: (v) =>
                                  _edit(provider, vendor.copyWith(notes: v)),
                            ),
                          ),
                          // THE ORDER IS THE ORDER A JOB IS SEEDED IN, so the
                          // two companies most packages go to belong at the
                          // top and it has to be possible to put them there.
                          avRowIcon(Icons.arrow_upward, 'Move up', () {
                            provider.vendorBook.move(vendor.id, up: true);
                            setState(() => _dirty = true);
                            provider.vendorBookChanged();
                          }),
                          avRowIcon(Icons.arrow_downward, 'Move down', () {
                            provider.vendorBook.move(vendor.id, up: false);
                            setState(() => _dirty = true);
                            provider.vendorBookChanged();
                          }),
                          avRowIcon(
                            Icons.delete_outline,
                            'Remove this company',
                            () {
                              provider.vendorBook.remove(vendor.id);
                              setState(() => _dirty = true);
                              provider.vendorBookChanged();
                            },
                            danger: true,
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      SizedBox(
                        width: 260,
                        child: TextField(
                          key: const ValueKey('vendor_book_new'),
                          controller: _newName,
                          decoration: const InputDecoration(
                            labelText: 'New company',
                            hintText: 'e.g. Extron',
                            isDense: true,
                          ),
                          onSubmitted: (_) => _add(provider),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        key: const ValueKey('vendor_book_add'),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add'),
                        onPressed: () => _add(provider),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    book.source.isEmpty ? 'Not saved yet' : book.source,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.disabledColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${book.count} vendor${book.count == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.disabledColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.folder_open, size: 18),
          label: const Text('Load...'),
          onPressed: () => _load(provider),
        ),
        TextButton.icon(
          icon: const Icon(Icons.save_as, size: 18),
          label: const Text('Save as...'),
          onPressed: () => _saveAs(provider),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        ElevatedButton(
          key: const ValueKey('vendor_book_save'),
          onPressed: () async {
            final saved = await provider.saveVendorBook();
            if (saved.isEmpty) {
              _snack('Could not save the vendor list.', error: true);
              return;
            }
            setState(() => _dirty = false);
            _snack('Default vendors saved to $saved');
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _load(AppStateProvider provider) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Open a vendor list',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    await provider.loadVendorBook(explicitPath: path);
    if (!mounted) return;
    setState(() => _dirty = false);
    _snack('Loaded ${provider.vendorBook.count} vendors from $path');
  }

  Future<void> _saveAs(AppStateProvider provider) async {
    String? output = await FilePicker.saveFile(
      dialogTitle: 'Save the vendor list as',
      fileName: 'vendor_list.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (output == null) return;
    if (!output.toLowerCase().endsWith('.json')) output += '.json';
    final saved = await provider.vendorBook.save(toPath: output);
    if (!mounted) return;
    if (saved.isEmpty) {
      _snack('Could not write the vendor list.', error: true);
      return;
    }
    setState(() => _dirty = false);
    provider.vendorBookChanged();
    showSavedFileSnack(context, provider, 'Default vendors', saved);
  }
}
