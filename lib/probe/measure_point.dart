/// A user measurement point, in sensor coordinates.
class MeasurePoint {
  MeasurePoint(this.id, this.x, this.y);

  final int id;
  int x;
  int y;
}

/// The user's measurement points, in sensor coordinates. Ids count up and
/// are never reused, so labels stay stable while points are removed.
class MeasurePoints {
  static const int max = 8;

  final List<MeasurePoint> points = <MeasurePoint>[];
  int _nextId = 1;

  /// Adds a point, or returns null when [max] points exist already.
  MeasurePoint? add(int x, int y) {
    if (points.length >= max) return null;
    final MeasurePoint p = MeasurePoint(_nextId++, x, y);
    points.add(p);
    return p;
  }

  void move(MeasurePoint p, int x, int y) {
    p
      ..x = x
      ..y = y;
  }

  void remove(MeasurePoint p) {
    points.remove(p);
  }
}
