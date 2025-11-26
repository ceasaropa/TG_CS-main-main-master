//Version 11/11 TG-CS
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/node.dart';
import 'dart:math';
import '../algorithms/d_star_lite.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';
import 'dart:math' as math;

// For transparency of image
import 'dart:ui' as ui;
import 'package:flutter/services.dart';

// For working with .json
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../models/poi.dart';
import '../obst/obstacles_repository.dart';

// For integration with Cesar
import '../sensor/data/conteopasostexteo.dart';
import '../sensor/global_sensor_manager.dart';
import '../sensor/data/sensor_processor.dart';
import '../widgets/graphbuilder.dart';
import '../sensor/guardar/savedata.dart';
import '../utils/background_processor.dart';
import '../utils/performance_monitor.dart';
import '../utils/map_grid_converter.dart';
import '../utils/arrow_animation_helper.dart';
import '../models/sensor_states.dart';

// Orientation cone widgets
import '../widgets/orientation/orientation_arrow_widget.dart';
import '../widgets/orientation/orientation_cone_config.dart';
import '../widgets/orientation/cone_path_cache.dart';

// Navigation import
import 'home_screen.dart';
import '../fingerprint/fingerprint_training_screen.dart';
import '../fingerprint/fingerprint_online_screen.dart';
import '../fingerprint/fingerprint_repository.dart';
import '../fingerprint/fingerprint_sample.dart';
import '../fingerprint/fingerprint_matcher.dart';

const String kMapAssetPath = 'assets/planta1.png';
const double kPixelsPerMeter = 39.51; // Imagen calibrada a 39.51 px por metro
const double kMapNorthDegrees = 81.0; // Norte del plano (grados)

Future<ui.Image> loadUiImage(String assetPath) async {
  final data = await rootBundle.load(assetPath);
  final bytes = data.buffer.asUint8List();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

// Map initialization context for tracking state and errors
class MapInitializationContext {
  bool gridInitialized = false;
  bool sensorsAvailable = false;
  bool animationsEnabled = false;
  bool poisLoaded = false;
  bool mapCreated = false;
  bool obstaclesLoaded = false;
  List<String> errors = [];
  DateTime? lastAttempt;
  int retryCount = 0;

  void addError(String error) {
    errors.add('${DateTime.now()}: $error');
    debugPrint('Map Init Error: $error');
  }

  void reset() {
    gridInitialized = false;
    sensorsAvailable = false;
    animationsEnabled = false;
    poisLoaded = false;
    mapCreated = false;
    obstaclesLoaded = false;
    errors.clear();
    lastAttempt = DateTime.now();
  }

  bool get hasMinimalRequirements => gridInitialized;
  bool get hasFullFunctionality =>
      gridInitialized && sensorsAvailable && animationsEnabled && poisLoaded;

  String get statusSummary {
    final components = <String>[];
    if (gridInitialized) components.add('Grid');
    if (sensorsAvailable) components.add('Sensors');
    if (animationsEnabled) components.add('Animations');
    if (poisLoaded) components.add('POIs');
    if (obstaclesLoaded) components.add('Obstacles');

    return components.isEmpty
        ? 'No components initialized'
        : 'Initialized: ${components.join(", ")}';
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  // New variables
  LatLng? startPoint; // Start point
  LatLng? goalPoint; // Goal point
  bool selectingStart = true; // Flag to select start or goal point
  // New variables
  // final int numRows = 800; // rows
  // final int numCols = 800; // columns
  // Change for square grid without deforming map
  // Grid size (fixed rows, columns are calculated)
  static const int kNumRows = 400;
  static const double kCellSizeMeters = MapGridConverter.gridScale;
  late int numRows; // = kNumRows (assigned in _recomputeGridMetrics)
  late int numCols; // calculated to make square cells
  late double latStep; // cell size in latitude
  late double lngStep; // cell size in longitude (equal to latStep)
  double _mapAspectRatio = 1.0;
  double _mapWidthMeters = kNumRows * kCellSizeMeters;
  double _mapHeightMeters = kNumRows * kCellSizeMeters;

  // Set to track visited cells
  Set<Point<int>> visitedCells = {};

  // Calibration mode variables
  bool _isCalibrationMode = false;
  Point<int>? _firstCalibrationPoint;
  Point<int>? _secondCalibrationPoint;
  double _calibrationDistanceCm = 357.0; // Default calibration distance in cm

  void _recomputeGridMetrics() {
    try {
      // Derive grid dimensions from calibrated pixel density (39.51 px/m)
      numRows = max(1, (_mapHeightMeters / kCellSizeMeters).round());
      numCols = max(1, (_mapWidthMeters / kCellSizeMeters).round());

      // Maintain 10cm cells using the shared grid scale
      const double metersPerDegreeLat = 111320.0;
      latStep = kCellSizeMeters / metersPerDegreeLat;
      lngStep =
          latStep; // Keep square cells in degrees to match the map converter

      // Update bounds to match the recomputed grid so the overlay stays in sync
      endBounds = LatLng(
        startBounds.latitude + latStep * numRows,
        startBounds.longitude + lngStep * numCols,
      );

      debugPrint(
        'Grid metrics computed for 10cm cells (39.51 px/m): ${numRows}x$numCols, latStep=$latStep, lngStep=$lngStep, mapSize=${_mapWidthMeters.toStringAsFixed(2)}mx${_mapHeightMeters.toStringAsFixed(2)}m, aspectRatio=$_mapAspectRatio',
      );
    } catch (e) {
      debugPrint('Error computing grid metrics: $e');
      // Set fallback values
      numRows = 400;
      numCols = 400;
      latStep = kCellSizeMeters / 111320.0;
      lngStep = latStep;
      endBounds = LatLng(
        startBounds.latitude + latStep * numRows,
        startBounds.longitude + lngStep * numCols,
      );
    }
  }

  // For following position
  LatLng?
  _currentPosition; // Current user position (fixed when selecting start)

  double _deviceAngle = 0.0; // Rotation angle in radians
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<MagnetometerEvent>? _magSub;

  AccelerometerEvent? _accelData;
  MagnetometerEvent? _magData;

  late List<List<Node>> grid;

  Set<Point<int>> obstacles = {};

  // Modo temporal para bloquear rapidamente una linea de celdas como obstaculos
  bool _isObstacleLineMode = false;
  Point<int>? _obstacleLineStart;

  final ObstaclesRepository _obstaclesRepo = ObstaclesRepository();

  final MapController _mapController = MapController();
  // Here the calculated route will be stored
  List<LatLng> path = [];
  static const double _routeSnapDistanceMeters = 1.2;
  static const double _routeDirectionToleranceMeters = 0.4;
  double? _lastDistanceToGoalMeters;

  LatLng startBounds = LatLng(6.241, -75.589); // bottom left corner
  LatLng endBounds = LatLng(6.242, -75.587); // top right corner

  List<POI> pointsOfInterest = []; // All POIs from JSON
  List<POI> visiblePOIs = []; // List of POIs near the route

  // Global sensor manager integration
  GlobalSensorManager? _globalSensorManager;
  final GraphBuilder _graphBuilder = GraphBuilder();
  final FingerprintRepository _fingerprintRepository = FingerprintRepository();
  FingerprintSample? _selectedFingerprintSample;
  bool showgraph = false;
  LatLng? _knnLatLng;
  double? _knnDistance;
  bool _showHeadingPointer = false;
  bool _isCalculatingRoute = false;
  bool _isAddingPOIMode = false;
  final GlobalKey _fingerprintKey = GlobalKey();

  // Arrow positioning and animation
  ArrowState? _currentArrowState;
  late MapGridConverter _gridConverter;
  LatLng? _arrowStartPosition;
  List<ArrowState> _arrowPath = [];
  Timer? _arrowUpdateTimer;

  // For text boxes
  int _stepCount = 0;
  double _distanceMeters = 0.0;
  bool _isCountingSteps = false;

  // Map initialization context
  final MapInitializationContext _initContext = MapInitializationContext();
  bool _mapInitializationFailed = false;

  // Orientation cone configuration
  late OrientationConeConfig _coneConfig;
  bool _showOrientationCone = true; // User preference for showing cone
  double _headingOffsetRad =
      0.0; // Offset en radianes para alinear con norte del plano
  double _headingMap = 0.0; // Heading filtrado respecto al norte del plano
  static const double _headingSmoothingAlpha = 0.15;
  static const double _headingDeadband = 0.5 * math.pi / 180; // 0.5 degrees
  double? _magNormReference;
  String _pendingPOIIconKey = 'info';
  String? _pendingPOIName;
  String? _pendingPOIDescription;
  final List<POI> _userPOIs = [];
  static const Map<String, IconData> _poiIconOptions = {
    'info': Icons.info,
    'flag': Icons.flag,
    'home': Icons.home,
    'star': Icons.star,
    'medical': Icons.local_hospital,
    'school': Icons.school,
    'place': Icons.place,
  };

  @override
  void initState() {
    super.initState();

    // Initialize orientation cone configuration
    _coneConfig = OrientationConeConfig.light(); // Default to light theme
    _headingOffsetRad = -89 * math.pi / 180;

    _fingerprintRepository.addListener(_onFingerprintRepoChanged);
    _initializeMapComponents();
  }

  // Progressive initialization with error handling
  Future<void> _initializeMapComponents() async {
    _initContext.reset();
    _mapInitializationFailed = false;

    try {
      // Step 1: Grid metrics calculation (Critical)
      await _initializeGridMetrics();

      // Step 2: Load obstacles (Optional)
      await _initializeObstacles();

      // Step 3: Load POIs (Optional)
      await _initializePOIs();

      // Step 4: Initialize global sensor manager (Optional but important)
      await _initializeGlobalSensorManager();

      // Step 5: Initialize grid converter
      await _initializeGridConverter();

      // Step 6: Initialize animations (Optional)
      await _initializeAnimations();

      // Step 7: Initialize background processing
      await _initializeBackgroundProcessing();

      _initContext.mapCreated = true;
      debugPrint(
        'Map initialization completed successfully: ${_initContext.statusSummary}',
      );
    } catch (e) {
      _initContext.addError('Critical initialization failed: $e');
      _mapInitializationFailed = true;
      debugPrint('Map initialization failed: $e');
    }

    if (mounted) {
      setState(() {}); // Trigger rebuild with initialization results
    }
  }

  Future<void> _initializeGridMetrics() async {
    try {
      await _loadMapImageAspectRatio();
      _recomputeGridMetrics();

      // Validate coordinate bounds after calculating grid
      if (!_validateCoordinateBounds()) {
        throw Exception('Invalid coordinate bounds');
      }

      // Validate calculated grid dimensions
      if (numRows <= 0 || numCols <= 0 || latStep <= 0 || lngStep <= 0) {
        throw Exception(
          'Invalid grid dimensions calculated: rows=$numRows, cols=$numCols, latStep=$latStep, lngStep=$lngStep',
        );
      }

      // Initialize grid safely
      grid = List.generate(
        numRows,
        (row) => List.generate(numCols, (col) => Node(row: row, col: col)),
      );

      // Mark walkable obstacles after grid initialization
      for (final obstacle in obstacles) {
        if (obstacle.x >= 0 &&
            obstacle.x < numRows &&
            obstacle.y >= 0 &&
            obstacle.y < numCols) {
          grid[obstacle.x][obstacle.y].walkable = false;
        }
      }

      _initContext.gridInitialized = true;
      debugPrint('Grid metrics initialized successfully: ${numRows}x$numCols');
    } catch (e) {
      _initContext.addError('Grid initialization failed: $e');
      // Try with default values as fallback
      try {
        numRows = 400;
        numCols = 400;
        latStep = 0.001;
        lngStep = 0.001;
        grid = List.generate(
          numRows,
          (row) => List.generate(numCols, (col) => Node(row: row, col: col)),
        );
        _initContext.gridInitialized = true;
        debugPrint('Grid initialized with default values');
      } catch (fallbackError) {
        _initContext.addError('Grid fallback failed: $fallbackError');
        rethrow; // This is critical, must work
      }
    }
  }

  Future<void> _initializeObstacles() async {
    try {
      await loadObstacles();
      _initContext.obstaclesLoaded = true;
    } catch (e) {
      _initContext.addError('Obstacles loading failed: $e');
      // Continue without obstacles - not critical
    }
  }

  Future<void> _initializePOIs() async {
    try {
      // Check if POI asset exists before loading
      if (!await _validatePOIAsset()) {
        _initContext.addError('POI asset validation failed');
        pointsOfInterest = [];
        return;
      }

      await loadPOIsFromJson();

      // Validate loaded POIs
      if (pointsOfInterest.isNotEmpty) {
        pointsOfInterest =
            pointsOfInterest.where((poi) => _validatePOIData(poi)).toList();
        debugPrint('Validated ${pointsOfInterest.length} POIs');
      }

      _initContext.poisLoaded = true;
    } catch (e) {
      _initContext.addError('POIs loading failed: $e');
      pointsOfInterest = [];
      // Continue without POIs - not critical
    }
  }

  Future<void> _initializeGlobalSensorManager() async {
    try {
      _globalSensorManager = GlobalSensorManager.getInstance();
      _globalSensorManager!.initialize();

      // Add listener for global sensor updates
      _globalSensorManager!.addListener(_onGlobalSensorUpdate);

      // Start arrow update timer
      _arrowUpdateTimer = Timer.periodic(const Duration(milliseconds: 200), (
        timer,
      ) {
        _updateArrowPosition();
      });

      _initContext.sensorsAvailable = true;
      debugPrint('GlobalSensorManager initialized successfully');
    } catch (e) {
      _initContext.addError('Global sensor manager initialization failed: $e');
      // Continue without sensors - not critical
    }
  }

  Future<void> _initializeGridConverter() async {
    try {
      _gridConverter = MapGridConverter(
        startBounds: startBounds,
        endBounds: endBounds,
        fixedRows: numRows,
      );
      debugPrint('Grid converter initialized successfully');
    } catch (e) {
      _initContext.addError('Grid converter initialization failed: $e');
      debugPrint('WARNING: Grid converter initialization failed: $e');
    }
  }

  Future<void> _loadMapImageAspectRatio() async {
    try {
      final image = await loadUiImage(kMapAssetPath);
      if (image.height != 0) {
        _mapAspectRatio = image.width / image.height;
        _mapWidthMeters = image.width / kPixelsPerMeter;
        _mapHeightMeters = image.height / kPixelsPerMeter;
        debugPrint(
          'Map image aspect ratio loaded: $_mapAspectRatio (${image.width}x${image.height}), sizeMeters=${_mapWidthMeters.toStringAsFixed(2)}x${_mapHeightMeters.toStringAsFixed(2)}',
        );
      }
    } catch (e) {
      _mapAspectRatio = 1.0;
      _mapWidthMeters = kNumRows * kCellSizeMeters;
      _mapHeightMeters = kNumRows * kCellSizeMeters;
      debugPrint('Could not load map image for aspect ratio, using 1:1: $e');
    }
  }

  Future<void> _initializeAnimations() async {
    try {
      // Initialize shared animation controller for POI icons
      // if (mounted) {
      //   OptimizedAnimatedPOIIcon.initSharedController(this);
      // }
      _initContext.animationsEnabled = true;
      debugPrint('Animations initialization skipped (not implemented)');
    } catch (e) {
      _initContext.addError('Animation initialization failed: $e');
      _initContext.animationsEnabled = false;
      debugPrint('Animations disabled due to initialization error: $e');
      // Continue without animations - not critical
    }
  }

  Future<void> _initializeBackgroundProcessing() async {
    try {
      await BackgroundProcessor.instance.initialize();

      if (kDebugMode) {
        PerformanceMonitor.instance.startMonitoring();
      }

      debugPrint('Background processing initialized successfully');
    } catch (e) {
      _initContext.addError('Background processing failed: $e');
      debugPrint('WARNING: Background processing initialization failed: $e');
      // Continue without background processing - will affect path calculation
    }
  }

  // Validation methods for safe initialization
  bool _validateCoordinateBounds() {
    try {
      if (startBounds.latitude >= endBounds.latitude) {
        debugPrint('Invalid latitude bounds: start >= end');
        return false;
      }
      if (startBounds.longitude >= endBounds.longitude) {
        debugPrint('Invalid longitude bounds: start >= end');
        return false;
      }

      // Check if bounds are reasonable (not too small)
      final latSpan = (endBounds.latitude - startBounds.latitude).abs();
      final lngSpan = (endBounds.longitude - startBounds.longitude).abs();

      if (latSpan < 0.0001 || lngSpan < 0.0001) {
        debugPrint('Bounds too small: lat=$latSpan, lng=$lngSpan');
        return false;
      }

      if (latSpan > 1.0 || lngSpan > 1.0) {
        debugPrint('Bounds too large: lat=$latSpan, lng=$lngSpan');
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('Coordinate bounds validation failed: $e');
      return false;
    }
  }

  Future<bool> _validatePOIAsset() async {
    try {
      await rootBundle.loadString('assets/pois.json');
      return true;
    } catch (e) {
      debugPrint('POI asset validation failed: $e');
      return false;
    }
  }

  bool _validatePOIData(POI poi) {
    try {
      // Ensure grid is initialized before validating POI coordinates
      if (!_initContext.gridInitialized) {
        debugPrint('Cannot validate POI: grid not initialized');
        return false;
      }

      if (poi.cell.x < 0 || poi.cell.x >= numRows) {
        debugPrint(
          'POI ${poi.name} x-coordinate outside bounds: ${poi.cell.x} (max: $numRows)',
        );
        return false;
      }

      if (poi.cell.y < 0 || poi.cell.y >= numCols) {
        debugPrint(
          'POI ${poi.name} y-coordinate outside bounds: ${poi.cell.y} (max: $numCols)',
        );
        return false;
      }

      if (poi.name.isEmpty) {
        debugPrint('POI has empty name');
        return false;
      }

      if (poi.iconKey.isEmpty) {
        debugPrint('POI has empty icon key');
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('POI data validation failed: $e');
      return false;
    }
  }

  IconData _iconForPOI(POI poi) {
    return _poiIconOptions[poi.iconKey] ?? Icons.place;
  }

  Future<void> _openAddPOIDialog() async {
    if (!_initContext.gridInitialized) {
      _showUserMessage('La grilla no esta lista', Colors.orange);
      return;
    }

    final nameController = TextEditingController(text: _pendingPOIName ?? '');
    final descController =
        TextEditingController(text: _pendingPOIDescription ?? '');
    String iconKey = _pendingPOIIconKey;

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Nuevo punto de interes'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Nombre',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: descController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Descripcion',
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: iconKey,
                    decoration: const InputDecoration(
                      labelText: 'Icono',
                    ),
                    items:
                        _poiIconOptions.entries
                            .map(
                              (entry) => DropdownMenuItem<String>(
                                value: entry.key,
                                child: Row(
                                  children: [
                                    Icon(entry.value, size: 20),
                                    const SizedBox(width: 8),
                                    Text(entry.key),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        iconKey = value;
                      }
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(
                    context,
                    {
                      'name': nameController.text.trim(),
                      'description': descController.text.trim(),
                      'iconKey': iconKey,
                    },
                  );
                },
                child: const Text('Elegir punto en el mapa'),
              ),
            ],
          ),
    );

    if (result == null) return;

    final name = result['name']?.trim() ?? '';
    final description = result['description']?.trim() ?? '';
    final selectedIcon = result['iconKey'] ?? 'info';

    if (name.isEmpty) {
      _showUserMessage('Ponle nombre al punto', Colors.orange);
      return;
    }

    setState(() {
      _pendingPOIName = name;
      _pendingPOIDescription = description;
      _pendingPOIIconKey = selectedIcon;
      _isAddingPOIMode = true;
    });

    _showUserMessage('Toca el mapa para ubicar el POI', Colors.blue);
  }

  void _handleAddPOITap(LatLng latlng) {
    if (!_isAddingPOIMode) return;

    try {
      final cell = latLngToGrid(latlng);
      if (!_isCellWithinGrid(cell)) {
        _showUserMessage('El punto esta fuera del mapa', Colors.red);
        return;
      }

      final poi = POI(
        cell: cell,
        name: _pendingPOIName ?? 'POI sin nombre',
        description: _pendingPOIDescription ?? '',
        iconKey: _pendingPOIIconKey,
      );

      if (!_validatePOIData(poi)) {
        _showUserMessage('No se pudo validar el POI', Colors.orange);
        return;
      }

      setState(() {
        pointsOfInterest.add(poi);
        _userPOIs.add(poi);
        visiblePOIs = [...visiblePOIs, poi];
        _isAddingPOIMode = false;
        _pendingPOIName = null;
        _pendingPOIDescription = null;
      });

      _showUserMessage('POI agregado', Colors.green);
    } catch (e) {
      debugPrint('Error adding POI: $e');
      _showUserMessage('Error agregando el POI: $e', Colors.red);
    }
  }

  void _onFingerprintMatchUpdated(FingerprintMatcherResult? result) {
    try {
      if (!mounted) return;
      setState(() {
        if (result == null) {
          _knnLatLng = null;
          _knnDistance = null;
          return;
        }

        final latlng = _fingerprintToLatLng(result.best.position);
        _knnLatLng = latlng;
        _knnDistance = result.distance;
      });
    } catch (e) {
      debugPrint('Error handling fingerprint match: $e');
    }
  }

  bool _isKnnStartReady() {
    return _knnLatLng != null && _knnDistance != null && _knnDistance! < 130;
  }

  Future<void> _startRouteFromKnn() async {
    try {
      final dynamic fingerprintState = _fingerprintKey.currentState;
      if (fingerprintState != null &&
          fingerprintState.startQuickMonitoringFromParent != null) {
        await fingerprintState.startQuickMonitoringFromParent();
        // Small wait to let the new scan update kNN result
        await Future.delayed(const Duration(milliseconds: 600));
      }
    } catch (e) {
      debugPrint('No se pudo iniciar escaneo rapido: $e');
    }

    if (!_isKnnStartReady()) {
      _showUserMessage('No hay huella cercana (<130)', Colors.orange);
      return;
    }

    if (goalPoint == null) {
      _showUserMessage('Selecciona un destino en el mapa', Colors.orange);
      return;
    }

    setState(() {
      startPoint = _knnLatLng;
      selectingStart = false;
      _currentPosition = _knnLatLng;
      path = [];
      _lastDistanceToGoalMeters = null;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      calculatePath();
    });

    _showUserMessage('Origen fijado desde huella cercana', Colors.green);
  }

  // Project Cesar - Global Sensor Manager
  @override
  void dispose() {
    try {
      // Remove listener from global sensor manager
      _globalSensorManager?.removeListener(_onGlobalSensorUpdate);
      _fingerprintRepository.removeListener(_onFingerprintRepoChanged);

      _accelSub?.cancel();
      _magSub?.cancel();
      _gyroSubscription?.cancel();
      _compassUpdateTimer?.cancel();
      _arrowUpdateTimer?.cancel();

      BackgroundProcessor.instance.dispose();
      PerformanceMonitor.instance.dispose();

      // Cleanup orientation cone cache
      ConePathCache.clearCache();

      // Dispose shared animation controller
      // OptimizedAnimatedPOIIcon.disposeSharedController();
    } catch (e) {
      debugPrint('Error in dispose: $e');
    }
    super.dispose();
  }

  // Global sensor data update handler
  void _onGlobalSensorUpdate() {
    _updateStepCountAndDistance();
    if (mounted) {
      setState(() {});
    }
  }

  // Update step count and distance from global sensor manager
  void _updateStepCountAndDistance() {
    if (_globalSensorManager == null) return;

    final sensorState = _globalSensorManager!.sensorState;
    _stepCount = sensorState.stepCount;
    _distanceMeters = sensorState.totalDistance;
    _isCountingSteps = sensorState.isRunning;
  }

  bool _trimRouteIfAdvancing(LatLng userPosition) {
    if (goalPoint == null || path.length < 2) {
      _lastDistanceToGoalMeters = null;
      return false;
    }

    try {
      final distanceCalc = Distance();
      final distanceToGoal = distanceCalc.as(
        LengthUnit.Meter,
        userPosition,
        goalPoint!,
      );

      final bool movingTowardGoal =
          _lastDistanceToGoalMeters == null ||
          distanceToGoal <=
              _lastDistanceToGoalMeters! + _routeDirectionToleranceMeters;

      _lastDistanceToGoalMeters = distanceToGoal;

      if (!movingTowardGoal) {
        return false;
      }

      int closestIndex = 0;
      double closestDistance = double.infinity;

      for (int i = 0; i < path.length; i++) {
        final double d = distanceCalc.as(
          LengthUnit.Meter,
          userPosition,
          path[i],
        );

        if (d < closestDistance) {
          closestDistance = d;
          closestIndex = i;
        }
      }

      if (closestIndex == 0 || closestDistance > _routeSnapDistanceMeters) {
        return false;
      }

      final int newStartIndex = max(closestIndex - 1, 1);

      if (newStartIndex >= path.length) {
        return false;
      }

      path = path.sublist(newStartIndex);
      return true;
    } catch (e) {
      debugPrint('Error trimming route: $e');
      return false;
    }
  }

  // Update arrow position based on global sensor data
  void _updateArrowPosition() {
    if (_globalSensorManager == null ||
        !_globalSensorManager!.isRunning ||
        _arrowStartPosition == null) {
      return;
    }

    try {
      final positionState = _globalSensorManager!.positionState;

      if (positionState.isValid && positionState.accuracy > 0.1) {
        // Calculate new arrow state with smooth animation and compass data
        final newArrowState = _gridConverter.calculateArrowState(
          positionState,
          _arrowStartPosition!,
          customSpeed: _globalSensorManager!.currentSpeed,
          compassAngle: -_deviceAngle, // use unified heading (north=0, cw)
        );

        // Track visited cells
        if (newArrowState.isVisible) {
          final currentCell = latLngToGrid(newArrowState.position);
          if (!visitedCells.contains(currentCell)) {
            setState(() {
              visitedCells.add(currentCell);
            });
          }
        }

        // Apply smooth transition if there's a previous arrow state
        if (_currentArrowState != null && newArrowState.isVisible) {
          // Use smooth state calculation from ArrowAnimationHelper
          _currentArrowState = ArrowAnimationHelper.calculateSmoothState(
            _currentArrowState!,
            newArrowState,
            0.3, // Lerp factor for smooth movement
            _globalSensorManager!.currentSpeed,
          );
        } else {
          // First arrow or not visible, use direct state
          _currentArrowState = newArrowState;
        }

        // Manage arrow path for trail visualization
        if (_currentArrowState != null && _currentArrowState!.isVisible) {
          _arrowPath = ArrowAnimationHelper.manageArrowTrail(
            _arrowPath,
            _currentArrowState!,
            maxPoints: 100,
          );

          // Hide the traveled portion of the route when moving toward the goal
          _trimRouteIfAdvancing(_currentArrowState!.position);

          // Keep heading pointer anchored to the latest position from sensors
          _currentPosition = _currentArrowState!.position;
        }

        if (mounted) {
          setState(() {});
        }
      }
    } catch (e) {
      debugPrint('Error updating arrow position: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final halfHeight = MediaQuery.of(context).size.height * 0.5;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Planta 3 FIET - PSNEOPEC'),
        actions: [
          // Calibration mode toggle button
          IconButton(
            onPressed: _toggleCalibrationMode,
            icon: Icon(
              _isCalibrationMode
                  ? Icons.square_foot
                  : Icons.square_foot_outlined,
              color: _isCalibrationMode ? Colors.blue : Colors.grey,
            ),
            tooltip:
                _isCalibrationMode
                    ? 'Salir del modo de calibración'
                    : 'Entrar al modo de calibración',
          ),
          IconButton(
            onPressed: _toggleHeadingPointer,
            icon: Icon(
              _showHeadingPointer
                  ? Icons.navigation
                  : Icons.navigation_outlined,
            ),
            tooltip:
                _showHeadingPointer
                    ? 'Ocultar puntero de rumbo'
                    : 'Mostrar puntero de rumbo',
          ),
          // Cone theme selector
          PopupMenuButton<String>(
            onSelected: _switchConeTheme,
            icon: const Icon(Icons.palette),
            tooltip: 'Tema del cono de orientación',
            itemBuilder:
                (BuildContext context) => [
                  const PopupMenuItem(
                    value: 'light',
                    child: Row(
                      children: [
                        Icon(Icons.light_mode, size: 20),
                        SizedBox(width: 8),
                        Text('Claro'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'dark',
                    child: Row(
                      children: [
                        Icon(Icons.dark_mode, size: 20),
                        SizedBox(width: 8),
                        Text('Oscuro'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'high_contrast',
                    child: Row(
                      children: [
                        Icon(Icons.contrast, size: 20),
                        SizedBox(width: 8),
                        Text('Alto contraste'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'performance',
                    child: Row(
                      children: [
                        Icon(Icons.speed, size: 20),
                        SizedBox(width: 8),
                        Text('Rendimiento'),
                      ],
                    ),
                  ),
                ],
          ),
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const HomeScreen()),
              );
            },
            icon: const Icon(Icons.analytics),
            tooltip: 'Análisis de Datos',
          ),
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (context) => FingerprintTrainingScreen(
                        repository: _fingerprintRepository,
                        widthMeters: _mapWidthMeters,
                        heightMeters: _mapHeightMeters,
                        imageAssetPath: kMapAssetPath,
                      ),
                ),
              );
            },
            icon: const Icon(Icons.wifi),
            tooltip: 'Entrenamiento WiFi',
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: halfHeight,
            child: RepaintBoundary(child: _buildSafeFlutterMap()),
          ),

          // Performance debug overlay (only in debug mode)
          if (kDebugMode)
            Positioned(
              top: 5,
              right: 5,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Performance',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    StreamBuilder<String>(
                      stream: _getPerformanceStream(),
                      builder: (context, snapshot) {
                        return Text(
                          snapshot.data ?? 'Monitoring...',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),

          Positioned(
            top: halfHeight,
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Card(
                margin: const EdgeInsets.all(12),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: FingerprintOnlineScreen(
                    key: _fingerprintKey,
                    embedded: true,
                    useExternalMap: true,
                    repository: _fingerprintRepository,
                    widthMeters: _mapWidthMeters,
                    heightMeters: _mapHeightMeters,
                    imageAssetPath: kMapAssetPath,
                    selectedSample: _selectedFingerprintSample,
                    onSampleSelected: (sample) {
                      _onFingerprintSelected(sample, center: true);
                    },
                    onMatchUpdated: _onFingerprintMatchUpdated,
                  ),
                ),
              ),
            ),
          ),
          // Text boxes and button in the top left corner
          Positioned(
            top: 5,
            left: 0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Calibration info display
                if (_isCalibrationMode && _firstCalibrationPoint != null) ...[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.8),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _secondCalibrationPoint == null
                          ? 'Seleccione el segundo punto de calibración'
                          : 'Puntos seleccionados: ${_calculateGridDistance(_firstCalibrationPoint!, _secondCalibrationPoint!).toStringAsFixed(1)} celdas',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white70,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Pasos: $_stepCount',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white70,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Distancia: ${_distanceMeters.toStringAsFixed(2)} m',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Route status indicator
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color:
                        path.isNotEmpty
                            ? Colors.green.withOpacity(0.8)
                            : Colors.orange.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    path.isNotEmpty
                        ? 'Ruta: ${path.length} puntos'
                        : 'Sin ruta',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _isKnnStartReady()
                        ? Colors.green.withOpacity(0.8)
                        : Colors.grey.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _knnDistance == null
                        ? 'Huella: sin dato'
                        : 'Huella kNN: ${_knnDistance!.toStringAsFixed(1)}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _isKnnStartReady() ? _startRouteFromKnn : null,
                  icon: const Icon(Icons.my_location),
                  label: const Text('Usar huella como origen'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _openAddPOIDialog,
                  icon: const Icon(Icons.add_location_alt),
                  label: Text(
                    _isAddingPOIMode
                        ? 'Selecciona punto en mapa'
                        : 'Agregar POI',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _isAddingPOIMode ? Colors.orange : Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _toggleObstacleLineMode,
                  icon: Icon(
                    _isObstacleLineMode ? Icons.block : Icons.timeline,
                  ),
                  label: Text(
                    _isObstacleLineMode
                        ? 'Bloqueo A-B activo'
                        : 'Bloquear obstaculos A-B',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _isObstacleLineMode ? Colors.redAccent : Colors.black54,
                    foregroundColor: Colors.white,
                  ),
                ),
                if (_isObstacleLineMode) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _obstacleLineStart == null
                          ? 'Toca el mapa para marcar nodo A'
                          : 'A = (${_obstacleLineStart!.x}, ${_obstacleLineStart!.y}), toca nodo B',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () {
                    if (_globalSensorManager == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Sensores no disponibles'),
                        ),
                      );
                      return;
                    }

                    if (_globalSensorManager!.isRunning) {
                      // Stop sensors and reset arrow
                      _globalSensorManager!.stopSensors();

                      // Stop compass tracking
                      _accelSub?.cancel();
                      _magSub?.cancel();
                      _compassUpdateTimer?.cancel();

                      setState(() {
                        _currentArrowState = null;
                        _arrowPath.clear();
                        _arrowStartPosition = null;
                        _lastDistanceToGoalMeters = null;
                        _currentPosition = null;
                        // Clear visited cells when stopping
                        visitedCells.clear();
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Sensores detenidos')),
                      );
                    } else {
                      // Start sensors and set arrow start position
                      _globalSensorManager!.startSensors();

                      // Start compass tracking for small arrow orientation
                      _startCompassTracking();

                      // Set arrow start position to current position or map center
                      if (startPoint != null) {
                        _arrowStartPosition = startPoint;
                      } else {
                        // Default to map center if no start point selected
                        _arrowStartPosition = LatLng(
                          (startBounds.latitude + endBounds.latitude) / 2,
                          (startBounds.longitude + endBounds.longitude) / 2,
                        );
                      }

                      // Reset global sensor data for fresh start
                      _globalSensorManager!.resetData();

                      setState(() {
                        _currentArrowState = null;
                        _arrowPath.clear();
                        _lastDistanceToGoalMeters = null;
                        _currentPosition = _arrowStartPosition;
                        // Clear visited cells when starting fresh
                        visitedCells.clear();
                      });

                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Sensores iniciados - Comience a caminar',
                          ),
                        ),
                      );
                    }
                  },
                  icon: Icon(
                    _globalSensorManager?.isRunning == true
                        ? Icons.stop
                        : Icons.directions_walk,
                  ),
                  label: Text(
                    _globalSensorManager?.isRunning == true
                        ? "Detener"
                        : "Iniciar",
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _globalSensorManager?.isRunning == true
                            ? Colors.red
                            : Colors.teal,
                    foregroundColor: Colors.white,
                    elevation: 3,
                  ),
                ),
                // Calibration button
                if (_isCalibrationMode &&
                    _firstCalibrationPoint != null &&
                    _secondCalibrationPoint != null) ...[
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _applyCalibration,
                    icon: const Icon(Icons.check),
                    label: const Text('Aplicar Calibración'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),

      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() {
            startPoint = null;
            goalPoint = null;
            path = [];
            _lastDistanceToGoalMeters = null;
            _isAddingPOIMode = false;
            _pendingPOIName = null;
            _pendingPOIDescription = null;
            selectingStart = true;
            // Clear visited cells when refreshing the map
            visitedCells.clear();
            // Clear calibration points
            _firstCalibrationPoint = null;
            _secondCalibrationPoint = null;
          });
        },
        child: const Icon(Icons.refresh),
      ),
    );
  }

  Point<int> latLngToGrid(LatLng point) {
    final gridCoords = _gridConverter.latLngToGrid(point);
    return Point(gridCoords['gridX']!.toInt(), gridCoords['gridY']!.toInt());
  }

  bool _isCellWithinGrid(Point<int> cell) {
    return cell.x >= 0 &&
        cell.x < numRows &&
        cell.y >= 0 &&
        cell.y < numCols;
  }

  LatLng gridToLatLng(Node node) {
    return _gridConverter.gridCoordsToLatLng(node.row, node.col);
  }

  List<LatLng> getCellPolygon(int row, int col) {
    return _gridConverter.getGridCellPolygon(row, col);
  }

  Future<void> calculatePath() async {
    debugPrint('=== CALCULATE PATH STARTED ===');

    if (startPoint == null || goalPoint == null) {
      debugPrint('ERROR: Start or goal point is null');
      debugPrint('Start point: $startPoint');
      debugPrint('Goal point: $goalPoint');
      return;
    }

    if (_isCalculatingRoute) {
      debugPrint('Route calculation already in progress');
      return;
    }

    if (!_initContext.gridInitialized) {
      _showUserMessage('La grilla no está lista todavía', Colors.orange);
      return;
    }

    setState(() {
      _isCalculatingRoute = true;
    });

    try {
      final startCell = latLngToGrid(startPoint!);
      final goalCell = latLngToGrid(goalPoint!);

      // Enhanced debug logging
      debugPrint('=== CALCULATING ROUTE ===');
      debugPrint('Start point: $startPoint');
      debugPrint('Goal point: $goalPoint');
      debugPrint('Start cell: $startCell');
      debugPrint('Goal cell: $goalCell');
      debugPrint('Grid initialized: ${_initContext.gridInitialized}');

      // Validation: same cell check
      if (startCell == goalCell) {
        debugPrint('ERROR: Start and goal are in the same cell');
        _showUserMessage(
          'Selecciona un destino diferente al inicio',
          Colors.orange,
        );
        return;
      }

      // Validate grid bounds
      if (startCell.x < 0 ||
          startCell.x >= grid.length ||
          startCell.y < 0 ||
          startCell.y >= grid[0].length ||
          goalCell.x < 0 ||
          goalCell.x >= grid.length ||
          goalCell.y < 0 ||
          goalCell.y >= grid[0].length) {
        debugPrint('ERROR: Points are outside grid bounds');
        _showUserMessage('Puntos fuera de los límites del mapa', Colors.red);
        return;
      }

      final startNode = grid[startCell.x][startCell.y];
      final goalNode = grid[goalCell.x][goalCell.y];

      // Validate nodes are walkable
      if (!startNode.walkable || !goalNode.walkable) {
        debugPrint('ERROR: Start or goal node is not walkable');
        debugPrint('Start walkable: ${startNode.walkable}');
        debugPrint('Goal walkable: ${goalNode.walkable}');
        _showUserMessage(
          'Punto de inicio o destino no es accesible',
          Colors.orange,
        );
        return;
      }

      // Show loading message
      _showUserMessage('Calculando ruta...', Colors.blue);

      // ATOMIC PATH CALCULATION AND UPDATE
      final calculatedPath = await _executePathCalculation(
        startNode,
        goalNode,
        startCell,
        goalCell,
      );

      if (calculatedPath.isEmpty) {
        debugPrint('ERROR: No path found between points');
        _showUserMessage('No se encontró ruta entre los puntos', Colors.orange);
        return;
      }

      // Convert to coordinates
      final latLngPath =
          calculatedPath.map((node) => gridToLatLng(node)).toList();

      debugPrint('=== PATH CALCULATION SUCCESS ===');
      debugPrint('Path nodes: ${calculatedPath.length}');
      debugPrint('Path coordinates: ${latLngPath.length} points');
      debugPrint('First point: ${latLngPath.first}');
      debugPrint('Last point: ${latLngPath.last}');

      // ATOMIC STATE UPDATE - Single setState call for consistency
      if (mounted) {
        final routeCells =
            calculatedPath.map((n) => Point(n.row, n.col)).toList();
        final newVisiblePOIs =
            pointsOfInterest.where((poi) {
              return isPOINearRoute(poi.cell, routeCells);
            }).toList();

        setState(() {
          path = latLngPath;
          visiblePOIs = [...newVisiblePOIs, ..._userPOIs];
          _lastDistanceToGoalMeters = null;
        });

        debugPrint('=== STATE UPDATED SUCCESSFULLY ===');
        debugPrint('Final path length in state: ${path.length}');
        debugPrint('Visible POIs: ${visiblePOIs.length}');

        // Show success message
        _showUserMessage(
          'Ruta calculada: ${latLngPath.length} puntos',
          Colors.green,
        );
      }
    } catch (e, stackTrace) {
      debugPrint('=== PATH CALCULATION ERROR ===');
      debugPrint('Error: $e');
      debugPrint('Stack trace: $stackTrace');
      _showUserMessage('Error calculando la ruta: $e', Colors.red);
    } finally {
      if (mounted) {
        setState(() {
          _isCalculatingRoute = false;
        });
      } else {
        _isCalculatingRoute = false;
      }
    }
  }

  /// Execute path calculation with multiple fallback strategies
  Future<List<Node>> _executePathCalculation(
    Node startNode,
    Node goalNode,
    Point<int> startCell,
    Point<int> goalCell,
  ) async {
    debugPrint('=== EXECUTING PATH CALCULATION ===');

    // Strategy 1: Direct D* Lite calculation (most reliable)
    try {
      debugPrint('Trying direct D* Lite calculation...');
      final dStarLite = DStarLite(grid: grid, start: startNode, goal: goalNode);
      final directPath = dStarLite.computeShortestPath();

      if (directPath.isNotEmpty) {
        debugPrint('Direct calculation SUCCESS: ${directPath.length} nodes');
        return directPath;
      } else {
        debugPrint('Direct calculation returned empty path');
      }
    } catch (directError) {
      debugPrint('Direct calculation FAILED: $directError');
    }

    // Strategy 2: Background processor (if direct fails)
    try {
      debugPrint('Trying background processor calculation...');
      final nodePath = await BackgroundProcessor.instance
          .calculatePath(
            grid: grid,
            startX: startCell.x,
            startY: startCell.y,
            goalX: goalCell.x,
            goalY: goalCell.y,
          )
          .timeout(Duration(seconds: 10)); // Add timeout

      if (nodePath.isNotEmpty) {
        debugPrint('Background processor SUCCESS: ${nodePath.length} nodes');
        return nodePath;
      } else {
        debugPrint('Background processor returned empty path');
      }
    } catch (bgError) {
      debugPrint('Background processor FAILED: $bgError');
    }

    debugPrint('=== ALL PATH CALCULATION STRATEGIES FAILED ===');
    return [];
  }

  /// Helper method for consistent user messaging
  void _showUserMessage(String message, Color color) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: color,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Toggle calibration mode
  void _toggleCalibrationMode() {
    try {
      setState(() {
        _isCalibrationMode = !_isCalibrationMode;
        if (!_isCalibrationMode) {
          // Clear calibration points when exiting calibration mode
          _firstCalibrationPoint = null;
          _secondCalibrationPoint = null;
        }
      });

      _showUserMessage(
        _isCalibrationMode
            ? 'Modo de calibración activado'
            : 'Modo de calibración desactivado',
        _isCalibrationMode ? Colors.blue : Colors.orange,
      );
    } catch (e) {
      debugPrint('Error toggling calibration mode: $e');
      _showUserMessage('Error al cambiar modo de calibración', Colors.red);
    }
  }

  /// Toggle orientation cone visibility
  void _toggleOrientationCone() {
    try {
      setState(() {
        _showOrientationCone = !_showOrientationCone;
      });

      _showUserMessage(
        _showOrientationCone
            ? 'Cono de orientación activado'
            : 'Cono de orientación desactivado',
        _showOrientationCone ? Colors.green : Colors.orange,
      );
    } catch (e) {
      debugPrint('Error toggling orientation cone: $e');
      _showUserMessage('Error al cambiar configuración del cono', Colors.red);
    }
  }

  /// Update cone configuration based on theme or user preference
  void _updateConeConfiguration({OrientationConeConfig? newConfig}) {
    try {
      final config = newConfig ?? OrientationConeConfig.light();

      // Validate configuration before applying
      if (!config.isValid()) {
        debugPrint('Invalid cone configuration provided, using default');
        _coneConfig = OrientationConeConfig.light();
      } else {
        _coneConfig = config;
      }

      setState(() {});

      // Trigger cache validation for new configuration
      ConePathCache.validateCache();
    } catch (e) {
      debugPrint('Error updating cone configuration: $e');
      // Fallback to default configuration
      _coneConfig = OrientationConeConfig.light();
      _showUserMessage(
        'Error en configuración, usando valores por defecto',
        Colors.orange,
      );
    }
  }

  /// Switch cone theme (light/dark/high contrast)
  void _switchConeTheme(String theme) {
    try {
      late OrientationConeConfig newConfig;

      switch (theme.toLowerCase()) {
        case 'dark':
          newConfig = OrientationConeConfig.dark();
          break;
        case 'high_contrast':
          newConfig = OrientationConeConfig.highContrast();
          break;
        case 'performance':
          newConfig = OrientationConeConfig.performance();
          break;
        default:
          newConfig = OrientationConeConfig.light();
      }

      _updateConeConfiguration(newConfig: newConfig);
      _showUserMessage('Tema del cono cambiado a: $theme', Colors.blue);
    } catch (e) {
      debugPrint('Error switching cone theme: $e');
      _showUserMessage('Error al cambiar tema del cono', Colors.red);
    }
  }

  /// Simple viewport culling helper methods
  LatLngBounds _getVisibleBounds() {
    final camera = _mapController.camera;
    final bounds = camera.visibleBounds;
    const double padding = 0.1;

    final latSpan = bounds.north - bounds.south;
    final lngSpan = bounds.east - bounds.west;

    return LatLngBounds(
      LatLng(
        bounds.south - (latSpan * padding),
        bounds.west - (lngSpan * padding),
      ),
      LatLng(
        bounds.north + (latSpan * padding),
        bounds.east + (lngSpan * padding),
      ),
    );
  }

  bool _isPointVisible(LatLng point, LatLngBounds visibleBounds) {
    return point.latitude >= visibleBounds.south &&
        point.latitude <= visibleBounds.north &&
        point.longitude >= visibleBounds.west &&
        point.longitude <= visibleBounds.east;
  }

  int _calculateLOD(double zoomLevel) {
    if (zoomLevel < 16) return 20;
    if (zoomLevel < 17) return 10;
    if (zoomLevel < 18) return 5;
    if (zoomLevel < 19) return 2;
    return 1;
  }

  /// Get performance metrics stream for debug overlay
  Stream<String> _getPerformanceStream() {
    return Stream.periodic(const Duration(seconds: 1), (count) {
      if (!kDebugMode) return '';

      final metrics = PerformanceMonitor.instance.getMetrics();
      return 'FPS: ${metrics.currentFrameRate.toStringAsFixed(0)}\n'
          'Frame: ${metrics.averageFrameRate.toStringAsFixed(1)}fps\n'
          'Mem: ${metrics.currentMemoryUsage.toStringAsFixed(0)}MB\n'
          'Events: ${metrics.totalEvents}';
    });
  }

  List<Polyline> buildOptimizedGridLines() {
    final List<Polyline> lines = [];

    final endGridLat = startBounds.latitude + numRows * latStep;
    final endGridLng = startBounds.longitude + numCols * lngStep;

    // Get current zoom level for LOD
    double zoomLevel = 18.0; // Default zoom level
    try {
      // Safely get zoom level if controller is initialized
      if (_mapController.camera != null) {
        zoomLevel = _mapController.camera!.zoom;
      }
    } catch (e) {
      // Use default zoom level if there's an error
      debugPrint('Error getting zoom level: $e');
    }

    final int lod = _calculateLOD(zoomLevel);

    try {
      final visibleBounds = _getVisibleBounds();

      // Calculate visible range
      final startRow = ((visibleBounds.south - startBounds.latitude) / latStep)
          .floor()
          .clamp(0, numRows);
      final endRow = ((visibleBounds.north - startBounds.latitude) / latStep)
          .ceil()
          .clamp(0, numRows);
      final startCol = ((visibleBounds.west - startBounds.longitude) / lngStep)
          .floor()
          .clamp(0, numCols);
      final endCol = ((visibleBounds.east - startBounds.longitude) / lngStep)
          .ceil()
          .clamp(0, numCols);

      // Add horizontal lines with LOD
      for (int row = startRow; row <= endRow; row += lod) {
        final lat = startBounds.latitude + row * latStep;
        lines.add(
          Polyline(
            points: [
              LatLng(lat, startBounds.longitude),
              LatLng(lat, endGridLng),
            ],
            color: Colors.black,
            strokeWidth: 0.3,
          ),
        );
      }

      // Add vertical lines with LOD
      for (int col = startCol; col <= endCol; col += lod) {
        final lng = startBounds.longitude + col * lngStep;
        lines.add(
          Polyline(
            points: [
              LatLng(startBounds.latitude, lng),
              LatLng(endGridLat, lng),
            ],
            color: Colors.black,
            strokeWidth: 0.3,
          ),
        );
      }
    } catch (e) {
      // Fallback to simple grid with reduced density
      final gridStep = lod > 0 ? lod : 1;
      for (int r = 0; r <= numRows; r += gridStep) {
        final lat = startBounds.latitude + r * latStep;
        lines.add(
          Polyline(
            points: [
              LatLng(lat, startBounds.longitude),
              LatLng(lat, endGridLng),
            ],
            color: Colors.black.withOpacity(0.3),
            strokeWidth: 0.3,
          ),
        );
      }

      for (int j = 0; j <= numCols; j += gridStep) {
        final lng = startBounds.longitude + j * lngStep;
        lines.add(
          Polyline(
            points: [
              LatLng(startBounds.latitude, lng),
              LatLng(endGridLat, lng),
            ],
            color: Colors.black.withOpacity(0.3),
            strokeWidth: 0.3,
          ),
        );
      }
    }

    return lines;
  }

  // Calcula los puntos enteros entre dos celdas usando Bresenham
  List<Point<int>> _getCellsOnLine(Point<int> start, Point<int> end) {
    final points = <Point<int>>[];
    var x0 = start.x;
    var y0 = start.y;
    final x1 = end.x;
    final y1 = end.y;

    final dx = (x1 - x0).abs();
    final dy = (y1 - y0).abs();
    final sx = x0 < x1 ? 1 : -1;
    final sy = y0 < y1 ? 1 : -1;
    var err = dx - dy;

    while (true) {
      points.add(Point<int>(x0, y0));
      if (x0 == x1 && y0 == y1) break;
      final e2 = 2 * err;
      if (e2 > -dy) {
        err -= dy;
        x0 += sx;
      }
      if (e2 < dx) {
        err += dx;
        y0 += sy;
      }
    }

    return points;
  }

  void _toggleObstacleLineMode() {
    setState(() {
      _isObstacleLineMode = !_isObstacleLineMode;
      _obstacleLineStart = null;
    });

    _showUserMessage(
      _isObstacleLineMode
          ? 'Modo A-B activo: toca nodo A'
          : 'Modo A-B desactivado',
      _isObstacleLineMode ? Colors.redAccent : Colors.grey,
    );
  }

  Future<void> _handleObstacleLineTap(LatLng latlng) async {
    try {
      if (!_initContext.gridInitialized) {
        _showUserMessage('La grilla no esta lista para bloquear', Colors.orange);
        return;
      }

      final cell = latLngToGrid(latlng);

      if (_obstacleLineStart == null) {
        setState(() {
          _obstacleLineStart = cell;
        });
        _showUserMessage(
          'Nodo A (${cell.x}, ${cell.y}) seleccionado. Ahora toca nodo B.',
          Colors.orange,
        );
        return;
      }

      final startCell = _obstacleLineStart!;
      final endCell = cell;
      final lineCells = _getCellsOnLine(startCell, endCell)
          .where(_isCellWithinGrid)
          .toList();

      if (lineCells.isEmpty) {
        _showUserMessage('No se encontraron celdas para bloquear', Colors.red);
        return;
      }

      setState(() {
        for (final p in lineCells) {
          obstacles.add(p);
          grid[p.x][p.y].walkable = false;
        }
        _obstacleLineStart = null;
      });

      await saveObstacles();

      _showUserMessage(
        'Bloqueados ${lineCells.length} nodos entre A y B',
        Colors.redAccent,
      );
    } catch (e) {
      debugPrint('Error manejando linea de obstaculos: $e');
      _showUserMessage('No se pudo bloquear la linea', Colors.red);
    }
  }

  void toggleObstacle(LatLng latlng) async {
    final cell = latLngToGrid(latlng);

    setState(() {
      if (obstacles.contains(cell)) {
        // Unlock
        obstacles.remove(cell);
        grid[cell.x][cell.y].walkable = true;
      } else {
        // Block
        obstacles.add(cell);
        grid[cell.x][cell.y].walkable = false;
      }
    });

    await saveObstacles();
  }

  // For working with .json
  Future<void> saveObstacles() async {
    try {
      await _obstaclesRepo.save(obstacles);
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/obstacles.json');
      print('Obstáculos guardados en: ${file.path}');
    } catch (e) {
      debugPrint('Error guardando obstáculos: $e');
    }
  }

  Future<void> loadObstacles() async {
    try {
      final loaded = await _obstaclesRepo.load();
      if (mounted) {
        setState(() {
          obstacles = loaded;
        });
      } else {
        obstacles = loaded;
      }

      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/obstacles.json');
      if (await file.exists()) {
        print('Obstáculos cargados desde: ${file.path}');
      } else {
        print('Obstáculos cargados desde asset: assets/obst/obstacles.json');
      }
    } catch (e) {
      debugPrint('Error cargando obstáculos: $e');
    }
  }

  // For loading POIs from JSON file
  Future<void> loadPOIsFromJson() async {
    try {
      final String jsonString = await rootBundle.loadString('assets/pois.json');
      final List<dynamic> jsonList = json.decode(jsonString);

      final List<POI> loadedPOIs = [];
      for (final jsonItem in jsonList) {
        try {
          final poi = POI.fromJson(jsonItem);
          // Validate POI before adding
          if (_validatePOIData(poi)) {
            loadedPOIs.add(poi);
          } else {
            debugPrint('Skipping invalid POI: ${jsonItem}');
          }
        } catch (e) {
          debugPrint('Error parsing POI from JSON: $e, data: $jsonItem');
        }
      }

      if (mounted) {
        setState(() {
          pointsOfInterest = loadedPOIs;
        });
      }
      debugPrint(
        'Successfully loaded ${pointsOfInterest.length} valid POIs out of ${jsonList.length} total',
      );
    } catch (e) {
      debugPrint('Error loading POIs from JSON: $e');
      // Set empty list as fallback
      if (mounted) {
        setState(() {
          pointsOfInterest = [];
        });
      }
      // Don't rethrow - POIs are optional
    }
  }

  // To filter POIs near the calculated route
  bool isPOINearRoute(
    Point<int> poiCell,
    List<Point<int>> routeCells, {
    int distance = 2,
  }) {
    for (var cell in routeCells) {
      if ((poiCell.x - cell.x).abs() <= distance &&
          (poiCell.y - cell.y).abs() <= distance) {
        return true;
      }
    }
    return false;
  }

  // To follow orientation like a compass - Optimized with throttling
  Timer? _compassUpdateTimer;
  void _startCompassTracking() {
    _accelSub = accelerometerEventStream(
      samplingPeriod: const Duration(microseconds: 8000), // 125 Hz
    ).listen((AccelerometerEvent event) {
      _accelData = event;
      _throttledUpdateDeviceAngle();
    });

    _magSub = magnetometerEventStream(
      samplingPeriod: const Duration(microseconds: 8000), // 125 Hz
    ).listen((MagnetometerEvent event) {
      _magData = event;
      _throttledUpdateDeviceAngle();
    });
  }

  void _throttledUpdateDeviceAngle() {
    // Throttle compass updates to avoid excessive setState calls
    if (_compassUpdateTimer?.isActive == true) return;

    _compassUpdateTimer = Timer(const Duration(milliseconds: 100), () {
      _updateDeviceAngle();
    });
  }

  void _onFingerprintSelected(
    FingerprintSample? sample, {
    bool center = false,
  }) {
    setState(() {
      _selectedFingerprintSample = sample;
    });
    if (center && sample != null) {
      final target = _fingerprintToLatLng(sample.position);
      _mapController.move(target, _mapController.camera.zoom);
    }
  }

  void _toggleHeadingPointer() {
    setState(() {
      _showHeadingPointer = !_showHeadingPointer;
      _headingMap = _deviceAngle;
    });
  }

  double _headingDegrees() {
    final deg = _deviceAngle * 180 / math.pi;
    final normalized = (deg % 360 + 360) % 360;
    return normalized;
  }

  void _onFingerprintRepoChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Get visible obstacles using simple bounds checking
  List<Point<int>> _getVisibleObstacles() {
    try {
      final visibleBounds = _getVisibleBounds();
      return obstacles.where((obstacle) {
        final latlng = gridToLatLng(Node(row: obstacle.x, col: obstacle.y));
        return _isPointVisible(latlng, visibleBounds);
      }).toList();
    } catch (e) {
      // Fallback to all obstacles if viewport culling fails
      return obstacles.toList();
    }
  }

  LatLng _fingerprintToLatLng(LatLng positionMeters) {
    final lat =
        startBounds.latitude +
        (positionMeters.latitude / _mapHeightMeters) *
            (endBounds.latitude - startBounds.latitude);
    final lng =
        startBounds.longitude +
        (positionMeters.longitude / _mapWidthMeters) *
            (endBounds.longitude - startBounds.longitude);
    return LatLng(lat, lng);
  }

  List<Marker> _buildFingerprintMarkers() {
    final samples = _fingerprintRepository.samples;
    if (samples.isEmpty) return [];
    final markers = <Marker>[];
    for (final sample in samples) {
      final point = _fingerprintToLatLng(sample.position);
      final isSelected = identical(sample, _selectedFingerprintSample);
      markers.add(
        Marker(
          point: point,
          width: 12,
          height: 12,
          child: GestureDetector(
            onTap: () => _onFingerprintSelected(sample, center: true),
            child: Container(
              decoration: BoxDecoration(
                color:
                    isSelected ? Colors.green : Colors.purple.withOpacity(0.8),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white,
                  width: isSelected ? 2 : 1,
                ),
              ),
            ),
          ),
        ),
      );
      if (isSelected) {
        markers.add(
          Marker(
            point: point,
            width: 22,
            height: 22,
            child: IgnorePointer(
              child: Icon(
                Icons.my_location,
                color: Colors.green.withOpacity(0.8),
                size: 22,
              ),
            ),
          ),
        );
      }
    }
    return markers;
  }

  /// Get visible POIs using simple bounds checking
  List<POI> _getVisiblePOIs() {
    try {
      final visibleBounds = _getVisibleBounds();
      return visiblePOIs.where((poi) {
        final latlng = gridToLatLng(Node(row: poi.cell.x, col: poi.cell.y));
        return _isPointVisible(latlng, visibleBounds);
      }).toList();
    } catch (e) {
      // Fallback to all visible POIs if viewport culling fails
      return visiblePOIs;
    }
  }

  Widget _buildSafeFlutterMap() {
    // Check if initialization failed
    if (_mapInitializationFailed || !_initContext.hasMinimalRequirements) {
      return _buildInitializationErrorUI();
    }

    try {
      return FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: LatLng(
            (startBounds.latitude + endBounds.latitude) / 2,
            (startBounds.longitude + endBounds.longitude) / 2,
          ),
          initialZoom: 18,
          minZoom: 15,
          maxZoom: 25, // Increased from 22 to 25 for more zoom
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all,
          ),
          onTap: (tapPosition, latlng) {
            try {
              debugPrint('=== MAP TAP EVENT ===');
              debugPrint('Tap position: $latlng');
              debugPrint('Selecting start: $selectingStart');
              debugPrint('Current start point: $startPoint');
              debugPrint('Current goal point: $goalPoint');

              // Handle calibration mode
              if (_isCalibrationMode) {
                _handleCalibrationTap(latlng);
                return;
              }

              // Modo temporal para bloquear una linea de obstaculos A-B
              if (_isObstacleLineMode) {
                _handleObstacleLineTap(latlng);
                return;
              }

              if (_isAddingPOIMode) {
                _handleAddPOITap(latlng);
                return;
              }

              if (selectingStart) {
                setState(() {
                  startPoint = latlng;
                  selectingStart = false;
                  _currentPosition = latlng;
                  // Clear previous path when setting new start
                  path = [];
                  _lastDistanceToGoalMeters = null;
                });
                debugPrint('? Start point set to: $startPoint');
                if (_initContext.sensorsAvailable) {
                  _startCompassTracking();
                }
              } else {
                setState(() {
                  goalPoint = latlng;
                  selectingStart = true;
                  // Clear previous path when setting new goal
                  path = [];
                  _lastDistanceToGoalMeters = null;
                });
                debugPrint('Goal point set to: $goalPoint');

                // Calculate path if both points are set
                if (startPoint != null) {
                  debugPrint('Both points set, initiating path calculation...');
                  // Calculate path immediately after setState completes
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    calculatePath();
                  });
                } else {
                  debugPrint('Start point is null, cannot calculate path');
                }
              }
            } catch (e) {
              debugPrint('Error handling map tap: $e');
            }
          },
          onLongPress: (tapPosition, latlng) {
            try {
              toggleObstacle(latlng);
            } catch (e) {
              debugPrint('Error handling long press: $e');
            }
          },
        ),
        children: [
          // Image overlay - with fallback handling (BASE LAYER)
          if (_shouldShowMapImage())
            OverlayImageLayer(
              overlayImages: [
                OverlayImage(
                  bounds: LatLngBounds(startBounds, endBounds),
                  opacity: 1.0,
                  imageProvider: const AssetImage(kMapAssetPath),
                  gaplessPlayback: true,
                ),
              ],
            ),

          // Polygons - cell highlights (BACKGROUND ELEMENTS)
          if (_initContext.gridInitialized)
            RepaintBoundary(
              child: PolygonLayer(polygons: _buildSafePolygons()),
            ),

          // Grid lines and Route polylines (NAVIGATION LAYER)
          RepaintBoundary(
            child: PolylineLayer(
              polylineCulling: true,
              polylines: _buildSafePolylines(),
            ),
          ),

          // Fingerprint sample markers (TRAINING DATA)
          // Obstacle markers (OBSTACLE LAYER)
          if (_initContext.obstaclesLoaded)
            RepaintBoundary(
              child: MarkerLayer(
                markers: obstacles.map((point) {
                  final latlng = gridToLatLng(
                    Node(row: point.x, col: point.y),
                  );
                  return Marker(
                    width: 6,
                    height: 6,
                    point: latlng,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),

          // POI markers (INFORMATION LAYER)
          if (_initContext.poisLoaded)
            RepaintBoundary(
              child: MarkerLayer(
                markers:
                    _getVisiblePOIs()
                        .map((poi) {
                          try {
                            final node = grid[poi.cell.x][poi.cell.y];
                            final latlng = gridToLatLng(node);
                            return Marker(
                              point: latlng,
                              width: 40,
                              height: 40,
                              child: GestureDetector(
                                onTap: () {
                                  _showPOIDialog(poi);
                                },
                                child: RepaintBoundary(
                                  child: Icon(
                                    _iconForPOI(poi),
                                    color: Colors.deepPurpleAccent,
                                    size: 28,
                                  ),
                                ),
                              ),
                            );
                          } catch (e) {
                            debugPrint(
                              'Error creating POI marker for ${poi.name}: $e',
                            );
                            // Return empty marker as fallback
                            return Marker(
                              point: const LatLng(0, 0),
                              width: 0,
                              height: 0,
                              child: const SizedBox.shrink(),
                            );
                          }
                        })
                        .where((marker) => marker.width > 0)
                        .toList(),
              ),
            ),

          // Navigation markers - START/GOAL/CURRENT POSITION (TOP LAYER)
          RepaintBoundary(child: MarkerLayer(markers: _buildSafeMarkers())),

          // Fingerprint markers (TOP)
          RepaintBoundary(
            child: MarkerLayer(markers: _buildFingerprintMarkers()),
          ),

          // Arrow layer for movement tracking (ARROW LAYER)
          if (_globalSensorManager?.isRunning == true)
            RepaintBoundary(child: _buildArrowLayer()),
        ],
      );
    } catch (e) {
      debugPrint('Error building FlutterMap: $e');
      _initContext.addError('FlutterMap build failed: $e');
      return _buildMapErrorUI(e.toString());
    }
  }

  /// Handle tap in calibration mode
  void _handleCalibrationTap(LatLng latlng) {
    try {
      final tappedCell = latLngToGrid(latlng);

      setState(() {
        if (_firstCalibrationPoint == null) {
          _firstCalibrationPoint = tappedCell;
        } else if (_secondCalibrationPoint == null) {
          _secondCalibrationPoint = tappedCell;
        } else {
          // If both points are already selected, replace the second point
          _secondCalibrationPoint = tappedCell;
        }
      });

      _showUserMessage(
        _secondCalibrationPoint == null
            ? 'Primer punto de calibración seleccionado'
            : 'Segundo punto de calibración seleccionado',
        Colors.blue,
      );
    } catch (e) {
      debugPrint('Error handling calibration tap: $e');
      _showUserMessage('Error al seleccionar punto de calibración', Colors.red);
    }
  }

  Widget _buildInitializationErrorUI() {
    return Container(
      color: Colors.grey[100],
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.warning, size: 72, color: Colors.orange),
              SizedBox(height: 24),
              Text(
                'Map Initialization Failed',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 16),
              Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[300]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Status:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 8),
                    Text(_initContext.statusSummary),
                    if (_initContext.errors.isNotEmpty) ...[
                      SizedBox(height: 12),
                      Text(
                        'Recent Errors:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                        ),
                      ),
                      SizedBox(height: 4),
                      ...(_initContext.errors
                          .take(3)
                          .map(
                            (error) => Padding(
                              padding: EdgeInsets.only(bottom: 4),
                              child: Text(
                                error,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.red[700],
                                ),
                              ),
                            ),
                          )),
                    ],
                  ],
                ),
              ),
              SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: _retryInitialization,
                    icon: Icon(Icons.refresh),
                    label: Text('Retry'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  SizedBox(width: 16),
                  OutlinedButton.icon(
                    onPressed: _showDiagnosticInfo,
                    icon: Icon(Icons.info_outline),
                    label: Text('Details'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMapErrorUI(String error) {
    return Container(
      color: Colors.grey[300],
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Colors.red),
            SizedBox(height: 16),
            Text(
              'Map Rendering Failed',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              'Technical Issue: $error',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: _retryInitialization,
              child: Text('Restart App'),
            ),
          ],
        ),
      ),
    );
  }

  void _updateDeviceAngle() {
    if (_accelData == null || _magData == null) return;

    final ax = _accelData!.x;
    final ay = _accelData!.y;
    final az = _accelData!.z;

    final mx = _magData!.x;
    final my = _magData!.y;
    final mz = _magData!.z;

    final normA = math.sqrt(ax * ax + ay * ay + az * az);
    final normM = math.sqrt(mx * mx + my * my + mz * mz);

    if (normA == 0 || normM == 0) return;

    // Track reference magnetic magnitude and skip updates on large perturbations
    _magNormReference ??= normM;
    final lower = _magNormReference! * 0.7;
    final upper = _magNormReference! * 1.3;
    if (normM < lower || normM > upper) {
      // Field disturbed, keep previous heading
      return;
    }
    // Slowly adapt reference to gradual changes
    _magNormReference = _magNormReference! * 0.99 + normM * 0.01;

    final axn = ax / normA;
    final ayn = ay / normA;
    final azn = az / normA;

    final mxn = mx / normM;
    final myn = my / normM;
    final mzn = mz / normM;

    final hx = myn * azn - mzn * ayn;
    final hy = mzn * axn - mxn * azn;
    final hz = mxn * ayn - myn * axn;

    final normH = math.sqrt(hx * hx + hy * hy + hz * hz);
    if (normH == 0.0) return;

    final hxNorm = hx / normH;
    final hyNorm = hy / normH;

    final angle = math.atan2(hyNorm, hxNorm); // Angle in radians
    final adjusted = _normalizeAngle(angle + _headingOffsetRad);

    // Smooth heading to reduce jitter
    if (_headingMap == 0.0) {
      _headingMap = adjusted;
    } else {
      final diff = _normalizeAngle(adjusted - _headingMap);
      _headingMap = _normalizeAngle(
        _headingMap + _headingSmoothingAlpha * diff,
      );
    }

    // Apply deadband to avoid tiny oscillations
    final delta = _normalizeAngle(_headingMap - _deviceAngle);
    if (delta.abs() < _headingDeadband) return;

    setState(() {
      _deviceAngle = _headingMap;
    });
  }

  double _normalizeAngle(double angle) {
    while (angle > math.pi) {
      angle -= 2 * math.pi;
    }
    while (angle < -math.pi) {
      angle += 2 * math.pi;
    }
    return angle;
  }

  // Helper methods for safe UI building
  bool _shouldShowMapImage() {
    try {
      // Check if the map overlay should be shown
      // Ensure grid is initialized before showing overlay
      return _initContext.gridInitialized;
    } catch (e) {
      debugPrint('Error checking map image availability: $e');
      return false;
    }
  }

  List<Marker> _buildSafeMarkers() {
    try {
      List<Marker> markers = [];

      if (startPoint != null) {
        markers.add(
          Marker(
            point: startPoint!,
            width: 40,
            height: 40,
            child: const Icon(Icons.location_on, color: Colors.green, size: 50),
          ),
        );
      }

      if (goalPoint != null) {
        markers.add(
          Marker(
            point: goalPoint!,
            width: 40,
            height: 40,
            child: const Icon(Icons.flag, color: Colors.red, size: 50),
          ),
        );
      }

      // Add arrow path trail markers (if enabled) - DISABLED
      /*
      if (_arrowPath.isNotEmpty && _globalSensorManager?.isRunning == true) {
        for (int i = 0; i < _arrowPath.length - 1; i++) {
          final arrowState = _arrowPath[i];
          if (arrowState.isVisible) {
            markers.add(Marker(
              point: arrowState.position,
              width: 20,
              height: 20,
              child: RepaintBoundary(
                child: Opacity(
                  opacity: 0.4, // Trail markers are more transparent
                  child: Transform.rotate(
                    angle: arrowState.normalizedRotation * pi / 180,
                    child: Icon(
                      Icons.navigation,
                      color: Colors.blueGrey,
                      size: 16,
                    ),
                  ),
                ),
              ),
            ));
          }
        }
      }
      */

      // Add current arrow marker (main position indicator) - DISABLED
      /*
      if (_currentArrowState != null && _currentArrowState!.isVisible) {
        markers.add(Marker(
          point: _currentArrowState!.position,
          width: _currentArrowState!.size,
          height: _currentArrowState!.size,
          child: RepaintBoundary(
            child: AnimatedOpacity(
              opacity: _currentArrowState!.opacity,
              duration: const Duration(milliseconds: 300),
              child: AnimatedScale(
                scale: _currentArrowState!.scale,
                duration: const Duration(milliseconds: 200),
                child: Transform.rotate(
                  angle: _currentArrowState!.normalizedRotation * pi / 180,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.navigation,
                      color: Colors.blue,
                      size: _currentArrowState!.size * 0.8,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ));
      }
      */

      // Heading pointer overlay when enabled
      if (_showHeadingPointer && _currentPosition != null) {
        final headingAngle = _deviceAngle;
        final headingDeg = (headingAngle * 180 / math.pi) % 360;
        final headingText =
            '${headingDeg < 0 ? headingDeg + 360 : headingDeg.toStringAsFixed(0)}°';
        markers.add(
          Marker(
            point: _currentPosition!,
            width: 60,
            height: 60,
            child: IgnorePointer(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Transform.rotate(
                    angle: headingAngle,
                    child: const Icon(
                      Icons.navigation,
                      color: Colors.orange,
                      size: 36,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      headingText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      return markers;
    } catch (e) {
      debugPrint('Error building markers: $e');
      return [];
    }
  }

  List<Polygon> _buildSafePolygons() {
    try {
      List<Polygon> polygons = [];

      // Add visited cells with blue color
      for (final cell in visitedCells) {
        polygons.add(
          Polygon(
            points: getCellPolygon(cell.x, cell.y),
            borderColor: Colors.blue,
            borderStrokeWidth: 1,
            color: Colors.blue.withOpacity(0.3),
          ),
        );
      }

      if (startPoint != null) {
        polygons.add(
          Polygon(
            points: getCellPolygon(
              latLngToGrid(startPoint!).x,
              latLngToGrid(startPoint!).y,
            ),
            borderColor: Colors.green,
            borderStrokeWidth: 2,
            color: Colors.green.withOpacity(0.3),
          ),
        );
      }

      if (goalPoint != null) {
        polygons.add(
          Polygon(
            points: getCellPolygon(
              latLngToGrid(goalPoint!).x,
              latLngToGrid(goalPoint!).y,
            ),
            borderColor: Colors.red,
            borderStrokeWidth: 2,
            color: Colors.red.withOpacity(0.3),
          ),
        );
      }

      // Add calibration points in calibration mode
      if (_isCalibrationMode) {
        if (_firstCalibrationPoint != null) {
          polygons.add(
            Polygon(
              points: getCellPolygon(
                _firstCalibrationPoint!.x,
                _firstCalibrationPoint!.y,
              ),
              borderColor: Colors.blue,
              borderStrokeWidth: 3,
              color: Colors.blue.withOpacity(0.5),
            ),
          );
        }

        if (_secondCalibrationPoint != null) {
          polygons.add(
            Polygon(
              points: getCellPolygon(
                _secondCalibrationPoint!.x,
                _secondCalibrationPoint!.y,
              ),
              borderColor: Colors.blue,
              borderStrokeWidth: 3,
              color: Colors.blue.withOpacity(0.5),
            ),
          );
        }
      }

      return polygons;
    } catch (e) {
      debugPrint('Error building polygons: $e');
      return [];
    }
  }

  List<Polyline> _buildSafePolylines() {
    try {
      List<Polyline> polylines = [];

      debugPrint('=== BUILDING POLYLINES ===');
      debugPrint('Path length: ${path.length}');
      debugPrint('Grid initialized: ${_initContext.gridInitialized}');

      // PRIORITY 1: ROUTE POLYLINES (HIGHEST PRIORITY)
      if (path.isNotEmpty && path.length >= 2) {
        debugPrint('=== ADDING ROUTE POLYLINES ===');
        debugPrint('Route points: ${path.length}');
        debugPrint('Route starts at: ${path.first}');
        debugPrint('Route ends at: ${path.last}');

        // Create white border first (renders underneath)
        final routeBorder = Polyline(
          points: path,
          color: Colors.white,
          strokeWidth: 10.0, // Wider border for maximum visibility
          isDotted: false,
          useStrokeWidthInMeter: false,
        );
        polylines.add(routeBorder);

        // Create main blue route on top
        final routePolyline = Polyline(
          points: path,
          color: Colors.blue.shade700, // Darker blue for better contrast
          strokeWidth: 6.0,
          isDotted: false,
          useStrokeWidthInMeter: false,
        );
        polylines.add(routePolyline);

        debugPrint('? Route polylines added: border + main route');
        debugPrint('? Route color: Blue (${Colors.blue.shade700})');
        debugPrint('? Route width: 6.0px with 10.0px white border');
      } else {
        if (path.isEmpty) {
          debugPrint('?? WARNING: Path is empty - no route to display');
        } else {
          debugPrint(
            '?? WARNING: Path has only ${path.length} point(s) - need at least 2 for polyline',
          );
        }
      }

      // PRIORITY 2: GRID LINES (BACKGROUND)
      if (_initContext.gridInitialized) {
        final gridLines = buildOptimizedGridLines();
        polylines.addAll(gridLines);
        debugPrint('Added ${gridLines.length} grid lines (background)');
      }

      debugPrint('=== POLYLINES BUILD COMPLETE ===');
      debugPrint('Total polylines: ${polylines.length}');
      debugPrint(
        'Route polylines: ${path.isNotEmpty && path.length >= 2 ? 2 : 0} (border + main)',
      );

      return polylines;
    } catch (e, stackTrace) {
      debugPrint('=== ERROR BUILDING POLYLINES ===');
      debugPrint('Error: $e');
      debugPrint('Stack trace: $stackTrace');

      // Fallback: return at least grid lines
      try {
        if (_initContext.gridInitialized) {
          final fallbackGridLines = buildOptimizedGridLines();
          debugPrint(
            'Fallback: returning ${fallbackGridLines.length} grid lines only',
          );
          return fallbackGridLines;
        }
      } catch (gridError) {
        debugPrint('Fallback grid lines also failed: $gridError');
      }

      debugPrint('Returning empty polylines list as final fallback');
      return [];
    }
  }

  void _showPOIDialog(POI poi) {
    try {
      showDialog(
        context: context,
        builder:
            (_) => AlertDialog(
              title: Text(poi.name),
              content: Text(poi.description),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cerrar'),
                ),
              ],
            ),
      );
    } catch (e) {
      debugPrint('Error showing POI dialog: $e');
    }
  }

  void _retryInitialization() {
    try {
      _initContext.retryCount++;
      _initializeMapComponents();
    } catch (e) {
      debugPrint('Error retrying initialization: $e');
    }
  }

  void _showDiagnosticInfo() {
    try {
      showDialog(
        context: context,
        builder:
            (_) => AlertDialog(
              title: Text('Diagnostic Information'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Initialization Status:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 8),
                    Text('Grid: ${_initContext.gridInitialized ? "?" : "?"}'),
                    Text(
                      'Sensors: ${_initContext.sensorsAvailable ? "?" : "?"}',
                    ),
                    Text(
                      'Animations: ${_initContext.animationsEnabled ? "?" : "?"}',
                    ),
                    Text('POIs: ${_initContext.poisLoaded ? "?" : "?"}'),
                    Text(
                      'Obstacles: ${_initContext.obstaclesLoaded ? "?" : "?"}',
                    ),
                    SizedBox(height: 16),
                    Text('Retry Count: ${_initContext.retryCount}'),
                    if (_initContext.lastAttempt != null)
                      Text('Last Attempt: ${_initContext.lastAttempt}'),
                    SizedBox(height: 16),
                    if (_initContext.errors.isNotEmpty) ...[
                      Text(
                        'Error Log:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 8),
                      ...(_initContext.errors.map(
                        (error) => Padding(
                          padding: EdgeInsets.only(bottom: 4),
                          child: Text(error, style: TextStyle(fontSize: 10)),
                        ),
                      )),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
      );
    } catch (e) {
      debugPrint('Error showing diagnostic info: $e');
    }
  }

  /// Build arrow layer for movement tracking
  Widget _buildArrowLayer() {
    try {
      final renderingData = _gridConverter.getArrowRenderingData(
        _currentArrowState,
        _arrowPath,
      );
      final currentArrow = renderingData['currentArrow'] as ArrowState?;
      final trail = renderingData['trail'] as List<ArrowState>;

      final markers = <Marker>[];

      // Add trail markers (older positions)
      for (final trailState in trail) {
        if (ArrowAnimationHelper.isValidForRendering(trailState)) {
          markers.add(_buildArrowMarker(trailState, isTrailPoint: true));
        }
      }

      // Add current arrow marker (most recent position)
      if (currentArrow != null &&
          ArrowAnimationHelper.isValidForRendering(currentArrow)) {
        markers.add(_buildArrowMarker(currentArrow, isTrailPoint: false));
      }

      return MarkerLayer(markers: markers);
    } catch (e) {
      debugPrint('Error building arrow layer: $e');
      return MarkerLayer(markers: []);
    }
  }

  /// Build individual arrow marker with orientation cone
  Marker _buildArrowMarker(
    ArrowState arrowState, {
    required bool isTrailPoint,
  }) {
    try {
      // Validate arrow state
      if (!_validateArrowState(arrowState)) {
        debugPrint('Invalid arrow state detected, using fallback');
        return _buildFallbackMarker(arrowState, isTrailPoint);
      }

      if (!_showOrientationCone) {
        return _buildFallbackMarker(arrowState, isTrailPoint);
      }

      final size = isTrailPoint ? 20.0 : 32.0;
      final color =
          isTrailPoint ? Colors.orange.withOpacity(0.6) : Colors.orange;
      final opacity =
          isTrailPoint ? arrowState.trailOpacity : arrowState.opacity;

      return Marker(
        point: arrowState.position,
        width: size,
        height: size,
        child: RepaintBoundary(
          child: AnimatedOpacity(
            opacity: opacity,
            duration: const Duration(milliseconds: 200),
            child: Transform.rotate(
              // Use heading angle (smoothed) to avoid erratic jumps
              angle: _deviceAngle,
              child: Icon(Icons.navigation, color: color, size: size),
            ),
          ),
        ),
      );
    } catch (e) {
      debugPrint('Error building arrow marker: $e');
      return _buildFallbackMarker(arrowState, isTrailPoint);
    }
  }

  /// Validate arrow state for safe rendering
  bool _validateArrowState(ArrowState arrowState) {
    try {
      return arrowState.position.latitude.isFinite &&
          arrowState.position.longitude.isFinite &&
          arrowState.rotation.isFinite &&
          arrowState.scale > 0 &&
          arrowState.scale.isFinite &&
          arrowState.confidence >= 0 &&
          arrowState.confidence <= 1 &&
          arrowState.size > 0;
    } catch (e) {
      debugPrint('Error validating arrow state: $e');
      return false;
    }
  }

  /// Build fallback marker for error cases
  Marker _buildFallbackMarker(ArrowState arrowState, bool isTrailPoint) {
    return Marker(
      point: arrowState.position,
      width: 30,
      height: 30,
      child: Icon(
        isTrailPoint ? Icons.circle : Icons.navigation,
        color:
            isTrailPoint
                ? Colors.grey.withOpacity(0.6)
                : Colors.blue.withOpacity(0.7),
        size: isTrailPoint ? 8 : 20,
      ),
    );
  }

  /// Build legacy arrow widget (fallback without cone)
  Widget _buildLegacyArrowWidget(ArrowState arrowState, bool isTrailPoint) {
    return AnimatedOpacity(
      opacity: isTrailPoint ? arrowState.trailOpacity : arrowState.opacity,
      duration: const Duration(milliseconds: 200),
      child: Transform.rotate(
        angle: arrowState.rotation * pi / 180,
        child: AnimatedContainer(
          duration: Duration(milliseconds: isTrailPoint ? 100 : 300),
          child: AnimatedScale(
            scale: arrowState.scale,
            duration: Duration(milliseconds: isTrailPoint ? 100 : 200),
            child: Icon(
              isTrailPoint ? Icons.circle : Icons.navigation,
              color: isTrailPoint ? Colors.blue.withOpacity(0.6) : Colors.blue,
              size: isTrailPoint ? 12 : 30,
              shadows: [
                Shadow(
                  offset: const Offset(1, 1),
                  blurRadius: 2,
                  color: Colors.black.withOpacity(0.3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Calculate distance between two grid points
  double _calculateGridDistance(Point<int> point1, Point<int> point2) {
    try {
      // Calculate Euclidean distance between grid points
      final dx = (point2.x - point1.x).abs();
      final dy = (point2.y - point1.y).abs();
      return sqrt(dx * dx + dy * dy);
    } catch (e) {
      debugPrint('Error calculating grid distance: $e');
      return 0.0;
    }
  }

  /// Apply calibration based on selected points
  void _applyCalibration() {
    if (_firstCalibrationPoint == null || _secondCalibrationPoint == null) {
      _showUserMessage('Seleccione dos puntos para calibrar', Colors.orange);
      return;
    }

    try {
      // Calculate current distance in grid cells
      final currentDistance = _calculateGridDistance(
        _firstCalibrationPoint!,
        _secondCalibrationPoint!,
      );

      if (currentDistance <= 0) {
        _showUserMessage('Distancia inválida entre puntos', Colors.red);
        return;
      }

      // Calculate the scaling factor needed
      final targetDistance =
          _calibrationDistanceCm /
          10.0; // Convert cm to grid cells (10cm per cell)
      final scaleFactor = targetDistance / currentDistance;

      // Show calibration info
      _showUserMessage(
        'Calibración: ${currentDistance.toStringAsFixed(1)} -> ${targetDistance.toStringAsFixed(1)} celdas (${scaleFactor.toStringAsFixed(2)}x)',
        Colors.blue,
      );

      // For now, just show info. In a full implementation, we would adjust the grid metrics.
      // This would require recalculating latStep and lngStep based on the scaling factor.

      debugPrint('Calibration info:');
      debugPrint(
        '  Current distance: ${currentDistance.toStringAsFixed(2)} grid cells',
      );
      debugPrint(
        '  Target distance: ${targetDistance.toStringAsFixed(2)} grid cells',
      );
      debugPrint('  Scale factor: ${scaleFactor.toStringAsFixed(4)}');
    } catch (e) {
      debugPrint('Error applying calibration: $e');
      _showUserMessage('Error en la calibración: $e', Colors.red);
    }
  }
}

// Shared animation controller for all POI icons to optimize performance
class OptimizedAnimatedPOIIcon extends StatelessWidget {
  // Use static shared controller to avoid creating multiple animation controllers
  static AnimationController? _sharedController;
  static Animation<double>? _scaleAnimation;
  static bool _isInitialized = false;

  static void initSharedController(TickerProvider vsync) {
    if (_isInitialized && _sharedController != null) return;

    try {
      _sharedController?.dispose(); // Dispose previous controller if any
      _sharedController = AnimationController(
        vsync: vsync,
        duration: const Duration(seconds: 2),
      );

      _scaleAnimation = Tween(begin: 1.0, end: 1.2).animate(
        CurvedAnimation(parent: _sharedController!, curve: Curves.easeInOut),
      );

      _sharedController!.repeat(reverse: true);
      _isInitialized = true;
    } catch (e) {
      debugPrint('Error initializing shared controller: $e');
      _sharedController = null;
      _scaleAnimation = null;
      _isInitialized = false;
    }
  }

  static void disposeSharedController() {
    try {
      _sharedController?.dispose();
    } catch (e) {
      debugPrint('Error disposing shared controller: $e');
    } finally {
      _sharedController = null;
      _scaleAnimation = null;
      _isInitialized = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Always check initialization state and controller validity
    if (!_isInitialized ||
        _sharedController == null ||
        _scaleAnimation == null) {
      // Fallback to static icon if controller not properly initialized
      return const Icon(Icons.info, color: Colors.deepPurpleAccent, size: 28);
    }

    try {
      return AnimatedBuilder(
        animation: _scaleAnimation!,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation!.value,
            child: const Icon(
              Icons.info,
              color: Colors.deepPurpleAccent,
              size: 28,
            ),
          );
        },
      );
    } catch (e) {
      debugPrint('Error in OptimizedAnimatedPOIIcon build: $e');
      // Return static icon as fallback
      return const Icon(Icons.info, color: Colors.deepPurpleAccent, size: 28);
    }
  }
}

class AnimatedPOIIcon extends StatefulWidget {
  @override
  _AnimatedPOIIconState createState() => _AnimatedPOIIconState();
}

// For POI icon animation
class _AnimatedPOIIconState extends State<AnimatedPOIIcon>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    try {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 1),
      );
      _controller?.repeat(reverse: true);
    } catch (e) {
      debugPrint('Error initializing AnimationController: $e');
      _controller = null;
    }
  }

  @override
  void dispose() {
    try {
      _controller?.dispose();
    } catch (e) {
      debugPrint('Error disposing AnimationController: $e');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // If controller is null, return static icon
    if (_controller == null) {
      return const Icon(Icons.info, color: Colors.deepPurpleAccent, size: 28);
    }

    try {
      return ScaleTransition(
        scale: Tween(begin: 1.0, end: 1.3).animate(
          CurvedAnimation(parent: _controller!, curve: Curves.easeInOut),
        ),
        child: const Icon(Icons.info, color: Colors.deepPurpleAccent, size: 28),
      );
    } catch (e) {
      debugPrint('Error in AnimatedPOIIcon build: $e');
      // Return static icon as fallback
      return const Icon(Icons.info, color: Colors.deepPurpleAccent, size: 28);
    }
  }
}
