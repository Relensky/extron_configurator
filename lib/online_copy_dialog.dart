import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'contrast.dart';
import 'online_copy.dart';

/// ============================================================================
///  PUBLISHING THE JOB WHERE OTHER PEOPLE CAN READ IT
/// ============================================================================
///  The box behind the Project tab's "Online copy" button. It asks for one
///  thing — which folder — and then does the same thing every time it is
///  pressed afterwards.
///
///  A FOLDER, NOT AN ACCOUNT. OneDrive and Google Drive both keep a folder on
///  this machine in step with the cloud, so a file written into one is a file
///  that opens in Excel Online or as a Google Sheet minutes later. That is why
///  there is nothing here to sign into, nothing to renew, and nothing that
///  stops working when somebody's password changes — see online_copy.dart.
///
///  IT SAYS OUT LOUD THAT IT ONLY GOES ONE WAY. The single thing a person can
///  reasonably assume about a spreadsheet in a shared folder is that typing in
///  it does something. Here it does not: the copy is overwritten on the next
///  publish, and this box says so before it writes anything, because finding
///  that out afterwards means finding it out by losing an afternoon of
///  somebody's edits.
/// ============================================================================

/// Opens the publish box.
Future<void> showOnlineCopyDialog(
  BuildContext context,
  AppStateProvider provider,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _OnlineCopyDialog(provider: provider),
  );
}

class _OnlineCopyDialog extends StatefulWidget {
  final AppStateProvider provider;

  const _OnlineCopyDialog({required this.provider});

  @override
  State<_OnlineCopyDialog> createState() => _OnlineCopyDialogState();
}

class _OnlineCopyDialogState extends State<_OnlineCopyDialog> {
  late String _folder = widget.provider.project.onlineFolder;

  /// Write the project file beside the workbook.
  ///
  /// On by default: it is what makes the folder enough to OPEN the job on
  /// another machine rather than only enough to read a spreadsheet, and it
  /// costs one small file.
  bool _includeProject = true;

  bool _busy = false;
  String _result = '';
  bool _failed = false;

  Future<void> _pickFolder() async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: 'Which folder does OneDrive or Google Drive sync?',
    );
    if (picked == null || !mounted) return;
    setState(() => _folder = picked);
  }

  Future<void> _publish() async {
    if (_folder.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _result = '';
      _failed = false;
    });
    final result = await widget.provider.publishOnlineCopy(
      folder: _folder,
      includeProjectFile: _includeProject,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = result.written.isEmpty;
      _result = result.written.isEmpty
          ? 'Nothing could be written: ${result.failed.join('; ')}'
          : result.failed.isEmpty
          ? '${result.written.join(' and ')} written.'
          : '${result.written.join(' and ')} written. '
                'Failed: ${result.failed.join('; ')}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final project = widget.provider.project;
    final surface =
        theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface;
    final ready = _folder.trim().isNotEmpty && !_busy;

    return AlertDialog(
      key: const ValueKey('online_copy_dialog'),
      title: const Text('Online copy'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Writes the project workbook into a folder that OneDrive or '
                'Google Drive keeps in sync, so the job can be read in Excel '
                'Online or opened as a Google Sheet by anybody the folder is '
                'shared with.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              // The two things somebody has to know before they rely on it,
              // and both are easier to say now than to explain afterwards.
              _Point(
                icon: Icons.link,
                text: 'The same file name is rewritten every time, so a share '
                    'link sent once keeps opening the current figures.',
              ),
              _Point(
                icon: Icons.edit_off_outlined,
                text: 'It only goes one way. Edits made in Excel Online or '
                    'Google Sheets are not read back, and the next publish '
                    'overwrites them.',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Folder',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      child: Text(
                        _folder.trim().isEmpty
                            ? 'None picked yet'
                            : _folder.trim(),
                        key: const ValueKey('online_copy_folder'),
                        overflow: TextOverflow.ellipsis,
                        style: _folder.trim().isEmpty
                            ? theme.textTheme.bodyMedium?.copyWith(
                                fontStyle: FontStyle.italic,
                                color: muted,
                              )
                            : theme.textTheme.bodyMedium,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('online_copy_pick'),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Choose'),
                    onPressed: _busy ? null : _pickFolder,
                  ),
                ],
              ),
              CheckboxListTile(
                key: const ValueKey('online_copy_include_project'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _includeProject,
                title: const Text('Put the project file there too'),
                subtitle: Text(
                  'A copy of ${onlineProjectFileName(project)}, so the job can '
                  'be opened from the folder on another machine as well as '
                  'read as a spreadsheet.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _includeProject = v ?? false),
              ),
              const SizedBox(height: 8),
              Text(
                'Writes ${onlineWorkbookName(project)}'
                '${_includeProject ? ' and ${onlineProjectFileName(project)}' : ''}'
                '.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              const SizedBox(height: 4),
              Text(
                onlineFreshnessText(project.onlinePublishedAt),
                key: const ValueKey('online_copy_freshness'),
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              if (_result.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _result,
                  key: const ValueKey('online_copy_result'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _failed
                        ? errorTextOn(theme.colorScheme, surface)
                        : successOn(surface),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          key: const ValueKey('online_copy_publish'),
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_sync_outlined, size: 18),
          label: Text(
            project.onlinePublishedAt == null ? 'Publish' : 'Update it',
          ),
          onPressed: ready ? _publish : null,
        ),
      ],
    );
  }
}

/// One line of "here is what this actually does", with its icon.
class _Point extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Point({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}
