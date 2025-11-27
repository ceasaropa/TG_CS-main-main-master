import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Repository to load and save obstacles. It prefers a local file in
/// the application's documents directory and falls back to a bundled
/// asset `assets/obst/obstacles.json`.
class ObstaclesRepository {
  final String _fileName = 'obstacles.json';
  final String _assetPath = 'assets/obst/obstacles.json';

  Future<Set<Point<int>>> load() async {
    final dir = await getApplicationDocumentsDirectory();
    final localFile = File('${dir.path}/$_fileName');

    if (await localFile.exists()) {
      try {
        final contents = await localFile.readAsString();
        final decoded = jsonDecode(contents) as List<dynamic>;
        return _decode(decoded);
      } catch (_) {
        // fall through to asset
      }
    }

    final decoded = await _loadFromAsset();
    return _decode(decoded);
  }

  /// Force loading exclusively from bundled asset, ignoring local storage.
  Future<Set<Point<int>>> loadFromAssetOnly() async {
    final decoded = await _loadFromAsset();
    return _decode(decoded);
  }

  Future<List<dynamic>> _loadFromAsset() async {
    final str = await rootBundle.loadString(_assetPath);
    return jsonDecode(str) as List<dynamic>;
  }

  Set<Point<int>> _decode(List<dynamic> decoded) {
    final Set<Point<int>> result = {};
    for (var item in decoded) {
      try {
        final x = item['x'];
        final y = item['y'];
        if (x is int && y is int) {
          result.add(Point<int>(x, y));
        } else if (x is num && y is num) {
          result.add(Point<int>(x.toInt(), y.toInt()));
        }
      } catch (_) {
        // ignore malformed entries
      }
    }
    return result;
  }

  Future<void> save(Set<Point<int>> obstacles) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_fileName');
    final list = obstacles.map((p) => {'x': p.x, 'y': p.y}).toList();
    await file.writeAsString(jsonEncode(list));
  }
}
