import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_compass/flutter_compass.dart'; // <-- 1. IMPORTADO
import 'package:proyecto_imu_v1_3/sensor/data/sensor_processor.dart';

class SensorManager {
  // Datos del sensor
  final DataProcessor dataProcessor;
  double accX = 0.0, accY = 0.0, accZ = 0.0;
  double accMagnitude = 0.0;
  double gyroX = 0.0, gyroY = 0.0, gyroZ = 0.0;
  double gyroMagnitude = 0.0;
  double? heading = 0.0; // <-- 2. NUEVA VARIABLE PARA LA BRÚJULA

  // 🚀 NUEVO: Datos filtrados con Kalman
  double kalmanAccX = 0.0, kalmanAccY = 0.0, kalmanAccZ = 0.0;
  double kalmanGyroX = 0.0, kalmanGyroY = 0.0, kalmanGyroZ = 0.0;
  double kalmanAccMagnitude = 0.0;
  double kalmanGyroMagnitude = 0.0;
  double frequency = 0;
  bool isRunning = false;
  int sampleCount = 0;

  final Duration sensorInterval = const Duration(
    microseconds: 8333,
  ); // 125 Hz (1/8000 seconds = 125 Hz)
  StreamSubscription<AccelerometerEvent>? _accSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;
  StreamSubscription<CompassEvent>?
  _compassSubscription; // <-- 3. NUEVA SUSCRIPCIÓN
  late Timer _timer;

  // 👉 Callback para notificar a la UI
  final VoidCallback onUpdate;

  SensorManager({required this.onUpdate, required this.dataProcessor}) {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (isRunning) {
        frequency = sampleCount.toDouble();
        sampleCount = 0;
        onUpdate(); // 👉 Llama a setState()
      }
    });
  }

  void startSensors() {
    // Iniciar la brújula
    _compassSubscription = FlutterCompass.events!.listen((event) {
      // <-- 4. INICIAR ESCUCHA DE LA BRÚJULA
      double? newHeading = event.heading;

      if (newHeading != null) {
        // Normaliza el valor entre 0° a 360°
        heading = (newHeading + 360) % 360;
      }
      onUpdate(); // Notificar a la UI
    });

    _gyroSubscription = gyroscopeEventStream(
      samplingPeriod: sensorInterval,
    ).listen((event) {
      gyroX = event.x;
      gyroY = event.y;
      gyroZ = event.z;
      gyroMagnitude = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      onUpdate();
    });
    _accSubscription = accelerometerEventStream(
      samplingPeriod: sensorInterval,
    ).listen((event) {
      accX = event.x;
      accY = event.y;
      accZ = event.z;
      accMagnitude =
          sqrt(event.x * event.x + event.y * event.y + event.z * event.z) - 9.8;

      // 🚀 NUEVO: Usar el método mejorado con datos completos
      dataProcessor.addSensorData(
        accMagnitude,
        gyroMagnitude,
        heading ?? 0.0, // Validación adicional para evitar null
      ); // Asegurarse de pasar el heading

      sampleCount++;
      onUpdate();
    });
  }

  void stopSensors() {
    _accSubscription?.cancel();
    _gyroSubscription?.cancel();
    _compassSubscription?.cancel(); // <-- 5. CANCELAR SUSCRIPCIÓN DE LA BRÚJULA
    _accSubscription = null;
    _gyroSubscription = null;
    _compassSubscription = null; // <-- 5. LIMPIAR SUSCRIPCIÓN
  }

  void toggleSensors() {
    if (isRunning) {
      stopSensors();
    } else {
      // Limpiar todas las variables para una nueva lectura
      dataProcessor.accMagnitudeListDesfasada.clear();
      dataProcessor.historialFiltrado.clear();
      dataProcessor.indiceInicio = 0;
      dataProcessor.unionCrucesPicosVallesListFiltradoTotal.clear();
      dataProcessor.matrizordenada.clear();
      dataProcessor.matrizSecuenciasrevisar.clear();
      dataProcessor.unionFiltradorecortadoTotal.clear();
      dataProcessor.unionFiltradorecortadoTotal2.clear();
      dataProcessor.pasosPorVentana.clear();
      dataProcessor.tiempoDePasosList.clear();
      dataProcessor.longitudDePasosList.clear();
      dataProcessor.matrizsignalfiltertotal.clear();
      dataProcessor.tiemposRestados.clear();
      dataProcessor.primeraFilaMatrizOrdenada.clear();

      // Limpiar el historial completo de lecturas
      dataProcessor.readings.clear();
      dataProcessor.accMagnitudeListFiltered.clear();
      dataProcessor.accMagnitudeListFiltered2ndOrder.clear();
      dataProcessor.accMagnitudeListFiltered4thOrder.clear();

      // Limpiar matrices de datos recientes y pasos (reasignar con 4 filas para incluir heading)
      dataProcessor.matrizDatosRecientes = List.generate(
        4,
        (_) => List.filled(4, 0.0),
      );
      dataProcessor.matrizPasos = List.generate(3, (i) => List.filled(20, 0.0));

      dataProcessor.matrizordenadatotal = [[], [], [], [], []];
      dataProcessor.gyroMagnitudeListDesfasada.clear();
      dataProcessor.ventanaGyroXYZFiltradaList.clear();

      // Resetear todos los datos de azimuth/heading usando el método correcto
      dataProcessor.conteoPasos.resetAzimuthData();

      // Actualizar la UI inmediatamente después de limpiar
      onUpdate();

      startSensors();
    }
    isRunning = !isRunning;
    onUpdate();
  }

  void dispose() {
    _timer.cancel();
    stopSensors();
  }
}
