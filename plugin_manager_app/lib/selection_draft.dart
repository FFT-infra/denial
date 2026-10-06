/// A window-local selection. Editing never invokes the backend or writes state.
/// Polling acknowledges a committed draft, but cannot overwrite unsaved edits.
final class SelectionDraft {
  Map<String, Object?> _base = {};
  Map<String, Object?> _roots = {};
  Map<String, Object?> _latest = {};
  Map<String, Object?> get roots => Map.unmodifiable(_roots);
  Map<String, Object?> get selection => {..._base, 'roots': roots};
  bool get dirty => !_sameRoots(_roots, _base['roots'] as Map? ?? {});
  bool get stale => dirty && _latest['revision'] != _base['revision'];

  void observe(Map<String, Object?> saved) {
    _latest = saved;
    if (!dirty || _sameRoots(_roots, saved['roots'] as Map? ?? {})) {
      discard();
    }
  }

  void enable(Map<String, Object?> plugin) {
    _roots[plugin['name']! as String] = plugin;
  }

  void disable(String name) => _roots.remove(name);

  void discard() {
    _base = Map.of(_latest);
    _roots = Map<String, Object?>.from(_base['roots'] as Map? ?? {});
  }

  static bool _sameRoots(Map a, Map b) =>
      a.length == b.length &&
      a.entries.every((entry) {
        if (!b.containsKey(entry.key)) return false;
        final first = (entry.value as Map)['source'] as Map;
        final second = (b[entry.key] as Map)['source'] as Map;
        return [
          'kind',
          'location',
          'path',
          'ref',
        ].every((key) => first[key] == second[key]);
      });
}
