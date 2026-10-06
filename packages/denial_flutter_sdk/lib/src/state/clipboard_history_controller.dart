import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/clipboard_history.dart';
import '../services/clipboard_history_service.dart';
import 'clipboard_history_loader.dart';
import 'notifier_lifecycle.dart';

final clipboardHistoryProvider =
    NotifierProvider<ClipboardHistoryController, ClipboardHistoryViewState>(
      ClipboardHistoryController.new,
    );

@immutable
class ClipboardHistoryViewState {
  const ClipboardHistoryViewState({
    this.snapshot,
    this.query = '',
    this.loading = true,
    this.clearing = false,
    this.error,
    this.busyItemIds = const <int>{},
  });

  final ClipboardHistorySnapshot? snapshot;
  final String query;
  final bool loading;
  final bool clearing;
  final Object? error;
  final Set<int> busyItemIds;

  List<ClipboardHistoryEntry> get entries =>
      snapshot?.entries ?? const <ClipboardHistoryEntry>[];

  ClipboardHistoryViewState copyWith({
    ClipboardHistorySnapshot? snapshot,
    bool clearSnapshot = false,
    String? query,
    bool? loading,
    bool? clearing,
    Object? error,
    bool clearError = false,
    Set<int>? busyItemIds,
  }) {
    return ClipboardHistoryViewState(
      snapshot: clearSnapshot ? null : snapshot ?? this.snapshot,
      query: query ?? this.query,
      loading: loading ?? this.loading,
      clearing: clearing ?? this.clearing,
      error: clearError ? null : error ?? this.error,
      busyItemIds: busyItemIds ?? this.busyItemIds,
    );
  }
}

class ClipboardHistoryController extends Notifier<ClipboardHistoryViewState>
    with NotifierLifecycle<ClipboardHistoryViewState> {
  static const Duration _searchDebounce = Duration(milliseconds: 140);

  Timer? _searchTimer;
  late ClipboardHistoryLoader _loader;
  int _generation = 0;

  @override
  ClipboardHistoryViewState build() {
    final service = ref.watch(clipboardHistoryServiceProvider);
    final generation = _generation = beginBuildGeneration();
    final loader = _loader = ClipboardHistoryLoader(
      load: (query) => service.snapshot(query: query),
      onSnapshot: (snapshot) {
        if (isBuildGenerationActive(generation)) _publish(snapshot);
      },
      onError: (error) {
        if (isBuildGenerationActive(generation)) _handleError(error);
      },
    );
    final subscription = service.snapshots.listen(
      (snapshot) {
        if (!isBuildGenerationActive(generation)) return;
        if (state.query.isEmpty) {
          _searchTimer?.cancel();
          loader.invalidate();
          _publish(snapshot);
        } else {
          unawaited(refresh());
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (isBuildGenerationActive(generation)) _handleError(error);
      },
    );
    cancelOnDispose(subscription);
    ref.onDispose(() {
      _searchTimer?.cancel();
      loader.dispose();
    });
    scheduleMicrotask(() {
      if (isBuildGenerationActive(generation)) unawaited(refresh());
    });
    return ClipboardHistoryViewState(snapshot: service.lastSnapshot);
  }

  void setQuery(String value) {
    final query = value.trimLeft();
    if (query == state.query) return;
    _loader.invalidate();
    state = state.copyWith(query: query, loading: true, clearError: true);
    _searchTimer?.cancel();
    _searchTimer = Timer(_searchDebounce, refresh);
  }

  Future<void> refresh() {
    _searchTimer?.cancel();
    if (!isBuildGenerationActive(_generation)) return Future<void>.value();
    if (!state.loading || state.error != null) {
      state = state.copyWith(loading: true, clearError: true);
    }
    return _loader.refresh(state.query);
  }

  Future<bool> activate(int itemId) =>
      _runItemAction(itemId, (service) => service.activate(itemId));

  Future<bool> setPinned(int itemId, {required bool pinned}) => _runItemAction(
    itemId,
    (service) => service.setPinned(itemId, pinned: pinned),
  );

  Future<bool> delete(int itemId) =>
      _runItemAction(itemId, (service) => service.delete(itemId));

  Future<bool> startDrag(int itemId) async {
    final generation = _generation;
    try {
      await ref.read(clipboardHistoryServiceProvider).startDrag(itemId);
      return true;
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(error: error);
      }
      return false;
    }
  }

  Future<bool> clear() async {
    if (state.clearing) return false;
    final generation = _generation;
    state = state.copyWith(clearing: true, clearError: true);
    try {
      await ref.read(clipboardHistoryServiceProvider).clear();
      if (isBuildGenerationActive(generation)) await refresh();
      return true;
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(error: error);
      }
      return false;
    } finally {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(clearing: false);
      }
    }
  }

  Future<void> setPaused({required bool paused}) async {
    final generation = _generation;
    try {
      await ref.read(clipboardHistoryServiceProvider).setPaused(paused: paused);
      if (isBuildGenerationActive(generation)) await refresh();
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(error: error);
      }
    }
  }

  Future<bool> _runItemAction(
    int itemId,
    Future<int> Function(ClipboardHistoryService service) action,
  ) async {
    if (state.busyItemIds.contains(itemId)) return false;
    final generation = _generation;
    state = state.copyWith(
      busyItemIds: UnmodifiableSetView({...state.busyItemIds, itemId}),
      clearError: true,
    );
    try {
      await action(ref.read(clipboardHistoryServiceProvider));
      if (isBuildGenerationActive(generation)) await refresh();
      return true;
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(error: error);
      }
      return false;
    } finally {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(
          busyItemIds: UnmodifiableSetView(
            {...state.busyItemIds}..remove(itemId),
          ),
        );
      }
    }
  }

  void _publish(ClipboardHistorySnapshot snapshot) {
    if (identical(state.snapshot, snapshot) &&
        !state.loading &&
        state.error == null) {
      return;
    }
    state = state.copyWith(
      snapshot: snapshot,
      loading: false,
      clearError: true,
    );
  }

  void _handleError(Object error) {
    state = state.copyWith(loading: false, error: error);
  }
}
