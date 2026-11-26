import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../util/format.dart';
import '../widgets/dialogs.dart';
import 'shares_screen.dart';

/// Storage use, appearance, password, shared links and signing out.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  Stats? _stats;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().api!.stats().then((s) {
      if (mounted) setState(() => _stats = s);
    }, onError: (_) {});
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) showError(context, e.message);
    }
  }

  Future<void> _changePassword() async {
    final changed = await showDialog<bool>(context: context, builder: (_) => const _PasswordDialog());
    if ((changed ?? false) && mounted) showMessage(context, 'Password changed');
  }

  Future<void> _signOut() async {
    final app = context.read<AppState>();
    if (app.uploads?.active.isNotEmpty ?? false) {
      final ok = await confirm(
        context,
        title: 'Sign out?',
        message: 'Uploads still running will be cancelled.',
        confirmLabel: 'Sign out',
      );
      if (!ok) return;
    }
    await app.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final user = app.user!;
    final theme = Theme.of(context);
    final stats = _stats;
    final quota = stats?.quotaBytes;
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ListTile(
            leading: CircleAvatar(child: Text(user.username.characters.first.toUpperCase())),
            title: Text(user.username, style: theme.textTheme.titleMedium),
            subtitle: Text(app.api!.server.toString()),
          ),
          const Divider(),
          _Heading('Storage'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: stats == null
                ? const LinearProgressIndicator()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (quota != null && quota > 0) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            minHeight: 8,
                            value: (stats.usedBytes / quota).clamp(0, 1),
                            color: stats.usedBytes >= quota ? theme.colorScheme.error : null,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('${formatSize(stats.usedBytes)} of ${formatSize(quota)} used'),
                      ] else
                        Text('${formatSize(stats.usedBytes)} used'),
                      Text(
                        plural(stats.fileCount, 'file'),
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 8),
          const Divider(),
          _Heading('Theme'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
                ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
              ],
              selected: {app.themeMode},
              onSelectionChanged: (s) => _run(() => app.setTheme(AppState.themeKey(s.first))),
            ),
          ),
          const SizedBox(height: 8),
          _Heading('Folder color'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              children: [
                for (final MapEntry(key: key, value: c) in folderColors.entries)
                  Tooltip(
                    message: c.label,
                    child: InkResponse(
                      onTap: () => _run(() => app.setFolderColor(key)),
                      radius: 24,
                      child: Container(
                        width: 44,
                        height: 44,
                        margin: const EdgeInsets.all(2),
                        decoration: app.folderColor == key
                            ? BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: theme.colorScheme.onSurface, width: 2),
                              )
                            : null,
                        child: Icon(Icons.folder_rounded, color: c.color, size: 30),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Shared links'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SharesScreen())),
          ),
          ListTile(leading: const Icon(Icons.password), title: const Text('Change password'), onTap: _changePassword),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Change server'),
            onTap: () async {
              final ok = await confirm(
                context,
                title: 'Change server?',
                message: 'You\'ll be signed out of ${app.api!.server.host}.',
                confirmLabel: 'Change server',
              );
              if (ok) await app.changeServer();
            },
          ),
          ListTile(
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: Text('Sign out', style: TextStyle(color: theme.colorScheme.error)),
            onTap: _signOut,
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _repeat = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _save() async {
    if (_next.text != _repeat.text) {
      setState(() => _error = 'New passwords don\'t match');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().api!.changePassword(_current.text, _next.text);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change password'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _current,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Current password'),
          ),
          TextField(
            controller: _next,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'New password'),
          ),
          TextField(
            controller: _repeat,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Repeat new password'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Change')),
      ],
    );
  }
}
