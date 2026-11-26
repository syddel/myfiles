import 'package:material_ui/material_ui.dart';

import '../api/models.dart';

/// "1.4 MB", using 1024-based units like the website.
String formatSize(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value < 10 ? value.toStringAsFixed(1) : value.round()} ${units[i]}';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "14:03" today, "3 Sep" this year, "3 Sep 2024" otherwise.
String formatDate(DateTime date, {DateTime? now}) {
  now ??= DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  if (date.year == now.year && date.month == now.month && date.day == now.day) {
    return '${two(date.hour)}:${two(date.minute)}';
  }
  final dayMonth = '${date.day} ${_months[date.month - 1]}';
  return date.year == now.year ? dayMonth : '$dayMonth ${date.year}';
}

String plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

/// Icon and color for a file kind. Folders use the user's folder color.
({IconData icon, Color color}) kindIcon(String kind, {String folderColor = 'amber'}) {
  switch (kind) {
    case 'folder':
      return (icon: Icons.folder_rounded, color: folderColors[folderColor]?.color ?? folderColors['amber']!.color);
    case 'pdf':
      return (icon: Icons.picture_as_pdf_outlined, color: const Color(0xFFEF4444));
    case 'image':
      return (icon: Icons.image_outlined, color: const Color(0xFF059669));
    case 'audio':
      return (icon: Icons.audio_file_outlined, color: const Color(0xFFA855F7));
    case 'video':
      return (icon: Icons.video_file_outlined, color: const Color(0xFFF43F5E));
    case 'text':
      return (icon: Icons.description_outlined, color: const Color(0xFF64748B));
    case 'archive':
      return (icon: Icons.folder_zip_outlined, color: const Color(0xFFEA580C));
    default:
      return (icon: Icons.insert_drive_file_outlined, color: const Color(0xFF94A3B8));
  }
}

/// The 20 folder colors offered on the website (same keys and order).
const folderColors = <String, ({String label, Color color})>{
  'amber': (label: 'Yellow', color: Color(0xFFF59E0B)),
  'yellow': (label: 'Lemon', color: Color(0xFFEAB308)),
  'orange': (label: 'Orange', color: Color(0xFFF97316)),
  'red': (label: 'Red', color: Color(0xFFEF4444)),
  'rose': (label: 'Rose', color: Color(0xFFF43F5E)),
  'pink': (label: 'Pink', color: Color(0xFFEC4899)),
  'fuchsia': (label: 'Magenta', color: Color(0xFFD946EF)),
  'purple': (label: 'Purple', color: Color(0xFFA855F7)),
  'violet': (label: 'Violet', color: Color(0xFF8B5CF6)),
  'indigo': (label: 'Indigo', color: Color(0xFF6366F1)),
  'blue': (label: 'Blue', color: Color(0xFF3B82F6)),
  'sky': (label: 'Sky', color: Color(0xFF0EA5E9)),
  'cyan': (label: 'Cyan', color: Color(0xFF06B6D4)),
  'teal': (label: 'Teal', color: Color(0xFF14B8A6)),
  'emerald': (label: 'Emerald', color: Color(0xFF10B981)),
  'green': (label: 'Green', color: Color(0xFF22C55E)),
  'lime': (label: 'Lime', color: Color(0xFF84CC16)),
  'brown': (label: 'Brown', color: Color(0xFFB45309)),
  'gray': (label: 'Gray', color: Color(0xFFA1A1AA)),
  'charcoal': (label: 'Charcoal', color: Color(0xFF52525B)),
};

/// Subtitle for a list row: "1.4 MB · 3 Sep" (folders: just the date).
String nodeSubtitle(Node node) =>
    node.isDir ? formatDate(node.updatedAt) : '${formatSize(node.size)} · ${formatDate(node.updatedAt)}';
