import 'dart:async';

import '../models/clipboard_history.dart';

/// Serializes native searches and folds updates received during a search into
/// one follow-up for the latest query. Obsolete results never reach consumers.
final class ClipboardHistoryLoader {
  ClipboardHistoryLoader({
    required this.load,
    required this.onSnapshot,
    required this.onError,
  });

  final Future<ClipboardHistorySnapshot> Function(String query) load;
  final void Function(ClipboardHistorySnapshot snapshot) onSnapshot;
  final void Function(Object error) onError;

  Completer<void>? _completion;
  String _query = '';
  int _generation = 0;
  bool _pending = false;
  bool _disposed = false;

  Future<void> refresh(String query) {
    if (_disposed) return Future<void>.value();
    _query = query;
    _generation++;
    _pending = true;
    if (_completion case final completion?) return completion.future;
    final completion = _completion = Completer<void>();
    unawaited(_drain(completion));
    return completion.future;
  }

  /// A new query or an unsolicited unfiltered snapshot supersedes pending work.
  void invalidate() {
    _generation++;
    _pending = false;
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }

  Future<void> _drain(Completer<void> completion) async {
    try {
      while (_pending && !_disposed) {
        _pending = false;
        final generation = _generation;
        ClipboardHistorySnapshot snapshot;
        try {
          snapshot = await load(_query);
        } on Object catch (error) {
          if (!_disposed && generation == _generation) onError(error);
          continue;
        }
        if (!_disposed && generation == _generation) onSnapshot(snapshot);
      }
      completion.complete();
    } on Object catch (error, stackTrace) {
      completion.completeError(error, stackTrace);
    } finally {
      _completion = null;
    }
  }
}
