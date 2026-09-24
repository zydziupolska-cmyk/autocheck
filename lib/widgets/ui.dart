import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Płaski panel z cienką linią — podstawowy blok interfejsu.
/// [stripe] — pasek statusu po lewej (np. usterka), zamiast barwienia całego panelu.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? stripe;
  final EdgeInsetsGeometry? margin;

  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.stripe, this.margin});

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: stripe == null
          ? content
          : IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [Container(width: 3, color: stripe), Expanded(child: content)],
              ),
            ),
    );
  }
}

/// Mały podpis sekcji (zwykła wielkość liter).
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(text, style: AppTheme.label)),
          ?trailing,
        ],
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  final Color color;
  final double size;
  const StatusDot(this.color, {super.key, this.size = 8});

  @override
  Widget build(BuildContext context) =>
      Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

/// Krótki komunikat z paskiem statusu po lewej.
class Notice extends StatelessWidget {
  final String text;
  final Color tone;
  final IconData? icon;
  const Notice(this.text, {super.key, this.tone = AppTheme.textSecondary, this.icon});

  @override
  Widget build(BuildContext context) {
    return Panel(
      stripe: tone,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: tone),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(text, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, height: 1.35))),
        ],
      ),
    );
  }
}

/// Odczyt: podpis, wartość cyframi o stałej szerokości, jednostka.
class Readout extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final String? note;
  final Color? noteColor;
  final Color valueColor;
  final double size;

  const Readout({
    super.key,
    required this.label,
    required this.value,
    this.unit = "",
    this.note,
    this.noteColor,
    this.valueColor = AppTheme.textPrimary,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11.5)),
        const SizedBox(height: 2),
        Text.rich(
          TextSpan(children: [
            TextSpan(text: value, style: AppTheme.readout.copyWith(fontSize: size, color: valueColor)),
            if (unit.isNotEmpty)
              TextSpan(text: " $unit", style: const TextStyle(color: AppTheme.textMuted, fontSize: 12, fontWeight: FontWeight.w500)),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (note != null)
          Text(note!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: noteColor ?? AppTheme.textMuted, fontSize: 11, fontFeatures: AppTheme.tabular)),
      ],
    );
  }
}

/// Znak Dynomic: pierścień z przebiegiem „pulsu”.
class DynomicMark extends StatelessWidget {
  final double size;
  final Color color;
  const DynomicMark({super.key, this.size = 22, this.color = AppTheme.accent});

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _MarkPainter(color));
}

class _MarkPainter extends CustomPainter {
  final Color color;
  _MarkPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    // Rysunek w układzie 40×40 (środek 0,0), jak w logo na dynomic.pro
    final k = size.width / 40;
    canvas.translate(size.width / 2, size.height / 2);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(Offset.zero, 17 * k, p);
    final pts = const [Offset(-11, 2), Offset(-6, 2), Offset(-2, -7), Offset(3, 8), Offset(7, -2), Offset(11, -2)];
    final path = Path()..moveTo(pts.first.dx * k, pts.first.dy * k);
    for (final o in pts.skip(1)) {
      path.lineTo(o.dx * k, o.dy * k);
    }
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}

/// Nagłówek z marką: znak + „Dynomic” + „Diag”.
class BrandTitle extends StatelessWidget {
  const BrandTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DynomicMark(size: 24),
        SizedBox(width: 8),
        Text("Dynomic", style: TextStyle(color: AppTheme.textPrimary, fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
        SizedBox(width: 6),
        Text("Diag", style: TextStyle(color: AppTheme.textSecondary, fontSize: 17, fontWeight: FontWeight.w400)),
      ],
    );
  }
}
