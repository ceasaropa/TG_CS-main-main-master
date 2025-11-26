import 'package:latlong2/latlong.dart';

class FingerprintSample {
  FingerprintSample({
    required this.position,
    required this.timestamp,
    required Map<String, int> rssiByBssid,
    Map<String, double>? rssiStdByBssid,
    this.floor,
    this.notes,
  })  : rssiByBssid =
            Map.unmodifiable(Map<String, int>.from(rssiByBssid)),
        rssiStdByBssid = Map.unmodifiable(
          Map<String, double>.from(rssiStdByBssid ?? const {}),
        );

  /// Position in meters using a simple plane: x -> east (lng), y -> north (lat)
  /// Store as LatLng(y, x) to comply with LatLng signature (lat, lng)
  final LatLng position;
  final DateTime timestamp;
  final Map<String, int> rssiByBssid;
  final Map<String, double> rssiStdByBssid;

  final String? floor;
  final String? notes;

  Map<String, Object?> toJson() => {
        'x': position.longitude,
        'y': position.latitude,
        'timestamp': timestamp.toIso8601String(),
        'rssiByBssid': rssiByBssid,
        if (floor != null) 'floor': floor,
        if (notes != null) 'notes': notes,
      };

  factory FingerprintSample.fromJson(Map<String, dynamic> json) {
    final x = (json['x'] as num?)?.toDouble() ?? 0;
    final y = (json['y'] as num?)?.toDouble() ?? 0;
    final timestampRaw = json['timestamp'];
    final timestamp = timestampRaw is String
        ? DateTime.tryParse(timestampRaw) ?? DateTime.now()
        : DateTime.now();
    final rssi = <String, int>{};
    final rawMap = json['rssiByBssid'];
    if (rawMap is Map) {
      rawMap.forEach((key, value) {
        if (key is String && value is num) {
          rssi[key] = value.round();
        }
      });
    }
    final rssiStd = <String, double>{};
    final rawStdMap = json['rssiStdByBssid'];
    if (rawStdMap is Map) {
      rawStdMap.forEach((key, value) {
        if (key is String && value is num) {
          rssiStd[key] = value.toDouble();
        }
      });
    }

    return FingerprintSample(
      position: LatLng(y, x),
      timestamp: timestamp,
      rssiByBssid: rssi,
      rssiStdByBssid: rssiStd,
      floor: json['floor'] as String?,
      notes: json['notes'] as String?,
    );
  }
}
