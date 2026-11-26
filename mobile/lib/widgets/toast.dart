import 'dart:async';

import 'package:material_ui/material_ui.dart';

/// A small rounded message just under the top bar, in the app's
/// colours. Tap it to close it; it also fades out after [duration].
/// Only one shows at a time.
void showToast(
  BuildContext context,
  String message, {
  IconData icon = Icons.check_circle_outline,
  Duration duration = const Duration(seconds: 4),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _current?.dismiss();
  late final OverlayEntry entry;
  final key = GlobalKey<_ToastState>();
  entry = OverlayEntry(
    builder: (_) => _Toast(key: key, message: message, icon: icon, duration: duration, onGone: () => entry.remove()),
  );
  _current = _ToastHandle(key);
  overlay.insert(entry);
}

_ToastHandle? _current;

class _ToastHandle {
  _ToastHandle(this.key);
  final GlobalKey<_ToastState> key;
  void dismiss() => key.currentState?.dismiss(immediately: true);
}

class _Toast extends StatefulWidget {
  const _Toast({super.key, required this.message, required this.icon, required this.duration, required this.onGone});

  final String message;
  final IconData icon;
  final Duration duration;
  final VoidCallback onGone;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 200))..forward();
  Timer? _timer;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, dismiss);
  }

  Future<void> dismiss({bool immediately = false}) async {
    if (_gone) return;
    _gone = true;
    _timer?.cancel();
    if (!immediately && mounted) await _fade.reverse();
    widget.onGone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Positioned(
      left: 24,
      right: 24,
      // Just under the top bar, clear of bottom sheets, the + button and the mini player.
      top: MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
      child: Center(
        child: FadeTransition(
          opacity: _fade,
          child: Semantics(
            liveRegion: true,
            button: true,
            hint: 'Tap to close',
            child: GestureDetector(
              onTap: dismiss,
              child: Material(
                color: scheme.primaryContainer,
                elevation: 3,
                shadowColor: Colors.black45,
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, size: 20, color: scheme.onPrimaryContainer),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          widget.message,
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onPrimaryContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
