import 'dart:math';

class POI {
  final Point<int> cell; //posicion del POI
  final String name; //nombre del POI
  final String description; //descripcion del POI
  final String iconKey; //icono del POI

  POI({
    required this.cell,
    required this.name,
    required this.description,
    this.iconKey = 'info',
  });

  factory POI.fromJson(Map<String, dynamic> json) {
    return POI(
      cell: Point(json['x'], json['y']),
      name: json['name'],
      description: json['description'],
      iconKey: json['iconKey'] ?? 'info',
    );
  }
}
