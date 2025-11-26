import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class GraphBuilder {
  List<FlSpot> getGraphData(List<double> data) {
    if (data.isEmpty) return [];

    return List.generate(data.length, (index) {
      if (index >= data.length) {
        return FlSpot(index.toDouble(), 0.0);
      }
      return FlSpot(index.toDouble(), data[index]);
    });
  }

  double _niceStep(double range, {int targetCount = 6, bool forceInt = false}) {
    if (range == 0) return 1;

    final roughStep = range.abs() / targetCount;
    final exponent = math.pow(10, (math.log(roughStep) / math.ln10).floor());
    final fraction = roughStep / exponent;

    double niceFraction;
    if (fraction <= 1.5) {
      niceFraction = 1;
    } else if (fraction <= 3) {
      niceFraction = 2;
    } else if (fraction <= 7) {
      niceFraction = 5;
    } else {
      niceFraction = 10;
    }

    final step = niceFraction * exponent;
    if (forceInt && step < 1) return 1;
    return forceInt ? step.ceilToDouble() : step;
  }

  List<double> _buildTickValues(
    double min,
    double max, {
    int targetCount = 6,
    bool integerOnly = false,
  }) {
    if (min == max) {
      return [min];
    }

    final step = _niceStep(
      max - min,
      targetCount: targetCount,
      forceInt: integerOnly,
    );
    final start = (min / step).floorToDouble() * step;
    final end = (max / step).ceilToDouble() * step;

    final ticks = <double>[];
    double current = start;
    while (current <= end + (step * 0.5)) {
      ticks.add(integerOnly ? current.roundToDouble() : current);
      current += step;
    }

    return ticks;
  }

  bool _isCloseToTick(double value, List<double> ticks) {
    for (final tick in ticks) {
      if ((value - tick).abs() < (tick.abs() + 1) * 1e-3) {
        return true;
      }
    }
    return false;
  }

  Widget buildGraph(
    List<double> data, {
    Color color = Colors.blue,
    List<int>? peakIndices,
    List<int>? valleyIndices,
    String xLabel = 'Muestras',
    String yLabel = 'Amplitud',
    double? meanValue,
  }) {
    if (data.isEmpty) {
      return SizedBox(
        height: 300,
        child: const Center(
          child: Text(
            'No hay datos para mostrar',
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }

    final minYData = data.reduce(math.min);
    final maxYData = data.reduce(math.max);
    final padding =
        ((maxYData - minYData).abs() * 0.05).clamp(0.01, double.infinity);
    final minY = minYData - padding;
    final maxY = maxYData + padding;

    final yTicks = _buildTickValues(minY, maxY);
    final double maxX = data.length > 1 ? (data.length - 1).toDouble() : 1.0;
    final xTicks = _buildTickValues(
      0,
      maxX,
      targetCount: 7,
      integerOnly: true,
    );

    final filteredPeaks = (peakIndices ?? [])
        .where((i) => i >= 0 && i < data.length)
        .map((i) => FlSpot(i.toDouble(), data[i]))
        .toList();
    final filteredValleys = (valleyIndices ?? [])
        .where((i) => i >= 0 && i < data.length)
        .map((i) => FlSpot(i.toDouble(), data[i]))
        .toList();

    return SizedBox(
      height: 300,
      child: InteractiveViewer(
        clipBehavior: Clip.none,
        minScale: 1,
        maxScale: 6,
        boundaryMargin: const EdgeInsets.all(48),
        child: LineChart(
          LineChartData(
            backgroundColor: Colors.white,
            minX: 0,
            maxX: maxX,
            minY: minY,
            maxY: maxY,
          lineBarsData: [
            LineChartBarData(
              spots: getGraphData(data),
              isCurved: false,
              barWidth: 2.2,
              color: color,
              dotData: FlDotData(
                show: data.length <= 120,
                getDotPainter: (spot, percent, barData, index) {
                  return FlDotCirclePainter(
                    radius: 2.6,
                    color: Colors.white,
                    strokeWidth: 1.2,
                    strokeColor: Colors.black87,
                  );
                },
              ),
              belowBarData: BarAreaData(
                show: true,
                color: color.withOpacity(0.05),
              ),
            ),
            if (filteredPeaks.isNotEmpty)
              LineChartBarData(
                spots: filteredPeaks,
                isCurved: false,
                barWidth: 0,
                color: Colors.transparent,
                dotData: FlDotData(
                  show: true,
                  getDotPainter: (spot, percent, barData, index) {
                    return FlDotCirclePainter(
                      radius: 4,
                      color: Colors.white,
                      strokeWidth: 2,
                      strokeColor: Colors.green.shade700,
                    );
                  },
                ),
              ),
            if (filteredValleys.isNotEmpty)
              LineChartBarData(
                spots: filteredValleys,
                isCurved: false,
                barWidth: 0,
                color: Colors.transparent,
                dotData: FlDotData(
                  show: true,
                  getDotPainter: (spot, percent, barData, index) {
                    return FlDotCirclePainter(
                      radius: 4,
                      color: Colors.white,
                      strokeWidth: 2,
                      strokeColor: Colors.red.shade700,
                    );
                  },
                ),
              ),
          ],
          gridData: FlGridData(
            show: true,
            drawVerticalLine: true,
            drawHorizontalLine: true,
            getDrawingHorizontalLine: (value) {
              return FlLine(
                color: Colors.grey.shade400.withOpacity(0.6),
                strokeWidth: 0.8,
                dashArray: [4, 4],
              );
            },
            getDrawingVerticalLine: (value) {
              return FlLine(
                color: Colors.grey.shade400.withOpacity(0.6),
                strokeWidth: 0.8,
                dashArray: [4, 4],
              );
            },
          ),
          borderData: FlBorderData(
            show: true,
            border: const Border(
              left: BorderSide(color: Colors.black, width: 1.6),
              bottom: BorderSide(color: Colors.black, width: 1.6),
              right: BorderSide(color: Colors.transparent),
              top: BorderSide(color: Colors.transparent),
            ),
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 52,
                getTitlesWidget: (value, meta) {
                  if (!_isCloseToTick(value, yTicks)) return const SizedBox();
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      value.toStringAsFixed(2),
                      style: const TextStyle(
                        color: Colors.black87,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 42,
                getTitlesWidget: (value, meta) {
                  if (!_isCloseToTick(value, xTicks)) return const SizedBox();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      value.toInt().toString(),
                      style: const TextStyle(
                        color: Colors.black87,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                },
              ),
            ),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          extraLinesData: ExtraLinesData(
            horizontalLines: [
              if (meanValue != null)
                HorizontalLine(
                  y: meanValue,
                  color: Colors.grey.shade700,
                  strokeWidth: 1,
                  dashArray: [8, 6],
                  label: HorizontalLineLabel(show: false),
                ),
              if (minY <= 0 && maxY >= 0)
                HorizontalLine(
                  y: 0,
                  color: Colors.black.withOpacity(0.6),
                  strokeWidth: 1,
                  dashArray: [6, 6],
                ),
            ],
          ),
          // Desactivar gestos internos de fl_chart para que InteractiveViewer maneje zoom/pan.
          lineTouchData: const LineTouchData(
            enabled: false,
            handleBuiltInTouches: false,
          ),
        ),
      ),
    ),
  );
  }
}
