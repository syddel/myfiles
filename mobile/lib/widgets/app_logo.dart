import 'package:material_ui/material_ui.dart';

/// The app icon: the website's folder (frontend/public/favicon.svg), in orange.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.width = 108});

  /// Same size as the native splash screen's icon, so the hand-over is seamless.
  final double width;

  static const color = Color(0xFFF97316);

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(width, width * 16 / 18), painter: const _FolderPainter());
}

class _FolderPainter extends CustomPainter {
  const _FolderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // The SVG path, in its 24×24 viewBox; the folder spans x 3–21, y 4–20.
    final path = Path()
      ..moveTo(3, 6.5)
      ..arcToPoint(const Offset(5.5, 4), radius: const Radius.circular(2.5))
      ..lineTo(9.7, 4)
      ..cubicTo(10.3, 4, 10.9, 4.3, 11.3, 4.7)
      ..lineTo(12.8, 6)
      ..lineTo(18.5, 6)
      ..arcToPoint(const Offset(21, 8.5), radius: const Radius.circular(2.5))
      ..lineTo(21, 17.5)
      ..arcToPoint(const Offset(18.5, 20), radius: const Radius.circular(2.5))
      ..lineTo(5.5, 20)
      ..arcToPoint(const Offset(3, 17.5), radius: const Radius.circular(2.5))
      ..close();
    canvas
      ..scale(size.width / 18, size.height / 16)
      ..translate(-3, -4)
      ..drawPath(path, Paint()..color = AppLogo.color);
  }

  @override
  bool shouldRepaint(_FolderPainter oldDelegate) => false;
}
