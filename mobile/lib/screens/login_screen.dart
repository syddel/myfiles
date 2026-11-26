import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';

/// Sign in (or register, if the server allows it).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  final _invite = TextEditingController();
  bool _register = false;
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    final app = context.read<AppState>();
    setState(() => _error = null);
    if (_username.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Enter your username and password');
      return;
    }
    if (_register && _password.text != _password2.text) {
      setState(() => _error = 'Passwords don\'t match');
      return;
    }
    setState(() => _busy = true);
    try {
      if (_register) {
        await app.register(_username.text.trim(), _password.text, _invite.text.trim());
      } else {
        await app.signIn(_username.text.trim(), _password.text);
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final config = app.config;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.folder_rounded, size: 56, color: theme.colorScheme.primary),
                    const SizedBox(height: 8),
                    Text(app.appName, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                    Text(
                      app.api?.server.toString() ?? '',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    if (app.startupError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        app.startupError!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 24),
                    TextField(
                      controller: _username,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
                      textInputAction: _register ? TextInputAction.next : TextInputAction.go,
                      onSubmitted: _register ? null : (_) => _submit(),
                      decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                    ),
                    if (_register) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password2,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: 'Repeat password', border: OutlineInputBorder()),
                      ),
                      if (config?.inviteRequired ?? false) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _invite,
                          decoration: const InputDecoration(labelText: 'Invite code', border: OutlineInputBorder()),
                        ),
                      ],
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(_register ? 'Create account' : 'Sign in'),
                    ),
                    if (config?.registrationOpen ?? false)
                      TextButton(
                        onPressed: () => setState(() {
                          _register = !_register;
                          _error = null;
                        }),
                        child: Text(_register ? 'Already registered? Sign in' : 'No account yet? Register'),
                      ),
                    TextButton(
                      onPressed: () => context.read<AppState>().changeServer(),
                      child: const Text('Use a different server'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
