import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A ring chart of a few slices, drawn so the largest slice starts at twelve
/// o'clock and runs clockwise.
///
/// Hand-painted rather than pulled in as a dependency: a donut is a sweep angle
/// per slice and there is nothing here a chart package would improve.
class DonutChart extends StatelessWidget {
  const DonutChart({
    super.key,
    required this.slices,
    required this.center,
    this.size = 148,
    this.thickness = 22,
  });

  /// One entry per segment. Zero and negative values are ignored, so a caller
  /// can pass raw numbers without filtering first.
  final List<DonutSlice> slices;

  /// Text in the hole.
  final Widget center;

  final double size;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final visible = slices
        .where((s) => s.value > 0)
        .toList(growable: false);
    if (visible.isEmpty) return SizedBox(width: size, height: size);

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DonutPainter(slices: visible, thickness: thickness),
        child: Center(
          child: Padding(padding: EdgeInsets.all(thickness + 8), child: center),
        ),
      ),
    );
  }
}

class DonutSlice {
  const DonutSlice({required this.value, required this.color, this.label});

  final double value;
  final Color color;
  final String? label;
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter({required this.slices, required this.thickness});

  final List<DonutSlice> slices;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold<double>(0, (sum, s) => sum + s.value);
    if (total <= 0) return;

    final rect = Rect.fromLTWH(0, 0, size.width, size.height)
        .deflate(thickness / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.butt;

    // A gap between slices reads as a separator without needing a border.
    const gap = 0.014;
    var start = -math.pi / 2;
    for (final slice in slices) {
      final sweep = slice.value / total * 2 * math.pi;
      paint.color = slice.color;
      canvas.drawArc(rect, start, math.max(sweep - gap, 0.004), false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.slices != slices || old.thickness != thickness;
}

/// A vertical bar chart with an optional target line.
///
/// Used for spending per day. Bars are drawn by the caller with Flex, so this
/// only adds the axis furniture: a baseline, gridlines and the peak label.
class ChartFrame extends StatelessWidget {
  const ChartFrame({
    super.key,
    required this.child,
    this.axisLabels = const [],
    this.baselineLabel,
  });

  final Widget child;

  /// Optional labels drawn under the bars, evenly spread.
  final List<String> axisLabels;

  final String? baselineLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (baselineLabel != null) ...[
          Text(
            baselineLabel!,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
        ],
        SizedBox(height: 108, child: child),
        if (axisLabels.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              for (final label in axisLabels)
                Expanded(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                      fontSize: 10,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A filled area chart, drawn with a path. Good for a series with many points
/// where bars would turn into a comb.
class AreaChart extends StatelessWidget {
  const AreaChart({
    super.key,
    required this.values,
    required this.color,
    this.peakLabel,
  });

  final List<double> values;
  final Color color;
  final String? peakLabel;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _AreaPainter(values: values, color: color),
      child: const SizedBox.expand(),
    );
  }
}

class _AreaPainter extends CustomPainter {
  const _AreaPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || size.isEmpty) return;
    final peak = values.fold<double>(0, math.max);
    if (peak <= 0) return;

    // Leave headroom so the tallest point does not touch the frame.
    final top = size.height * 0.12;
    final usable = size.height - top;
    final dx = size.width / (values.length - 1);

    final points = <Offset>[
      for (var i = 0; i < values.length; i++)
        Offset(
          i * dx,
          top + usable * (1 - values[i] / peak),
        ),
    ];

    final line = Path()..moveTo(points.first.dx, points.first.dy);
    // Smooth with quadratic midpoints so the curve cannot overshoot into
    // negative territory the way a naive cubic can.
    for (var i = 0; i < points.length - 1; i++) {
      final current = points[i];
      final next = points[i + 1];
      final midX = (current.dx + next.dx) / 2;
      line.quadraticBezierTo(midX, current.dy, midX, (current.dy + next.dy) / 2);
      line.quadraticBezierTo(midX, next.dy, next.dx, next.dy);
    }

    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.35), color.withValues(alpha: 0.02)],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );

    // Mark the peak, which is the one point people look for.
    final peakIndex = values.indexOf(peak);
    if (peakIndex >= 0) {
      canvas.drawCircle(
        points[peakIndex],
        3.5,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_AreaPainter old) =>
      old.values != values || old.color != color;
}

/// One row of a ranked breakdown: a label, a proportional bar and the numbers.
class RankedBar extends StatelessWidget {
  const RankedBar({
    super.key,
    required this.label,
    required this.sublabel,
    required this.fraction,
    required this.value,
    required this.color,
    this.emphasis = false,
  });

  final String label;
  final String sublabel;

  /// 0..1 of the largest row, used for the bar width.
  final double fraction;

  final String value;
  final Color color;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: emphasis ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: emphasis
                      ? color
                      : theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: fraction.clamp(0.0, 1.0),
                    minHeight: 5,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (sublabel.isNotEmpty)
                Text(
                  sublabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}