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

import 'fingerprint_matcher.dart';
import 'fingerprint_repository.dart';
import 'fingerprint_sample.dart';

class FingerprintOnlineScreen extends StatefulWidget {
  const FingerprintOnlineScreen({
    super.key,
    required this.repository,
    this.widthMeters = 85.42,
    this.heightMeters = 33.79,
    this.imageAssetPath = 'assets/planta1.png',
    this.embedded = false,
    this.onClose,
    this.useExternalMap = false,
    this.selectedSample,
    this.onSampleSelected,
    this.onMatchUpdated,
  });

  final FingerprintRepository repository;
  final double widthMeters;
  final double heightMeters;
  final String imageAssetPath;
  final bool embedded;
  final VoidCallback? onClose;
  final bool useExternalMap;
  final FingerprintSample? selectedSample;
  final ValueChanged<FingerprintSample?>? onSampleSelected;
  final ValueChanged<FingerprintMatcherResult?>? onMatchUpdated;

  @override
  State<FingerprintOnlineScreen> createState() =>
      _FingerprintOnlineScreenState();
}

class _FingerprintOnlineScreenState extends State<FingerprintOnlineScreen> {
  static const double _kProximityThreshold = 20.0;
  final FingerprintMatcher _matcher = FingerprintMatcher();
  final MapController _mapController = MapController();
  static const String _memoryKey = 'memory';

  bool _isScanning = false;
  bool _hasFloorAsset = false;
  String? _statusMessage;
  LatLng? _estimatedPosition;
  FingerprintMatcherResult? _matcherResult;
  Map<String, int> _currentReading = const <String, int>{};
  List<WiFiAccessPoint> _lastScan = const <WiFiAccessPoint>[];
  List<FingerprintSample> _activeSamples = const <FingerprintSample>[];
  List<_DatasetInfo> _datasets = const <_DatasetInfo>[];
  String _selectedDatasetKey = _memoryKey;
  double? _mapWidth;
  double? _mapHeight;
  FingerprintSample? _selectedSample;
  bool _isQuickMonitoring = false;
  Timer? _quickTimer;
  Duration _monitoringElapsed = Duration.zero;
  int _changeCount = 0;

  @override
  void initState() {
    super.initState();
    _activeSamples = List<FingerprintSample>.from(widget.repository.samples);
    _mapWidth = widget.widthMeters;
    _mapHeight = widget.heightMeters;
    _selectedSample = widget.selectedSample;
    widget.repository.addListener(_onRepositoryChanged);
    unawaited(_initialize());
    unawaited(_loadDatasets());
  }

  @override
  void dispose() {
    widget.repository.removeListener(_onRepositoryChanged);
    _quickTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FingerprintOnlineScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedSample != oldWidget.selectedSample) {
      _selectedSample = widget.selectedSample;
    }
    if (widget.repository != oldWidget.repository) {
      oldWidget.repository.removeListener(_onRepositoryChanged);
      widget.repository.addListener(_onRepositoryChanged);
      _activeSamples = List<FingerprintSample>.from(widget.repository.samples);
    }
  }

  Future<void> _initialize() async {
    await _checkAsset();
    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      if (!mounted) return;
      setState(() {
        _statusMessage =
            'Se requiere acceso a la ubicación para estimar la posición.';
      });
      return;
    }
    await _performScan();
  }

  Future<void> _loadDatasets() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final entries = <_DatasetInfo>[];
      if (await directory.exists()) {
        await for (final entity in directory.list()) {
          if (entity is! File) continue;
          if (!entity.path.toLowerCase().endsWith('.json')) continue;
          final info = await _parseDataset(entity);
          if (info != null) {
            entries.add(info);
          }
        }
      }
      entries.sort((a, b) {
        final aTime = a.generatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.generatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });
      if (!mounted) return;
      setState(() {
        _datasets = entries;
      });
      final selectedExists = _selectedDatasetKey == _memoryKey ||
          entries.any((element) => element.key == _selectedDatasetKey);
      if (!selectedExists) {
        _onDatasetSelected(_memoryKey);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusMessage ??=
            'No se pudieron cargar datasets guardados: $error';
      });
    }
  }

  Future<_DatasetInfo?> _parseDataset(File file) async {
    try {
      final raw = await file.readAsString();
      final data = jsonDecode(raw);
      if (data is! Map) return null;
      final samplesRaw = data['samples'];
      if (samplesRaw is! List) return null;

      final samples = <FingerprintSample>[];
      for (final item in samplesRaw) {
        if (item is Map<String, dynamic>) {
          samples.add(FingerprintSample.fromJson(item));
        } else if (item is Map) {
          samples.add(
            FingerprintSample.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          );
        }
      }

      final area = data['areaMeters'];
      double? width;
      double? height;
      if (area is Map) {
        width = (area['width'] as num?)?.toDouble();
        height = (area['height'] as num?)?.toDouble();
      }
      final generatedAtRaw = data['generatedAt'];
      DateTime? generatedAt;
      if (generatedAtRaw is String) {
        generatedAt = DateTime.tryParse(generatedAtRaw);
      }

      final name = p.basename(file.path);
      return _DatasetInfo(
        key: file.path,
        name: name,
        samples: samples,
        generatedAt: generatedAt,
        width: width,
        height: height,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _checkAsset() async {
    try {
      await rootBundle.load(widget.imageAssetPath);
      if (mounted) setState(() => _hasFloorAsset = true);
    } catch (_) {
      if (mounted) setState(() => _hasFloorAsset = false);
    }
  }

  Future<void> _performScan() async {
    if (_isScanning) return;
    if (!mounted) return;
    setState(() => _isScanning = true);

    try {
      final canStart = await WiFiScan.instance.canStartScan(
        askPermissions: false,
      );
      if (canStart != CanStartScan.yes) {
        if (!mounted) return;
        setState(() {
          _statusMessage =
              'No es posible realizar un escaneo (${canStart.name}).';
          _isScanning = false;
        });
        return;
      }
      final started = await WiFiScan.instance.startScan();
      if (!started) {
        if (!mounted) return;
        setState(() {
          _statusMessage = 'El escaneo no pudo iniciarse.';
          _isScanning = false;
        });
        return;
      }

      await Future.delayed(const Duration(milliseconds: 400));
      final results = await WiFiScan.instance.getScannedResults();
      _applyResults(results);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Error escaneando: $error';
        _isScanning = false;
      });
    }
  }

  void _applyResults(List<WiFiAccessPoint> results) {
    if (!mounted) return;
    final previousReading = _currentReading;
    final ordered = List<WiFiAccessPoint>.from(results)
      ..sort((a, b) => b.level.compareTo(a.level));
    final current = {for (final ap in ordered) ap.bssid: ap.level};
    final samples = _activeSamples;
    final matcherResult =
        samples.isEmpty ? null : _matcher.match(current, samples);

    setState(() {
      _lastScan = ordered;
      _currentReading = current;
      _matcherResult = matcherResult;
      _estimatedPosition = matcherResult?.best.position;
      _selectedSample = matcherResult?.best ?? _selectedSample;
      _statusMessage = matcherResult == null
          ? 'Sin huellas para comparar.'
          : 'Distancia k-NN: ${matcherResult.distance.toStringAsFixed(1)}';
      _isScanning = false;

      if (matcherResult != null &&
          matcherResult.distance <= _kProximityThreshold) {
        _selectSample(matcherResult.best);
      }

      widget.onMatchUpdated?.call(matcherResult);

      if (_isQuickMonitoring &&
          _hasSignificantChange(previousReading, current)) {
        _changeCount += 1;
      }
    });
  }

  bool _hasSignificantChange(
    Map<String, int> prev,
    Map<String, int> current,
  ) {
    if (prev.length != current.length) return true;
    for (final entry in current.entries) {
      final prevValue = prev[entry.key];
      if (prevValue == null) return true;
      if ((prevValue - entry.value).abs() > 3) return true;
    }
    return false;
  }

  Future<void> _quickScanAndSelect() async {
    if (!mounted) return;
    if (_isQuickMonitoring) {
      _quickTimer?.cancel();
      setState(() {
        _isQuickMonitoring = false;
        _monitoringElapsed = Duration.zero;
        _changeCount = 0;
        _statusMessage ??= 'Monitoreo detenido.';
      });
      return;
    }
    setState(() {
      _isQuickMonitoring = true;
      _statusMessage = 'Monitoreo rapido...';
      _monitoringElapsed = Duration.zero;
      _changeCount = 0;
    });
    _quickTimer?.cancel();
    unawaited(_performScan());
    _quickTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (!_isQuickMonitoring || _isScanning) return;
      _monitoringElapsed += const Duration(milliseconds: 500);
      await _performScan();
    });
  }

  void _onDatasetSelected(String key) {
    if (key == _selectedDatasetKey && key != _memoryKey) {
      return;
    }

    List<FingerprintSample> samples;
    double width;
    double height;
    String status;

    if (key == _memoryKey) {
      samples = List<FingerprintSample>.from(widget.repository.samples);
      width = widget.widthMeters;
      height = widget.heightMeters;
      status = 'Usando huellas en memoria (${samples.length}).';
    } else {
      _DatasetInfo dataset;
      try {
        dataset = _datasets.firstWhere((element) => element.key == key);
      } catch (_) {
        return;
      }
      samples = dataset.samples;
      width = dataset.width ?? widget.widthMeters;
      height = dataset.height ?? widget.heightMeters;
      status = 'Dataset ${dataset.name} cargado (${samples.length} huellas).';
    }

    final match =
        samples.isEmpty ? null : _matcher.match(_currentReading, samples);

    // Propagate samples to shared repository so map screen renders them.
    widget.repository.replaceAll(samples);

    setState(() {
      _selectedDatasetKey = key;
      _activeSamples = samples;
      _mapWidth = width;
      _mapHeight = height;
      _matcherResult = match;
      _estimatedPosition = match?.best.position;
      _selectedSample = match?.best;
      _statusMessage = status;
      _monitoringElapsed = Duration.zero;
      _changeCount = 0;

      widget.onMatchUpdated?.call(match);
    });
  }

  void _fitBounds() {
    final width = _mapWidth ?? widget.widthMeters;
    final height = _mapHeight ?? widget.heightMeters;
    final bounds = LatLngBounds.fromPoints([
      LatLng(0, 0),
      LatLng(height, width),
    ]);
    _mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(24)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _buildBody(context);

    if (widget.embedded) {
      return Column(
        children: [
          _buildEmbeddedHeader(context),
          const SizedBox(height: 8),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Posicionamiento Fingerprinting'),
        actions: [
          IconButton(
            onPressed: _quickScanAndSelect,
            icon: _isScanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    _isQuickMonitoring
                        ? Icons.pause_circle
                        : Icons.play_circle,
                  ),
            tooltip: _isQuickMonitoring
                ? 'Detener monitoreo rapido'
                : 'Monitoreo rapido (auto)',
          ),
          IconButton(
            onPressed: _performScan,
            icon: _isScanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_find),
            tooltip: 'Escanear ahora',
          ),
        ],
      ),
      body: body,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _fitBounds,
        icon: const Icon(Icons.zoom_out_map),
        label: const Text('Ajustar mapa'),
      ),
    );
  }

  Widget _buildEmbeddedHeader(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).cardColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.location_searching, color: Colors.blue),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Posicionamiento Fingerprinting',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              onPressed: _quickScanAndSelect,
              icon: _isScanning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _isQuickMonitoring
                          ? Icons.pause_circle
                          : Icons.play_circle,
                    ),
              tooltip: _isQuickMonitoring
                  ? 'Detener monitoreo rapido'
                  : 'Monitoreo rapido (auto)',
            ),
            IconButton(
              onPressed: _performScan,
              icon: _isScanning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_find),
              tooltip: 'Escanear ahora',
            ),
            if (widget.onClose != null)
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(Icons.close),
                tooltip: 'Cerrar panel',
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final samples = _activeSamples;
    final match = _matcherResult;
    final estimated = _estimatedPosition;
    final lastScan = _lastScan;
    final scanList = lastScan
        .map(
          (ap) => ListTile(
            dense: true,
            leading: const Icon(Icons.network_wifi),
            title:
                Text(ap.ssid.isNotEmpty ? ap.ssid : 'Red oculta (${ap.bssid})'),
            subtitle: Text(ap.bssid),
            trailing: Text('${ap.level} dBm'),
          ),
        )
        .toList();

    if (widget.useExternalMap) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildDetails(match, scanList),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 900;
        final map = _buildMap(estimated, samples);
        final details = _buildDetails(match, scanList);

        if (isWide) {
          return Row(
            children: [
              Expanded(child: map),
              const VerticalDivider(width: 1),
              Expanded(child: details),
            ],
          );
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            map,
            const SizedBox(height: 16),
            details,
          ],
        );
      },
    );
  }

  Widget _buildMap(LatLng? estimated, List<FingerprintSample> samples) {
    final width = _mapWidth ?? widget.widthMeters;
    final height = _mapHeight ?? widget.heightMeters;
    final bounds = LatLngBounds.fromPoints([
      LatLng(0, 0),
      LatLng(height, width),
    ]);
    return SizedBox(
      height: 360,
      child: Card(
        clipBehavior: Clip.hardEdge,
        child: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                crs: const CrsSimple(),
                initialCenter: LatLng(
                  height / 2,
                  width / 2,
                ),
                initialZoom: 1,
                minZoom: -2,
                maxZoom: 6,
              ),
              children: [
                if (_hasFloorAsset)
                  OverlayImageLayer(
                    overlayImages: [
                      OverlayImage(
                        bounds: bounds,
                        imageProvider: AssetImage(widget.imageAssetPath),
                      ),
                    ],
                  ),
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: [
                        LatLng(0, 0),
                        LatLng(height, 0),
                        LatLng(height, width),
                        LatLng(0, width),
                      ],
                      color: Colors.blue.withOpacity(0.05),
                      borderStrokeWidth: 2,
                      borderColor: Colors.blueGrey,
                    )
                  ],
                ),
                MarkerLayer(
                  markers: [
                    for (final sample in samples)
                      Marker(
                        point: sample.position,
                        width: 16,
                        height: 16,
                        child: const Icon(
                          Icons.circle,
                          size: 10,
                          color: Colors.deepPurple,
                        ),
                      ),
                    if (estimated != null)
                      Marker(
                        point: estimated,
                        width: 34,
                        height: 34,
                        child: const Icon(
                          Icons.my_location,
                          color: Colors.green,
                          size: 28,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            if (!_hasFloorAsset)
              Positioned(
                left: 8,
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.yellow.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'No se encontró la imagen del plano (${widget.imageAssetPath}).',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetails(
    FingerprintMatcherResult? match,
    List<Widget> scanList,
  ) {
    final samples = _activeSamples;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Fuente de huellas',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selectedDatasetKey,
                        isExpanded: true,
                        items: [
                          DropdownMenuItem(
                            value: _memoryKey,
                            child: Text(
                              'En memoria (${widget.repository.samples.length})',
                            ),
                          ),
                          for (final dataset in _datasets)
                            DropdownMenuItem(
                              value: dataset.key,
                              child: Text(dataset.displayName),
                            ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          _onDatasetSelected(value);
                        },
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Actualizar lista de datasets',
                  onPressed: () => unawaited(_loadDatasets()),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Estado',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(_statusMessage ?? 'Listo para escanear.'),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  _isQuickMonitoring ? Icons.play_circle : Icons.pause_circle,
                  size: 18,
                  color: _isQuickMonitoring ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 6),
                Text(
                  _isQuickMonitoring
                      ? 'Monitoreo ${_formatDuration(_monitoringElapsed)}'
                      : 'Monitoreo detenido',
                ),
                const Spacer(),
                Text('Cambios: $_changeCount'),
              ],
            ),
            const SizedBox(height: 16),
            if (match != null)
              _MatchDetails(match: match)
            else
              const Text('Sin coincidencia disponible.'),
            const SizedBox(height: 16),
            Text(
              'Huellas guardadas (${samples.length})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Divider(height: 16),
            SizedBox(
              height: 160,
              child: samples.isEmpty
                  ? const Center(child: Text('No hay huellas.'))
                  : ListView.builder(
                      itemCount: samples.length,
                      itemBuilder: (context, index) {
                        final sample = samples[index];
                        final selected = identical(sample, _selectedSample);
                        return ListTile(
                          dense: true,
                          selected: selected,
                          selectedTileColor:
                              Theme.of(context).colorScheme.primaryContainer,
                          onTap: () => _selectSample(sample),
                          title: Text(
                            'X=${sample.position.longitude.toStringAsFixed(2)} · Y=${sample.position.latitude.toStringAsFixed(2)}',
                          ),
                          subtitle: Text(
                            'RSSI: ${sample.rssiByBssid.length} puntos · ${sample.timestamp.toLocal()}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 16),
            Text(
              'Lectura actual (${_currentReading.length} puntos)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Divider(height: 20),
            SizedBox(
              height: 220,
              child: scanList.isEmpty
                  ? const Center(child: Text('Sin redes detectadas.'))
                  : ListView(children: scanList),
            ),
          ],
        ),
      ),
    );
  }

  void _selectSample(FingerprintSample? sample) {
    setState(() {
      _selectedSample = sample;
    });
    widget.onSampleSelected?.call(sample);
  }

  void _onRepositoryChanged() {
    if (!mounted) return;
    if (_selectedDatasetKey == _memoryKey) {
      setState(() {
        _activeSamples = List<FingerprintSample>.from(widget.repository.samples);
      });
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _DatasetInfo {
  const _DatasetInfo({
    required this.key,
    required this.name,
    required this.samples,
    this.generatedAt,
    this.width,
    this.height,
  });

  final String key;
  final String name;
  final List<FingerprintSample> samples;
  final DateTime? generatedAt;
  final double? width;
  final double? height;

  String get displayName {
    final count = samples.length;
    final dateLabel = generatedAt != null
        ? ' · ${generatedAt!.toLocal().toString().split('.').first}'
        : '';
    return '$name ($count huellas)$dateLabel';
  }
}

class _MatchDetails extends StatelessWidget {
  const _MatchDetails({required this.match});

  final FingerprintMatcherResult match;

  @override
  Widget build(BuildContext context) {
    final sample = match.best;
    final entries = sample.rssiByBssid.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Huella más cercana',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Coordenadas: X=${sample.position.longitude.toStringAsFixed(2)} m · '
          'Y=${sample.position.latitude.toStringAsFixed(2)} m',
        ),
        Text('Registrada: ${sample.timestamp.toLocal()}'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final entry in entries)
              Chip(label: Text('${entry.key} (${entry.value} dBm)')),
          ],
        ),
      ],
    );
  }
}

