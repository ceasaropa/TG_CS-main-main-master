import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'fingerprint_sample.dart';

class FingerprintRepository extends ChangeNotifier {
  final List<FingerprintSample> _samples = [];

  List<FingerprintSample> get samples => List.unmodifiable(_samples);

  void saveSample({
    required LatLng position,
    required Map<String, int> rssiByBssid,
    Map<String, double>? rssiStdByBssid,
    String? floor,
    String? notes,
  }) {
    _samples.add(
      FingerprintSample(
        position: position,
        timestamp: DateTime.now(),
        rssiByBssid: Map<String, int>.from(rssiByBssid),
        rssiStdByBssid: rssiStdByBssid,
        floor: floor,
        notes: notes,
      ),
    );
    notifyListeners();
  }

  void removeSample(FingerprintSample sample) {
    _samples.remove(sample);
    notifyListeners();
  }

  void clear() {
    _samples.clear();
    notifyListeners();
  }

  void replaceAll(Iterable<FingerprintSample> samples) {
    _samples
      ..clear()
      ..addAll(samples);
    notifyListeners();
  }

  List<Map<String, Object?>> toJsonList() =>
      _samples.map((sample) => sample.toJson()).toList(growable: false);
}
