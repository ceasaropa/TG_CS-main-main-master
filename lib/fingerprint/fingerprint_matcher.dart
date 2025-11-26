import 'dart:math' as math;
import 'fingerprint_sample.dart';

class FingerprintMatcherResult {
  const FingerprintMatcherResult({
    required this.best,
    required this.distance,
  });
  final FingerprintSample best;
  final double distance;
}

class FingerprintMatcher {
  /// Returns the closest sample by Euclidean distance in RSSI space.
  /// current: map of BSSID -> RSSI (dBm)
  FingerprintMatcherResult? match(
    Map<String, int> current,
    List<FingerprintSample> samples,
  ) {
    if (samples.isEmpty) return null;
    FingerprintSample? bestSample;
    double bestDistance = double.infinity;

    for (final sample in samples) {
      final d = _euclideanRssiDistance(current, sample.rssiByBssid);
      if (d < bestDistance) {
        bestDistance = d;
        bestSample = sample;
      }
    }

    if (bestSample == null) return null;
    return FingerprintMatcherResult(best: bestSample, distance: bestDistance);
  }

  double _euclideanRssiDistance(
    Map<String, int> a,
    Map<String, int> b,
  ) {
    // Union of keys
    final keys = <String>{...a.keys, ...b.keys};
    double sumSq = 0;
    for (final k in keys) {
      final va = a[k];
      final vb = b[k];
      // If missing, treat as very low signal/no detection
      final da = va ?? -100;
      final db = vb ?? -100;
      final diff = (da - db).toDouble();
      sumSq += diff * diff;
    }
    return sumSq == 0 ? 0 : math.sqrt(sumSq);
  }
}
