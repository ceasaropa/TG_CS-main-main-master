import 'package:proyecto_imu_v1_3/models/sensor_states.dart';
import 'package:latlong2/latlong.dart';

/// Helper class for arrow animation and state management
class ArrowAnimationHelper {
  /// Calculate arrow scale based on movement speed
  static double calculateScaleFromSpeed(double speed) {
    // Base scale
    const baseScale = 1.0;
    
    // Scale factor based on speed (0.5 m/s to 2.0 m/s range)
    final speedFactor = (speed / 2.0).clamp(0.5, 2.0);
    
    return baseScale * speedFactor;
  }
  
  /// Calculate smooth transition between arrow states
  static ArrowState calculateSmoothState(
    ArrowState currentState,
    ArrowState targetState,
    double lerpFactor,
    double currentSpeed,
  ) {
    // Linear interpolation between positions
    final latDiff = targetState.position.latitude - currentState.position.latitude;
    final lngDiff = targetState.position.longitude - currentState.position.longitude;
    
    final smoothedLat = currentState.position.latitude + (latDiff * lerpFactor);
    final smoothedLng = currentState.position.longitude + (lngDiff * lerpFactor);
    
    // Smooth rotation (handle 360-degree wraparound)
    final rotationDiff = targetState.rotationDifferenceTo(currentState.rotation);
    final smoothedRotation = currentState.rotation + (rotationDiff * lerpFactor);
    
    // Smooth scale
    final scaleDiff = targetState.scale - currentState.scale;
    final smoothedScale = currentState.scale + (scaleDiff * lerpFactor);
    
    return ArrowState(
      position: LatLng(smoothedLat, smoothedLng),
      rotation: smoothedRotation,
      isVisible: targetState.isVisible,
      confidence: targetState.confidence,
      scale: smoothedScale,
      positionState: targetState.positionState,
      timestamp: targetState.timestamp,
      speed: currentSpeed,
      isTrailPoint: targetState.isTrailPoint,
    );
  }
  
  /// Manage arrow trail points with maximum limit
  static List<ArrowState> manageArrowTrail(
    List<ArrowState> currentTrail,
    ArrowState newPoint, {
    int maxPoints = 50,
  }) {
    final updatedTrail = List<ArrowState>.from(currentTrail);
    
    // Add new point to trail
    updatedTrail.add(newPoint);
    
    // Remove oldest points if we exceed the limit
    while (updatedTrail.length > maxPoints) {
      updatedTrail.removeAt(0);
    }
    
    return updatedTrail;
  }
  
  /// Check if arrow state is valid for rendering
  static bool isValidForRendering(ArrowState state) {
    return state.isVisible && 
           state.position.latitude.isFinite && 
           state.position.longitude.isFinite &&
           state.confidence > 0.1;
  }
}