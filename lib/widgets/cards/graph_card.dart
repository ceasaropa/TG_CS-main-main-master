import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:proyecto_imu_v1_3/widgets/graphbuilder.dart';

class GraphCard extends StatelessWidget {
  final String title;
  final List<double> data;
  final Color color;
  final GraphBuilder graphBuilder;
  final double peakThreshold;
  final double valleyThreshold;

  const GraphCard({
    super.key,
    required this.title,
    required this.data,
    required this.color,
    required this.graphBuilder,
    this.peakThreshold = 0.1,
    this.valleyThreshold = -0.1,
  });

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const SizedBox.shrink();

    final analysisResults = _analyzePeaksAndValleys(
      data,
      peakThreshold,
      valleyThreshold,
    );
    final double meanValue =
        data.reduce((a, b) => a + b) / (data.isNotEmpty ? data.length : 1);
    final peakIndices = analysisResults['peakIndices'] as List<int>;
    final valleyIndices = analysisResults['valleyIndices'] as List<int>;

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.1), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${data.length} puntos',
                  style: TextStyle(
                    fontSize: 12,
                    color: color,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            height: 280,
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.black.withOpacity(0.1),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: graphBuilder.buildGraph(
              data,
              color: color,
              peakIndices: peakIndices,
              valleyIndices: valleyIndices,
              xLabel: 'Muestras',
              yLabel: 'Amplitud',
              meanValue: meanValue,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildStatInfo(
                'Min',
                data.reduce((a, b) => a < b ? a : b).toStringAsFixed(3),
              ),
              _buildStatInfo(
                'Max',
                data.reduce((a, b) => a > b ? a : b).toStringAsFixed(3),
              ),
              _buildStatInfo(
                'Prom. Picos',
                (analysisResults['peaks'] as List<double>).isNotEmpty
                    ? ((analysisResults['peaks'] as List<double>).reduce(
                              (a, b) => a + b,
                            ) /
                            (analysisResults['peaks'] as List<double>).length)
                        .toStringAsFixed(3)
                    : '0.000',
              ),
              _buildStatInfo(
                'Prom. Valles',
                (analysisResults['valleys'] as List<double>).isNotEmpty
                    ? ((analysisResults['valleys'] as List<double>).reduce(
                              (a, b) => a + b,
                            ) /
                            (analysisResults['valleys'] as List<double>).length)
                        .toStringAsFixed(3)
                    : '0.000',
              ),
            ],
          ),
          if (analysisResults['peaks'].isNotEmpty ||
              analysisResults['valleys'].isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.white.withOpacity(0.1),
                  width: 1,
                ),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.trending_up,
                        color: color.withOpacity(0.8),
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Analisis de variabilidad',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withOpacity(0.9),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildPeakValleyInfo(
                          'Picos',
                          analysisResults['peaks'].length,
                          analysisResults['peakRange'],
                          Icons.keyboard_arrow_up,
                          Colors.green.withOpacity(0.8),
                          'Rango',
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 40,
                        color: Colors.white.withOpacity(0.1),
                      ),
                      Expanded(
                        child: _buildPeakValleyInfo(
                          'Valles',
                          analysisResults['valleys'].length,
                          analysisResults['valleyRange'],
                          Icons.keyboard_arrow_down,
                          Colors.red.withOpacity(0.8),
                          'Rango',
                        ),
                      ),
                    ],
                  ),
                  if (analysisResults['peaks'].isNotEmpty &&
                      analysisResults['valleys'].isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildSmallMetric(
                          'Rango P-V',
                          (analysisResults['peakValleyRange'] as double)
                              .toStringAsFixed(2),
                          Icons.height,
                        ),
                        _buildSmallMetric(
                          'Estabilidad',
                          (analysisResults['stabilityIndex'] as double)
                              .toStringAsFixed(2),
                          Icons.balance,
                        ),
                        _buildSmallMetric(
                          'Regularidad',
                          (analysisResults['regularityIndex'] as double)
                              .toStringAsFixed(2),
                          Icons.linear_scale,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatInfo(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.6)),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildPeakValleyInfo(
    String label,
    int count,
    double range,
    IconData icon,
    Color iconColor,
    String metricLabel,
  ) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: iconColor, size: 16),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withOpacity(0.7),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '$count',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        Text(
          '$metricLabel: ${range.toStringAsFixed(3)}',
          style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.6)),
        ),
      ],
    );
  }

  Widget _buildSmallMetric(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: Colors.white.withOpacity(0.6), size: 14),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 9, color: Colors.white.withOpacity(0.5)),
        ),
      ],
    );
  }

  Map<String, dynamic> _analyzePeaksAndValleys(
    List<double> data,
    double peakThreshold,
    double valleyThreshold,
  ) {
    if (data.length < 5) {
      return {
        'peaks': <double>[],
        'valleys': <double>[],
        'peakIndices': <int>[],
        'valleyIndices': <int>[],
        'peakRange': 0.0,
        'valleyRange': 0.0,
        'peakValleyRange': 0.0,
        'stabilityIndex': 0.0,
        'regularityIndex': 0.0,
      };
    }

    final List<double> peaks = [];
    final List<double> valleys = [];
    final List<int> peakIndices = [];
    final List<int> valleyIndices = [];

    for (int i = 2; i < data.length - 2; i++) {
      final bool isPeak =
          data[i] > data[i - 1] &&
          data[i] > data[i + 1] &&
          data[i] > data[i - 2] &&
          data[i] > data[i + 2] &&
          data[i] >= peakThreshold;

      final bool isValley =
          data[i] < data[i - 1] &&
          data[i] < data[i + 1] &&
          data[i] < data[i - 2] &&
          data[i] < data[i + 2] &&
          data[i] <= valleyThreshold;

      if (isPeak) {
        peaks.add(data[i]);
        peakIndices.add(i);
      } else if (isValley) {
        valleys.add(data[i]);
        valleyIndices.add(i);
      }
    }

    double peakRange = 0.0;
    double valleyRange = 0.0;

    if (peaks.length >= 2) {
      final double maxPeak = peaks.reduce((a, b) => a > b ? a : b);
      final double minPeak = peaks.reduce((a, b) => a < b ? a : b);
      peakRange = maxPeak - minPeak;
    }

    if (valleys.length >= 2) {
      final double maxValley = valleys.reduce((a, b) => a > b ? a : b);
      final double minValley = valleys.reduce((a, b) => a < b ? a : b);
      valleyRange = maxValley - minValley;
    }

    double peakValleyRange = 0.0;
    double stabilityIndex = 0.0;
    double regularityIndex = 0.0;

    if (peaks.isNotEmpty && valleys.isNotEmpty) {
      final double maxPeak = peaks.reduce((a, b) => a > b ? a : b);
      final double minValley = valleys.reduce((a, b) => a < b ? a : b);
      peakValleyRange = maxPeak - minValley;

      final double totalRange = peakRange + valleyRange;
      final double maxPossibleRange = peakValleyRange * 2;
      if (maxPossibleRange > 0) {
        stabilityIndex = 1.0 - (totalRange / maxPossibleRange);
        stabilityIndex = stabilityIndex.clamp(0.0, 1.0);
      }

      if (peakIndices.length > 1 && valleyIndices.length > 1) {
        final List<int> peakDistances = [];
        final List<int> valleyDistances = [];

        for (int i = 1; i < peakIndices.length; i++) {
          peakDistances.add(peakIndices[i] - peakIndices[i - 1]);
        }

        for (int i = 1; i < valleyIndices.length; i++) {
          valleyDistances.add(valleyIndices[i] - valleyIndices[i - 1]);
        }

        final double peakDistanceVariation = _calculateVariationInt(
          peakDistances,
        );
        final double valleyDistanceVariation = _calculateVariationInt(
          valleyDistances,
        );

        regularityIndex =
            1.0 - ((peakDistanceVariation + valleyDistanceVariation) / 2.0);
        regularityIndex = regularityIndex.clamp(0.0, 1.0);
      }
    }

    return {
      'peaks': peaks,
      'valleys': valleys,
      'peakIndices': peakIndices,
      'valleyIndices': valleyIndices,
      'peakRange': peakRange,
      'valleyRange': valleyRange,
      'peakValleyRange': peakValleyRange,
      'stabilityIndex': stabilityIndex,
      'regularityIndex': regularityIndex,
    };
  }

  double _calculateVariationInt(List<int> values) {
    if (values.length < 2) return 0.0;

    final double mean =
        values.reduce((a, b) => a + b) / (values.isNotEmpty ? values.length : 1);
    if (mean == 0) return 0.0;

    double sumSquaredDiffs = 0.0;
    for (int value in values) {
      sumSquaredDiffs += math.pow(value - mean, 2);
    }

    final double variance = sumSquaredDiffs / values.length;
    final double stdDev = math.sqrt(variance);

    return stdDev / mean.abs();
  }
}
