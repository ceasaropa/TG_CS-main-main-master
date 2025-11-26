import 'dart:math';
import 'package:latlong2/latlong.dart';
import 'package:proyecto_imu_v1_3/models/sensor_states.dart';
import 'package:proyecto_imu_v1_3/utils/arrow_animation_helper.dart';

/// Enhanced grid coordinate conversion system for the map interface
/// Handles conversion between meters, grid coordinates, and LatLng with 10cm precision
class MapGridConverter {
  // Grid configuration constants
  static const double gridScale = 0.1; // 10cm per grid unit
  static const int defaultGridRows = 400;
  
  // Map bounds (should match MapScreen bounds)
  final LatLng startBounds;
  final LatLng endBounds;
  
  // Grid dimensions
  final int numRows;
  final int numCols;
  final double latStep;
  final double lngStep;
  
  // Real-world distance per grid cell (in meters)
  final double metersPerCell;
  
  MapGridConverter({
    required this.startBounds,
    required this.endBounds,
    int? fixedRows,
  }) : 
    numRows = fixedRows ?? defaultGridRows,
    latStep = (endBounds.latitude - startBounds.latitude) / (fixedRows ?? defaultGridRows),
    lngStep = (endBounds.latitude - startBounds.latitude) / (fixedRows ?? defaultGridRows), // Square grid cells
    numCols = ((endBounds.longitude - startBounds.longitude) / 
              ((endBounds.latitude - startBounds.latitude) / (fixedRows ?? defaultGridRows))).floor(),
    metersPerCell = _calculateMetersPerCell(startBounds, endBounds, fixedRows);

  /// Calculate real-world meters per grid cell
  static double _calculateMetersPerCell(LatLng startBounds, LatLng endBounds, int? fixedRows) {
    final rows = fixedRows ?? defaultGridRows;
    final latSpan = endBounds.latitude - startBounds.latitude;
    
    // Calculate meters per degree of latitude (approximately 111,320 meters per degree)
    final metersPerDegreeLat = 111320.0;
    
    // Calculate the real-world height of the map in meters
    final mapHeightMeters = latSpan * metersPerDegreeLat;
    
    // Calculate meters per grid cell
    final metersPerCell = mapHeightMeters / rows;
    
    return metersPerCell;
  }
  
  /// Convert meters to grid units using 10cm scale
  static double metersToGrid(double meters) {
    return meters / gridScale;
  }
  
  /// Convert grid units to meters using 10cm scale
  static double gridToMeters(double gridUnits) {
    return gridUnits * gridScale;
  }
  
  /// Convert position state (in meters) to grid coordinates
  Map<String, double> positionToGrid(PositionState position) {
    return {
      'gridX': metersToGrid(position.x),
      'gridY': metersToGrid(position.y),
      'rotation': position.angle,
    };
  }
  
  /// Convert grid coordinates to position state (in meters)
  PositionState gridToPosition(double gridX, double gridY, {double angle = 0.0, double accuracy = 1.0}) {
    return PositionState(
      x: gridToMeters(gridX),
      y: gridToMeters(gridY),
      angle: angle,
      accuracy: accuracy,
      timestamp: DateTime.now(),
    );
  }
  
  /// Convert position state to map coordinates (LatLng)
  LatLng positionToLatLng(PositionState position, LatLng startPosition) {
    // Convert meters directly to lat/lng offset from start position
    // Using the proper conversion factors for the map area
    final latOffset = position.y / 111320.0; // Approximate meters per degree latitude
    final lngOffset = position.x / (111320.0 * cos(startPosition.latitude * pi / 180)); // Adjust for longitude
    
    return LatLng(
      startPosition.latitude + latOffset,
      startPosition.longitude + lngOffset,
    );
  }
  
  /// Convert grid coordinates to LatLng map coordinates
  LatLng gridToLatLng(double gridX, double gridY, LatLng startPosition) {
    // Convert grid units back to meters
    final metersX = gridToMeters(gridX);
    final metersY = gridToMeters(gridY);
    
    // Convert meters to lat/lng offset from start position
    final latOffset = metersY / 111320.0; // Approximate meters per degree latitude
    final lngOffset = metersX / (111320.0 * cos(startPosition.latitude * pi / 180)); // Adjust for longitude
    
    return LatLng(
      startPosition.latitude + latOffset,
      startPosition.longitude + lngOffset,
    );
  }
  
  /// Convert LatLng coordinates to grid coordinates
  Map<String, double> latLngToGrid(LatLng point) {
    final row = ((point.latitude - startBounds.latitude) / latStep).floor();
    final col = ((point.longitude - startBounds.longitude) / lngStep).floor();
    
    return {
      'gridX': row.clamp(0, numRows - 1).toDouble(),
      'gridY': col.clamp(0, numCols - 1).toDouble(),
    };
  }
  
  /// Convert grid coordinates to LatLng within map bounds
  LatLng gridCoordsToLatLng(int row, int col) {
    final lat = startBounds.latitude + row * latStep + latStep / 2;
    final lng = startBounds.longitude + col * lngStep + lngStep / 2;
    
    return LatLng(lat, lng);
  }
  
  /// Calculate the optimal arrow position on the map based on current position
  ArrowState calculateArrowState(PositionState position, LatLng startMapPosition, {double? customSpeed, double? compassAngle}) {
    // Convert position to map coordinates
    final mapPosition = positionToLatLng(position, startMapPosition);
    
    // Validate that the position is within map bounds
    if (!isWithinMapBounds(mapPosition)) {
      return ArrowState.hidden(startMapPosition);
    }
    
    // Calculate movement speed if not provided
    final speed = customSpeed ?? 0.0;
    
    // Use compass angle if provided, otherwise use position angle
    // Convert compass angle from radians to degrees if needed
    final rotationAngle = compassAngle != null 
        ? (compassAngle * 180 / pi) // Convert radians to degrees
        : position.angle;
    
    // Create arrow state with appropriate confidence and visibility
    return ArrowState.fromPosition(
      position,
      mapPosition,
      customRotation: rotationAngle,
      scale: ArrowAnimationHelper.calculateScaleFromSpeed(speed),
      speed: speed,
      isTrailPoint: false,
    );
  }
  
  /// Create a path of arrow states from position history with trail management
  List<ArrowState> createArrowPath(List<PositionState> positionHistory, LatLng startMapPosition, {int maxTrailPoints = 50}) {
    final arrowStates = <ArrowState>[];
    
    for (int i = 0; i < positionHistory.length; i++) {
      final position = positionHistory[i];
      final mapPosition = positionToLatLng(position, startMapPosition);
      
      // Skip if position is outside map bounds
      if (!isWithinMapBounds(mapPosition)) continue;
      
      // Calculate speed for this position
      final speed = 0.0; // Simplified for now
      
      final arrowState = ArrowState.fromPosition(
        position,
        mapPosition,
        customRotation: position.angle,
        scale: ArrowAnimationHelper.calculateScaleFromSpeed(speed),
        speed: speed,
        isTrailPoint: i < positionHistory.length - 1, // Only last position is not a trail point
      );
      
      // Adjust visibility and opacity based on position in history
      final isRecent = i >= positionHistory.length - maxTrailPoints;
      if (isRecent && arrowState.isVisible) {
        arrowStates.add(arrowState);
      }
    }
    
    return arrowStates;
  }
  
  /// Calculate grid cell polygon for visualization
  List<LatLng> getGridCellPolygon(int row, int col) {
    final north = startBounds.latitude + row * latStep;
    final south = north + latStep;
    final west = startBounds.longitude + col * lngStep;
    final east = west + lngStep;
    
    return [
      LatLng(north, west),
      LatLng(north, east),
      LatLng(south, east),
      LatLng(south, west),
    ];
  }
  
  /// Validate if a grid coordinate is within bounds
  bool isValidGridCoordinate(double gridX, double gridY) {
    return gridX >= 0 && gridX < numRows && gridY >= 0 && gridY < numCols;
  }
  
  /// Validate if a LatLng point is within map bounds
  bool isWithinMapBounds(LatLng point) {
    return point.latitude >= startBounds.latitude &&
           point.latitude <= endBounds.latitude &&
           point.longitude >= startBounds.longitude &&
           point.longitude <= endBounds.longitude;
  }
  
  /// Calculate distance between two positions in meters
  double calculateDistanceMeters(PositionState pos1, PositionState pos2) {
    final dx = pos2.x - pos1.x;
    final dy = pos2.y - pos1.y;
    return sqrt(dx * dx + dy * dy);
  }
  
  /// Calculate distance between two LatLng points in meters (approximate)
  double calculateLatLngDistance(LatLng point1, LatLng point2) {
    final distance = Distance();
    return distance.as(LengthUnit.Meter, point1, point2);
  }
  
  /// Get grid dimensions info
  Map<String, dynamic> getGridInfo() {
    return {
      'numRows': numRows,
      'numCols': numCols,
      'latStep': latStep,
      'lngStep': lngStep,
      'gridScale': gridScale,
      'metersPerCell': metersPerCell,
      'totalCells': numRows * numCols,
      'mapArea': {
        'latSpan': endBounds.latitude - startBounds.latitude,
        'lngSpan': endBounds.longitude - startBounds.longitude,
      },
    };
  }
  
  /// Get arrow states for rendering (includes current arrow and trail)
  Map<String, dynamic> getArrowRenderingData(ArrowState? currentArrow, List<ArrowState> trail) {
    final validTrail = trail.where((state) => 
      ArrowAnimationHelper.isValidForRendering(state) && state.isRecent
    ).toList();
    
    return {
      'currentArrow': currentArrow != null && ArrowAnimationHelper.isValidForRendering(currentArrow) ? currentArrow : null,
      'trail': validTrail,
      'trailCount': validTrail.length,
      'hasValidArrow': currentArrow?.isVisible == true,
    };
  }
  
  /// Generate debug information for troubleshooting arrow movement
  Map<String, dynamic> debugArrowConversion(PositionState position, LatLng startMapPosition, ArrowState? currentArrow) {
    final gridCoords = positionToGrid(position);
    final mapCoords = positionToLatLng(position, startMapPosition);
    final arrowState = calculateArrowState(position, startMapPosition);
    
    return {
      'originalPosition': {
        'x': position.x,
        'y': position.y,
        'angle': position.angle,
        'accuracy': position.accuracy,
      },
      'gridCoordinates': gridCoords,
      'mapCoordinates': {
        'latitude': mapCoords.latitude,
        'longitude': mapCoords.longitude,
        'withinBounds': isWithinMapBounds(mapCoords),
      },
      'arrowState': {
        'position': '${arrowState.position.latitude}, ${arrowState.position.longitude}',
        'rotation': arrowState.rotation,
        'isVisible': arrowState.isVisible,
        'confidence': arrowState.confidence,
        'scale': arrowState.scale,
        'speed': arrowState.speed,
      },
      'currentArrow': currentArrow != null ? {
        'position': '${currentArrow.position.latitude}, ${currentArrow.position.longitude}',
        'rotation': currentArrow.rotation,
        'isVisible': currentArrow.isVisible,
        'confidence': currentArrow.confidence,
        'scale': currentArrow.scale,
        'speed': currentArrow.speed,
      } : null,
      'startMapPosition': {
        'latitude': startMapPosition.latitude,
        'longitude': startMapPosition.longitude,
      },
      'gridInfo': getGridInfo(),
    };
  }
}