import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wifi_scan/wifi_scan.dart';

import 'fingerprint_repository.dart';
import 'fingerprint_sample.dart';

class FingerprintTrainingScreen extends StatefulWidget {
  const FingerprintTrainingScreen({
    super.key,
    this.widthMeters = 85.42,
    this.heightMeters = 33.79,
    this.imageAssetPath = 'assets/planta1.png',
    this.repository,
  });

  final double widthMeters;
  final double heightMeters;
  final String imageAssetPath;
  final FingerprintRepository? repository;

  @override
  State<FingerprintTrainingScreen> createState() =>
      _FingerprintTrainingScreenState();
}

enum _MonitoringMode { none, quick }

class _FingerprintTrainingScreenState extends State<FingerprintTrainingScreen> {
  static const Duration _quickScanInterval = Duration(milliseconds: 300);

  late final FingerprintRepository _repository;
  final MapController _mapController = MapController();
  final TextEditingController _xController = TextEditingController();
  final TextEditingController _yController = TextEditingController();

  late double _mapWidthMeters;
  late double _mapHeightMeters;
  List<WiFiAccessPoint> _lastResults = const [];
  Map<String, int> _lastLevels = const {};
  final Set<String> _selectedBssids = <String>{};
  LatLng? _selectedPosition;
  bool _hasFloorAsset = false;
  bool _isScanning = false;
  bool _isCapturing = false;
  String? _statusMessage;
  DateTime? _lastScanTime;
  Duration _captureDuration = const Duration(minutes: 2);
  int _signalChangeCount = 0;

  _MonitoringMode _monitoringMode = _MonitoringMode.none;
  bool _pendingAutoScan = false;
  Duration _monitoringElapsed = Duration.zero;
  Timer? _monitoringTimer;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? FingerprintRepository();
    _mapWidthMeters = widget.widthMeters;
    _mapHeightMeters = widget.heightMeters;
    _selectedPosition = _centerPoint;
    _updateCoordinateFields(_selectedPosition!);
    unawaited(_checkPermissions());
    unawaited(_checkAsset());
  }

  LatLng get _centerPoint => LatLng(_mapHeightMeters / 2, _mapWidthMeters / 2);

  @override
  void dispose() {
    _monitoringTimer?.cancel();
    _xController.dispose();
    _yController.dispose();
    super.dispose();
  }

  Future<void> _checkPermissions() async {
    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      setState(() {
        _statusMessage = 'Se requiere permiso de ubicacion para escanear WiFi.';
      });
      return;
    }
    unawaited(_scanOnce());
  }

  Future<void> _checkAsset() async {
    try {
      await rootBundle.load(widget.imageAssetPath);
      if (mounted) {
        setState(() => _hasFloorAsset = true);
      }
    } catch (_) {
      if (mounted) setState(() => _hasFloorAsset = false);
    }
  }

  bool _is24GHz(WiFiAccessPoint ap) =>
      ap.frequency >= 2400 && ap.frequency < 2500;

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  String _formatElapsed(Duration duration) {
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  bool _haveLevelsChanged(Map<String, int> previous, Map<String, int> current) {
    if (previous.length != current.length) return true;
    for (final entry in current.entries) {
      if (previous[entry.key] != entry.value) return true;
    }
    for (final key in previous.keys) {
      if (!current.containsKey(key)) return true;
    }
    return false;
  }

  void _scheduleNextAutoScan() {
    if (_monitoringMode != _MonitoringMode.quick ||
        _pendingAutoScan ||
        _isScanning) {
      return;
    }
    _pendingAutoScan = true;
    Future.delayed(_quickScanInterval, () async {
      _pendingAutoScan = false;
      if (!mounted || _monitoringMode != _MonitoringMode.quick) return;
      await _scanOnce(wait: const Duration(milliseconds: 120));
    });
  }

  void _startMonitoringTimer() {
    _monitoringTimer?.cancel();
    _monitoringTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _monitoringMode != _MonitoringMode.quick) return;
      setState(() {
        _monitoringElapsed += const Duration(seconds: 1);
      });
    });
  }

  void _stopMonitoring() {
    _monitoringMode = _MonitoringMode.none;
    _pendingAutoScan = false;
    _monitoringElapsed = Duration.zero;
    _monitoringTimer?.cancel();
    _monitoringTimer = null;
    _signalChangeCount = 0;
    setState(() {});
  }

  void _toggleQuickMonitoring() {
    if (_monitoringMode == _MonitoringMode.quick) {
      _stopMonitoring();
      return;
    }
    setState(() {
      _monitoringMode = _MonitoringMode.quick;
      _signalChangeCount = 0;
      _monitoringElapsed = Duration.zero;
      _pendingAutoScan = false;
      _statusMessage = 'Monitoreo rapido activado';
    });
    _startMonitoringTimer();
    unawaited(_scanOnce());
  }

  Future<void> _scanOnce({
    Duration wait = const Duration(milliseconds: 250),
  }) async {
    if (_isScanning) return;
    setState(() {
      _isScanning = true;
      _statusMessage =
          _monitoringMode == _MonitoringMode.quick
              ? 'Monitoreo rapido...'
              : 'Escaneando redes...';
    });

    try {
      final canStart = await WiFiScan.instance.canStartScan(
        askPermissions: false,
      );
      if (canStart != CanStartScan.yes) {
        throw Exception('No se puede iniciar escaneo (${canStart.name}).');
      }

      final started = await WiFiScan.instance.startScan();
      if (!started) throw Exception('El escaneo no pudo iniciarse.');

      await Future.delayed(wait);
      final results = await WiFiScan.instance.getScannedResults();
      final filtered =
          results.where(_is24GHz).toList()
            ..sort((a, b) => b.level.compareTo(a.level));

      if (_selectedBssids.isEmpty && filtered.isNotEmpty) {
        _selectedBssids.addAll(filtered.take(4).map((e) => e.bssid));
      }

      final currentLevels = {for (final ap in filtered) ap.bssid: ap.level};
      final changed = _haveLevelsChanged(_lastLevels, currentLevels);

      setState(() {
        _lastResults = filtered;
        _lastLevels = currentLevels;
        if (changed) _signalChangeCount++;
        _lastScanTime = DateTime.now();
        if (filtered.isEmpty) {
          _statusMessage = 'Sin redes 2.4 GHz encontradas';
        } else {
          final timeText = _formatTime(_lastScanTime!);
          _statusMessage =
              _monitoringMode == _MonitoringMode.quick
                  ? 'Monitoreo rapido (actualizado $timeText)'
                  : 'Lecturas listas (actualizado $timeText)';
        }
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error escaneando: $e';
      });
    } finally {
      setState(() {
        _isScanning = false;
      });
      _scheduleNextAutoScan();
    }
  }

  Future<Map<String, int>> _collectAverageLevels(
    Duration duration, {
    Duration? wait,
  }) async {
    final end = DateTime.now().add(duration);
    final accumulator = <String, List<int>>{};
    final sampleWait = wait ?? _quickScanInterval;

    while (DateTime.now().isBefore(end)) {
      await _scanOnce(wait: sampleWait);
      _pendingAutoScan = false; // evitar disparos automáticos durante captura
      for (final entry in _lastLevels.entries) {
        if (_selectedBssids.isNotEmpty &&
            !_selectedBssids.contains(entry.key)) {
          continue;
        }
        accumulator.putIfAbsent(entry.key, () => []).add(entry.value);
      }
      await Future.delayed(sampleWait);
    }

    final averages = <String, int>{};
    accumulator.forEach((bssid, levels) {
      if (levels.isEmpty) return;
      final mean = levels.reduce((a, b) => a + b) / levels.length;
      averages[bssid] = mean.round();
    });
    return averages;
  }

  Future<void> _captureFingerprint() async {
    final position = _selectedPosition;
    if (position == null) {
      _showSnack('Selecciona coordenadas válidas antes de capturar.');
      return;
    }
    if (_selectedBssids.isEmpty) {
      _showSnack('Selecciona al menos una red antes de capturar.');
      return;
    }
    if (_isCapturing) return;

    setState(() {
      _isCapturing = true;
      _statusMessage = 'Capturando huella...';
    });

    try {
      _monitoringMode = _MonitoringMode.quick;
      _monitoringElapsed = Duration.zero;
      _startMonitoringTimer();
      final averages = await _collectAverageLevels(_captureDuration);
      _stopMonitoring();
      if (averages.isEmpty) {
        _showSnack('No se obtuvieron lecturas.');
      } else {
        _repository.saveSample(position: position, rssiByBssid: averages);
        _showSnack(
          'Huella guardada en (${position.longitude.toStringAsFixed(2)}, '
          '${position.latitude.toStringAsFixed(2)}).',
        );
      }
    } catch (e) {
      _showSnack('Error al capturar: $e');
    } finally {
      setState(() {
        _isCapturing = false;
      });
    }
  }

  Future<void> _exportJson() async {
    final samples = _repository.samples;
    if (samples.isEmpty) {
      _showSnack('No hay huellas para exportar.');
      return;
    }

    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File('${directory.path}/fingerprints_$timestamp.json');
    final payload = {
      'generatedAt': DateTime.now().toIso8601String(),
      'areaMeters': {'width': _mapWidthMeters, 'height': _mapHeightMeters},
      'samples': _repository.toJsonList(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    _showSnack('Exportado a ${file.path}');
  }

  Future<void> _loadDataset() async {
    if (_isCapturing) {
      _showSnack('Espera a que finalice la captura actual.');
      return;
    }
    final directory = await getApplicationDocumentsDirectory();
    if (!await directory.exists()) {
      _showSnack('No se encontraron datasets guardados.');
      return;
    }

    final files =
        await directory
            .list()
            .where((e) => e is File && e.path.toLowerCase().endsWith('.json'))
            .cast<File>()
            .toList();
    if (files.isEmpty) {
      _showSnack('No se encontraron datasets guardados.');
      return;
    }

    final selected = await showDialog<File?>(
      context: context,
      builder:
          (context) => SimpleDialog(
            title: const Text('Selecciona dataset'),
            children: [
              ...files.map(
                (file) => SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(file),
                  child: Text(p.basename(file.path)),
                ),
              ),
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancelar'),
              ),
            ],
          ),
    );

    if (selected == null) return;

    try {
      final raw = await selected.readAsString();
      final data = jsonDecode(raw);
      if (data is! Map || data['samples'] is! List) {
        throw const FormatException('Formato inválido');
      }
      final samples =
          (data['samples'] as List)
              .whereType<Map>()
              .map(
                (item) => FingerprintSample.fromJson(
                  item.map((k, v) => MapEntry(k.toString(), v)),
                ),
              )
              .toList();
      _repository.replaceAll(samples);
      if (samples.isNotEmpty) {
        _selectedPosition = samples.first.position;
        _updateCoordinateFields(_selectedPosition!);
      }
      _showSnack('Dataset cargado (${samples.length} huellas).');
    } catch (e) {
      _showSnack('Error cargando dataset: $e');
    }
  }

  void _clearSamples() {
    if (_repository.samples.isEmpty) {
      _showSnack('No hay huellas para limpiar.');
      return;
    }
    _repository.clear();
    _showSnack('Huellas eliminadas.');
  }

  void _updateCoordinateFields(LatLng point) {
    _xController.text = point.longitude.toStringAsFixed(2);
    _yController.text = point.latitude.toStringAsFixed(2);
  }

  void _onCoordinateChanged() {
    final x = double.tryParse(_xController.text.replaceAll(',', '.'));
    final y = double.tryParse(_yController.text.replaceAll(',', '.'));
    if (x == null || y == null) return;
    setState(() {
      _selectedPosition = LatLng(y, x);
    });
  }

  void _onMapTap(TapPosition tap, LatLng point) {
    setState(() {
      _selectedPosition = point;
    });
    _updateCoordinateFields(point);
  }

  List<LatLng> get _bounds => [
    const LatLng(0, 0),
    LatLng(0, _mapWidthMeters),
    LatLng(_mapHeightMeters, _mapWidthMeters),
    LatLng(_mapHeightMeters, 0),
  ];

  List<Polyline> get _gridLines {
    const double spacing = 1; // 1 m grid
    final polylines = <Polyline>[];
    for (double x = spacing; x < _mapWidthMeters; x += spacing) {
      polylines.add(
        Polyline(
          points: [
            LatLng(0, x),
            LatLng(_mapHeightMeters, x),
          ],
          color: Colors.grey.withOpacity(0.2),
          strokeWidth: 0.5,
        ),
      );
    }
    for (double y = spacing; y < _mapHeightMeters; y += spacing) {
      polylines.add(
        Polyline(
          points: [
            LatLng(y, 0),
            LatLng(y, _mapWidthMeters),
          ],
          color: Colors.grey.withOpacity(0.2),
          strokeWidth: 0.5,
        ),
      );
    }
    return polylines;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildScanList() {
    if (_lastResults.isEmpty) {
      return const Center(child: Text('Sin redes para mostrar.'));
    }
    return ListView.separated(
      itemCount: _lastResults.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final ap = _lastResults[index];
        final selected = _selectedBssids.contains(ap.bssid);
        return CheckboxListTile(
          dense: true,
          value: selected,
          onChanged: (checked) {
            setState(() {
              if (checked ?? false) {
                _selectedBssids.add(ap.bssid);
              } else {
                _selectedBssids.remove(ap.bssid);
              }
            });
          },
          title: Text(
            ap.ssid.isNotEmpty ? ap.ssid : 'Red oculta (${ap.bssid})',
          ),
          subtitle: Text('BSSID: ${ap.bssid}'),
          secondary: Text('${ap.level} dBm'),
        );
      },
    );
  }

  Widget _buildMap() {
    final selected = _selectedPosition ?? _centerPoint;
    final bounds = LatLngBounds.fromPoints(_bounds);

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          crs: const CrsSimple(),
          initialCenter: selected,
          minZoom: -4, // allow zooming further out
          maxZoom: 6,
          initialZoom: 0,
          onTap: _onMapTap,
        ),
        children: [
          if (_hasFloorAsset)
            OverlayImageLayer(
              overlayImages: [
                OverlayImage(
                  bounds: bounds,
                  opacity: 1,
                  imageProvider: AssetImage(widget.imageAssetPath),
                ),
              ],
            ),
          PolygonLayer(
            polygons: [
              Polygon(
                points: _bounds,
                color: Colors.blue.withOpacity(0.05),
                borderColor: Colors.blueGrey,
                borderStrokeWidth: 2,
              ),
            ],
          ),
          PolylineLayer(polylines: _gridLines),
          AnimatedBuilder(
            animation: _repository,
            builder: (context, _) {
              return MarkerLayer(
                markers: [
                  for (final sample in _repository.samples)
                    Marker(
                      point: sample.position,
                      width: 16,
                      height: 16,
                      child: const Icon(
                        Icons.circle,
                        size: 10,
                        color: Colors.purple,
                      ),
                    ),
                  Marker(
                    point: selected,
                    width: 28,
                    height: 28,
                    child: const Icon(Icons.place, color: Colors.red),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSamplesList() {
    return AnimatedBuilder(
      animation: _repository,
      builder: (context, _) {
        final items = _repository.samples;
        if (items.isEmpty) {
          return const Text('Aún no hay huellas guardadas.');
        }
        return SizedBox(
          height: 200,
          child: ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final sample = items[index];
              final coords =
                  'X=${sample.position.longitude.toStringAsFixed(2)} · Y=${sample.position.latitude.toStringAsFixed(2)}';
              final entries =
                  sample.rssiByBssid.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value));
              return ListTile(
                leading: const Icon(Icons.place, color: Colors.deepPurple),
                title: Text(coords),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sample.timestamp.toLocal().toString()),
                    const SizedBox(height: 6),
                    if (entries.isEmpty)
                      const Text('Sin redes asociadas')
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children:
                            entries.map((entry) {
                              return Chip(
                                label: Text(
                                  '${entry.key} (${entry.value} dBm)',
                                ),
                              );
                            }).toList(),
                      ),
                  ],
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _repository.removeSample(sample),
                ),
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final elapsedLabel =
        _lastScanTime != null
            ? 'Ultimo escaneo: ${_lastScanTime!.toLocal().toIso8601String().split('T').last.split('.').first}'
            : 'Sin escanear';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Entrenamiento WiFi'),
        actions: [
          IconButton(
            tooltip: 'Cargar dataset',
            icon: const Icon(Icons.folder_open),
            onPressed: _loadDataset,
          ),
          IconButton(
            tooltip: 'Exportar JSON',
            icon: const Icon(Icons.save_alt),
            onPressed: _exportJson,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 900;
          final scanSection = Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _scanOnce,
                          icon:
                              _isScanning
                                  ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                  : const Icon(Icons.wifi_find),
                          label: Text(
                            _isScanning ? 'Escaneando...' : 'Escanear redes',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _isCapturing ? null : _captureFingerprint,
                        icon:
                            _isCapturing
                                ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.fingerprint),
                        label: const Text('Capturar huella'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _toggleQuickMonitoring,
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          _monitoringMode == _MonitoringMode.quick
                              ? Colors.green
                              : Colors.blueAccent,
                      foregroundColor: Colors.white,
                    ),
                    icon: Icon(
                      _monitoringMode == _MonitoringMode.quick
                          ? Icons.pause_circle
                          : Icons.play_circle,
                    ),
                    label: Text(
                      _monitoringMode == _MonitoringMode.quick
                          ? 'Detener monitoreo rapido'
                          : 'Monitoreo rapido (${_quickScanInterval.inMilliseconds} ms)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Duracion monitoreo: ${_formatElapsed(_monitoringElapsed)}',
                  ),
                  Text('Cambios detectados: $_signalChangeCount'),
                  Text(elapsedLabel),
                  if (_statusMessage != null)
                    Text(
                      _statusMessage!,
                      style: const TextStyle(color: Colors.blueGrey),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(height: 220, child: _buildScanList()),
                ],
              ),
            ),
          );

          final mapSection = Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Coordenadas (m)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _xController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'X (Este)',
                          ),
                          onChanged: (_) => _onCoordinateChanged(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _yController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Y (Norte)',
                          ),
                          onChanged: (_) => _onCoordinateChanged(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (!_hasFloorAsset)
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.yellow.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Plano no encontrado (${widget.imageAssetPath}). Se muestra la grilla vacía.',
                      ),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(height: 260, child: _buildMap()),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            final bounds = LatLngBounds.fromPoints(_bounds);
                            _mapController.fitCamera(
                              CameraFit.bounds(
                                bounds: bounds,
                                padding: const EdgeInsets.all(24),
                              ),
                            );
                          },
                          icon: const Icon(Icons.zoom_out_map),
                          label: const Text('Ajustar mapa'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final selected = await showDialog<Duration>(
                            context: context,
                            builder:
                                (context) => SimpleDialog(
                                  title: const Text('Duración de captura'),
                                  children: [
                                    for (final option in [
                                      const Duration(seconds: 15),
                                      const Duration(seconds: 30),
                                      const Duration(minutes: 1),
                                    ])
                                      SimpleDialogOption(
                                        onPressed:
                                            () => Navigator.of(
                                              context,
                                            ).pop(option),
                                        child: Text(
                                          option.inSeconds >= 60
                                              ? '${option.inMinutes} min'
                                              : '${option.inSeconds} s',
                                        ),
                                      ),
                                    SimpleDialogOption(
                                      onPressed:
                                          () => Navigator.of(context).pop(),
                                      child: const Text('Cancelar'),
                                    ),
                                  ],
                                ),
                          );
                          if (selected != null) {
                            setState(() => _captureDuration = selected);
                          }
                        },
                        icon: const Icon(Icons.timer),
                        label: Text(
                          'Duración: ${_captureDuration.inSeconds >= 60 ? '${_captureDuration.inMinutes} min' : '${_captureDuration.inSeconds} s'}',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );

          final samplesSection = Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Huellas registradas',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Eliminar todo',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _clearSamples,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildSamplesList(),
                ],
              ),
            ),
          );

          if (isWide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      scanSection,
                      const SizedBox(height: 16),
                      samplesSection,
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [mapSection],
                  ),
                ),
              ],
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              scanSection,
              const SizedBox(height: 16),
              mapSection,
              const SizedBox(height: 16),
              samplesSection,
            ],
          );
        },
      ),
    );
  }
}
