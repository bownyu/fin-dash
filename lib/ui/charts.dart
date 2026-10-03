import 'dart:math';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'design.dart';

class RingChart extends StatefulWidget {
  final List<(int, Color)> segments;
  final Widget center;
  final ValueChanged<int>? onSegmentTap;
  const RingChart({
    super.key,
    required this.segments,
    required this.center,
    this.onSegmentTap,
  });
  @override
  State<RingChart> createState() => _RingChartState();
}

class _RingChartState extends State<RingChart>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  )..value = 1;
  late List<(int, Color)> previous = widget.segments;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    animation.duration = Duration(
      milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 300,
    );
  }

  List<(int, Color)> get interpolated {
    return blend(previous, widget.segments, animation.value);
  }

  List<(int, Color)> blend(
    List<(int, Color)> from,
    List<(int, Color)> to,
    double progress,
  ) => [
    for (var i = 0; i < max(from.length, to.length); i++)
      (
        ((i < from.length ? from[i].$1 : 0) * (1 - progress) +
                (i < to.length ? to[i].$1 : 0) * progress)
            .round(),
        i < to.length ? to[i].$2 : from[i].$2,
      ),
  ];
  @override
  void didUpdateWidget(covariant RingChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.segments, widget.segments)) {
      // Capture the old visible values even if the previous transition was interrupted.
      previous = blend(previous, oldWidget.segments, animation.value);
      animation.forward(from: 0);
    }
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  void select(TapUpDetails details) {
    if (animation.isAnimating) return;
    final point = details.localPosition - const Offset(109, 109);
    if (point.distance < 72 || point.distance > 109) return;
    final total = widget.segments.fold<int>(0, (sum, s) => sum + s.$1);
    if (total <= 0) return;
    final angle = (atan2(point.dy, point.dx) + pi / 2 + 2 * pi) % (2 * pi);
    var end = 0.0;
    for (var index = 0; index < widget.segments.length; index++) {
      end += 2 * pi * widget.segments[index].$1 / total;
      if (angle <= end) {
        widget.onSegmentTap?.call(index);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 236,
    child: Center(
      child: SizedBox.square(
        dimension: 218,
        child: GestureDetector(
          onTapUp: widget.onSegmentTap == null ? null : select,
          child: AnimatedBuilder(
            animation: animation,
            child: Center(child: SizedBox(width: 152, child: widget.center)),
            builder: (context, child) => CustomPaint(
              painter: _RingPainter(
                interpolated,
                Theme.of(context).dividerColor.withValues(alpha: .12),
              ),
              child: child,
            ),
          ),
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
      if (s.$1 <= 0) continue;
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

class TrendChart extends StatefulWidget {
  final List<int> values;
  final List<String> labels;
  final List<String>? pointLabels;
  const TrendChart({
    super.key,
    required this.values,
    required this.labels,
    this.pointLabels,
  });
  @override
  State<TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<TrendChart> {
  int? selected;
  @override
  void didUpdateWidget(covariant TrendChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.values, widget.values) ||
        !listEquals(oldWidget.pointLabels, widget.pointLabels)) {
      selected = null;
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SizedBox(
        height: 100,
        width: double.infinity,
        child: LayoutBuilder(
          builder: (context, box) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: widget.values.isEmpty
                ? null
                : (details) => setState(
                    () => selected =
                        (details.localPosition.dx /
                                box.maxWidth *
                                (widget.values.length - 1))
                            .round()
                            .clamp(0, widget.values.length - 1),
                  ),
            child: AnimatedSwitcher(
              duration: Duration(
                milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 250,
              ),
              child: SizedBox.expand(
                key: ValueKey(Object.hashAll(widget.values)),
                child: CustomPaint(painter: _TrendPainter(widget.values)),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: widget.labels
            .map((s) => Text(s, style: Theme.of(context).textTheme.bodySmall))
            .toList(),
      ),
      const SizedBox(height: 8),
      Text(
        selected == null
            ? '点击曲线查看具体金额'
            : '${widget.pointLabels?[selected!] ?? '第 ${selected! + 1} 项'} · ${privateMoney(context, widget.values[selected!])}',
        style: Theme.of(context).textTheme.bodySmall,
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
