import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// Signed in, but the server can't be reached (e.g. the phone has no network
/// yet). The session is kept; this tries again by itself.
class OfflineScreen extends StatelessWidget {
  const OfflineScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.cloud_off_rounded, size: 64, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  Text('Can\'t reach the server', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text(app.api?.server.toString() ?? '', textAlign: TextAlign.center, style: muted),
                  if (app.startupError != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      app.startupError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'You\'re still signed in. The app keeps trying, and connects as soon as the server can be reached.',
                    textAlign: TextAlign.center,
                    style: muted,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: app.reconnecting ? null : app.retryConnection,
                    child: app.reconnecting
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Try again'),
                  ),
                  TextButton(onPressed: app.changeServer, child: const Text('Use a different server')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
