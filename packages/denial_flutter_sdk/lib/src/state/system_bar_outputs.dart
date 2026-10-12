/// Resolves a visible panel's output selection even when the previous scene
/// reserved no output (for example, when returning from mobile presentation).
List<int> resolveSystemBarMonitorIds({
  required Iterable<({int monitorId, String name})> outputs,
  required Iterable<String> outputNames,
  required Iterable<int> currentMonitorIds,
  required int? mainMonitorId,
}) {
  final available = outputs.toList(growable: false);
  final names = outputNames.toSet();
  final current = currentMonitorIds.toSet();
  final availableIds = available.map((output) => output.monitorId).toSet();
  final selected = names.isEmpty
      ? current.where(availableIds.contains).toList(growable: false)
      : available
            .where((output) => names.contains(output.name))
            .map((output) => output.monitorId)
            .toList(growable: false);
  if (selected.isNotEmpty) return selected;
  if (available.isEmpty) return const [];
  return [
    available.any((output) => output.monitorId == mainMonitorId)
        ? mainMonitorId!
        : available.first.monitorId,
  ];
}
