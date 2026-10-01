import 'dart:math';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'design.dart';

class RingChart extends StatelessWidget {
  final List<(int, Color)> segments;
  final Widget center;
  const RingChart({super.key, required this.segments, required this.center});
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 236,
    child: Center(
      child: SizedBox.square(
        dimension: 218,
        child: CustomPaint(
          painter: _RingPainter(
            segments,
            Theme.of(context).dividerColor.withValues(alpha: .12),
          ),
          child: Center(child: SizedBox(width: 152, child: center)),
        ),
      ),
    ),
  );
}

class _RingPainter extends CustomPainter {
  final List<(int, Color)> segments;
  final Color empty;
  _RingPainter(List<(int, Color)> segments, this.empty)
    : segments = List.unmodifiable(segments);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(12, 12, size.width - 24, size.height - 24);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18
      ..strokeCap = StrokeCap.round;
    final total = segments.fold<int>(0, (sum, s) => sum + s.$1);
    if (total == 0) {
      canvas.drawArc(rect, 0, 2 * pi, false, paint..color = empty);
      return;
    }
    var start = -pi / 2;
    for (final s in segments) {
      final angle = 2 * pi * s.$1 / total;
      final gap = segments.length > 1 ? min(.045, angle * .15) : 0.0;
      canvas.drawArc(
        rect,
        start + gap / 2,
        angle - gap,
        false,
        paint..color = s.$2,
      );
      start += angle;
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.empty != empty || !listEquals(old.segments, segments);
}

class TrendChart extends StatelessWidget {
  final List<int> values;
  final List<String> labels;
  const TrendChart({super.key, required this.values, required this.labels});
  @override
  Widget build(BuildContext context) => Column(
    children: [
      SizedBox(
        height: 100,
        width: double.infinity,
        child: CustomPaint(painter: _TrendPainter(values)),
      ),
      const SizedBox(height: 10),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: labels
            .map((s) => Text(s, style: Theme.of(context).textTheme.bodySmall))
            .toList(),
      ),
    ],
  );
}

class _TrendPainter extends CustomPainter {
  final List<int> values;
  _TrendPainter(List<int> values) : values = List.unmodifiable(values);
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = muted.withValues(alpha: .12)
      ..strokeWidth = 1;
    for (var i = 0; i < 3; i++) {
      final y = i * (size.height - 12) / 2 + 6;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (values.isEmpty) return;
    final largest = max(1, values.reduce(max));
    final points = [
      for (var i = 0; i < values.length; i++)
        Offset(
          values.length < 2
              ? size.width / 2
              : i * size.width / (values.length - 1),
          size.height - 6 - values[i] / largest * (size.height - 16),
        ),
    ];
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    final fill = Path.from(path)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            primary.withValues(alpha: .24),
            primary.withValues(alpha: .01),
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_TrendPainter old) => !listEquals(old.values, values);
}
