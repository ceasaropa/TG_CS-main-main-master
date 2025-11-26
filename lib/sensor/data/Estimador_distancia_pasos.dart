import 'dart:math';

const Map<String, String> _baseDeReglas = <String, String>{
  'Bajo-Bajo': 'MuyBajo',
  'Bajo-Medio': 'Bajo',
  'Bajo-Alto': 'Medio',
  'Medio-Bajo': 'Bajo',
  'Medio-Medio': 'Medio',
  'Medio-Alto': 'Alto',
  'Alto-Bajo': 'Medio',
  'Alto-Medio': 'Alto',
  'Alto-Alto': 'Alto',
};

/// ===============================================================
/// CONTROLADOR DIFUSO DE K – USUARIO 7 (con factor de escala)
/// ===============================================================
class ControladorDifusoK {
  /// Factor de corrección de distancia.
  /// Para el usuario 7: 11 / 6.69 ≈ 1.64
  final double factorEscala;

  const ControladorDifusoK({this.factorEscala = 1.15});

  // ---------------------------------------------------------------
  // ETAPA 1: FUZIFICACIÓN
  // ---------------------------------------------------------------

  Map<String, double> _fuzificarDuracion(double duracion) {
    if (!duracion.isFinite || duracion < 0) {
      duracion = 0.0;
    }

    return {
      'Bajo': _triangular(duracion, 2.2, 4.9, 5.8),
      'Medio': _triangular(duracion, 4.9, 5.8, 7.2),
      'Alto': _triangular(duracion, 5.8, 7.2, 10.8),
    };
  }

  Map<String, double> _fuzificarLongitudPaso(double longitud) {
    if (!longitud.isFinite || longitud < 0) {
      longitud = 0.0;
    }

    return {
      'Bajo': _triangular(longitud, 52.0, 63.55, 78.1),
      'Medio': _triangular(longitud, 63.55, 78.1, 88.9),
      'Alto': _triangular(longitud, 78.1, 88.9, 148.0),
    };
  }

  // ---------------------------------------------------------------
  // ETAPA 2: BASE DE REGLAS (Duración x Longitud -> nivel de K)
  // ---------------------------------------------------------------
  //
  // Longitud Baja   Longitud Media   Longitud Alta
  // Duración Baja      MuyBajo          Bajo             Medio
  // Duración Media       Bajo          Medio             Alto
  // Duración Alta       Medio           Alto             Alto
  //

  // ---------------------------------------------------------------
  // ETAPA 3: DESDIFUSIFICACIÓN (salida crisp de K)
  // ---------------------------------------------------------------
  double _desdifusificar(Map<String, double> gradosActivacion) {
    const Map<String, double> valoresK = {
      'MuyBajo': 0.313,
      'Bajo': 0.366,
      'Medio': 0.430,
      'Alto': 0.481,
    };

    double numerador = 0.0;
    double denominador = 0.0;

    gradosActivacion.forEach((nivelK, grado) {
      if (grado.isFinite) {
        final k = valoresK[nivelK] ?? 0.0;
        numerador += k * grado;
        denominador += grado;
      }
    });

    if (denominador > 0 && numerador.isFinite) {
      final resultado = numerador / denominador;
      if (resultado.isFinite && resultado >= 0.1 && resultado <= 1.0) {
        return resultado;
      }
    }

    return 0.430;
  }

  // ---------------------------------------------------------------
  // MÉTODOS PÚBLICOS
  // ---------------------------------------------------------------

  double calcularK(double duracion, double longitudMagnitud) {
    if (!duracion.isFinite || !longitudMagnitud.isFinite) {
      return 0.430;
    }

    final gradosDuracion = _fuzificarDuracion(duracion);
    final gradosLongitud = _fuzificarLongitudPaso(longitudMagnitud);

    final Map<String, double> gradosActivacionK = {};

    gradosDuracion.forEach((nivelDur, gradoDur) {
      if (gradoDur.isFinite && gradoDur > 0) {
        gradosLongitud.forEach((nivelLon, gradoLon) {
          if (gradoLon.isFinite && gradoLon > 0) {
            final regla = _baseDeReglas['$nivelDur-$nivelLon'];
            if (regla != null) {
              final gradoActivacion = min(gradoDur, gradoLon);
              if (gradoActivacion.isFinite) {
                gradosActivacionK[regla] = max(
                  gradosActivacionK[regla] ?? 0.0,
                  gradoActivacion,
                );
              }
            }
          }
        });
      }
    });

    return _desdifusificar(gradosActivacionK);
  }

  double getFactorEscala() => factorEscala;

  double calcularLongitudPaso(double duracion, double magnitudPaso) {
    final k = calcularK(duracion, magnitudPaso);
    final raizCuarta = pow(magnitudPaso.abs(), 0.25);
    final longitudBase = k * raizCuarta;
    return longitudBase * factorEscala;
  }

  // ---------------------------------------------------------------
  // Función de pertenencia triangular genérica
  // ---------------------------------------------------------------
  double _triangular(double x, double a, double b, double c) {
    if (!x.isFinite || !a.isFinite || !b.isFinite || !c.isFinite) {
      return 0.0;
    }
    if (a > b || b > c || a == c) {
      return 0.0;
    }

    if (x <= a || x >= c) return 0.0;
    if (x == b) return 1.0;

    if (x > a && x < b) {
      final denom = b - a;
      if (denom == 0) return 0.0;
      final result = (x - a) / denom;
      return result.isFinite ? result : 0.0;
    }

    final denom = c - b;
    if (denom == 0) return 0.0;
    final result = (c - x) / denom;
    return result.isFinite ? result : 0.0;
  }
}
