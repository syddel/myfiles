import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../util/format.dart';

/// The icon for a file kind; folders use the signed-in user's folder color.
class FileIcon extends StatelessWidget {
  const FileIcon(this.kind, {super.key, this.size = 28});

  final String kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final folderColor = context.select<AppState, String>((s) => s.folderColor);
    final style = kindIcon(kind, folderColor: folderColor);
    return Icon(style.icon, color: style.color, size: size);
  }
}
