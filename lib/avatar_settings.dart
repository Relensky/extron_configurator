import 'package:file_picker/file_picker.dart' show FileType;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'collab/collab_widgets.dart' show CollabAvatarCircle;
import 'file_dialogs.dart';

/// App Config: a picture in place of your initials where other people see
/// you have a file open. Kept in the Root Folder's assets\avatars.
class AvatarSettingsSection extends StatelessWidget {
  const AvatarSettingsSection({super.key});

  Future<void> _choose(BuildContext context, AppStateProvider provider) async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await pickFilesCompat(
      dialogTitle: 'Choose your avatar',
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg'],
    );
    final file = picked?.files.single.path;
    if (file == null) return;
    final problem = await provider.setMyAvatar(file);
    showTimedSnackBar(
      messenger,
      SnackBar(content: Text(problem.isEmpty ? 'Avatar set.' : problem)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final me = provider.collab.me.user;
    final picture = provider.myAvatarFile;
    return Column(
      key: const ValueKey('avatar_settings'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your avatar', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Shown instead of your initials when other people have the same '
          'file open. Saved in ${provider.avatarFolder}.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            CollabAvatarCircle(user: me, picture: picture, radius: 28),
            const SizedBox(width: 14),
            FilledButton.tonalIcon(
              key: const ValueKey('avatar_choose'),
              icon: const Icon(Icons.add_a_photo_outlined, size: 18),
              label: Text(picture == null ? 'Choose a picture' : 'Change'),
              onPressed: () => _choose(context, provider),
            ),
            if (picture != null) ...[
              const SizedBox(width: 8),
              TextButton.icon(
                key: const ValueKey('avatar_remove'),
                icon: const Icon(Icons.close, size: 18),
                label: const Text('Use initials'),
                onPressed: provider.removeMyAvatar,
              ),
            ],
          ],
        ),
      ],
    );
  }
}
