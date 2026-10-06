// Previous controller algorithm, retained for behavioral and timing comparisons.
List<int> legacyTransientFamilyOrder(
  int activatedId,
  Map<int, int> placements,
  Map<int, int> parents,
) {
  if (!placements.containsKey(activatedId)) return [];
  int rootOf(int id) {
    var current = id;
    final visited = <int>{};
    while (visited.add(current)) {
      final parent = parents[current];
      if (parent == null || !placements.containsKey(parent)) return current;
      current = parent;
    }
    return id;
  }

  int? depthBelow(int id, int ancestor) {
    var current = id;
    for (var depth = 0; depth <= parents.length; depth++) {
      if (current == ancestor) return depth;
      final parent = parents[current];
      if (parent == null || parent == current) return null;
      current = parent;
    }
    return null;
  }

  final root = rootOf(activatedId);
  final family = placements.keys
      .where((id) => depthBelow(id, root) != null)
      .toList(growable: false);
  return family.toList()..sort((left, right) {
    final a = depthBelow(left, activatedId) != null;
    final b = depthBelow(right, activatedId) != null;
    if (a != b) return a ? 1 : -1;
    final depth = depthBelow(left, root)!.compareTo(depthBelow(right, root)!);
    if (depth != 0) return depth;
    final z = placements[left]!.compareTo(placements[right]!);
    return z != 0 ? z : left.compareTo(right);
  });
}
