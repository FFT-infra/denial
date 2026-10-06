import 'dart:async';

import 'package:denial_flutter_sdk/launcher.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

part 'launcher_components.dart';

const desktopApplicationSuggestionsRowKey = ValueKey<String>(
  'desktop-application-suggestions-row',
);
const desktopApplicationSuggestionsDividerKey = ValueKey<String>(
  'desktop-application-suggestions-divider',
);

@immutable
class _DesktopLauncherTarget {
  const _DesktopLauncherTarget({
    required this.entry,
    required this.selectionId,
    required this.row,
    required this.column,
    required this.scrollTop,
    required this.scrollExtent,
  });

  final LauncherApplication entry;
  final String selectionId;
  final int row;
  final int column;
  final double scrollTop;
  final double scrollExtent;
}

String _catalogLauncherTargetId(String entryId) => 'catalog:$entryId';

String _suggestedLauncherTargetId(String entryId) => 'suggested:$entryId';

class DesktopApplicationLauncher extends StatefulWidget {
  const DesktopApplicationLauncher({super.key, required this.launcher});
  final LauncherContext launcher;

  @override
  State<DesktopApplicationLauncher> createState() =>
      _DesktopApplicationLauncherState();
}

class _DesktopApplicationLauncherState
    extends State<DesktopApplicationLauncher> {
  static const double _tileExtent = 112;
  static const double _suggestedTileExtent = 96;
  static const double _tileSpacing = 8;

  late final TextEditingController _searchController;
  final ScrollController _gridController = ScrollController();
  String _lastSearchText = '';
  String? _selectedTargetId;
  List<LauncherApplication>? _cachedInstalledApps;
  List<LauncherApplication>? _cachedSource;
  List<LauncherApplication>? _cachedFilteredSource;
  String? _cachedNormalizedQuery;
  List<LauncherApplication>? _cachedFilteredApps;
  List<_DesktopLauncherTarget> _visibleTargets =
      const <_DesktopLauncherTarget>[];
  final Map<String, GlobalKey<_DesktopAppTileState>> _tileKeys =
      <String, GlobalKey<_DesktopAppTileState>>{};

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController()
      ..addListener(_handleQueryChanged);
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_handleQueryChanged)
      ..dispose();
    _gridController.dispose();
    super.dispose();
  }

  void _handleQueryChanged() {
    final searchText = _searchController.text;
    if (searchText == _lastSearchText) {
      return;
    }
    _lastSearchText = searchText;
    setState(() => _selectedTargetId = null);
    _resetGridScroll();
  }

  @override
  void didUpdateWidget(covariant DesktopApplicationLauncher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.launcher.visible && widget.launcher.visible) {
      _handleVisibilityChanged();
    }
  }

  void _handleVisibilityChanged() {
    // Preserve the exact launcher presentation while it fades out. Resetting
    // the query here on close would replace filtered results with the complete
    // catalog while the panel is still visible. The next open notification is
    // delivered before its first rendered frame, so prepare the clean launcher
    // then instead.
    final targets = _visibleTargets;
    final previousIndex = _selectedIndexFor(targets);
    final previousSelection = previousIndex < 0
        ? null
        : targets[previousIndex].selectionId;
    _selectedTargetId = null;
    if (previousSelection != null &&
        targets.isNotEmpty &&
        previousSelection != targets.first.selectionId) {
      _setTileSelected(previousSelection, false);
      _setTileSelected(targets.first.selectionId, true);
    }
    _resetGridScroll();
    if (_searchController.text.isNotEmpty) {
      _searchController.clear();
    }
  }

  void _clearSearch() {
    _searchController.clear();
    widget.launcher.searchFocusNode.requestFocus();
  }

  void _launch(LauncherApplication entry) => widget.launcher.onLaunch(entry.id);

  int _selectedIndexFor(List<_DesktopLauncherTarget> targets) {
    if (targets.isEmpty) {
      return -1;
    }
    final selectedTargetId = _selectedTargetId;
    if (selectedTargetId == null) {
      return 0;
    }
    final index = targets.indexWhere(
      (target) => target.selectionId == selectedTargetId,
    );
    return index < 0 ? 0 : index;
  }

  void _selectIndex(List<_DesktopLauncherTarget> targets, int index) {
    if (targets.isEmpty) {
      return;
    }
    assert(index >= 0 && index < targets.length);
    final previousIndex = _selectedIndexFor(targets);
    final previousTargetId = previousIndex < 0
        ? null
        : targets[previousIndex].selectionId;
    final selectedTarget = targets[index];
    if (_selectedTargetId != selectedTarget.selectionId) {
      _selectedTargetId = selectedTarget.selectionId;
      if (previousTargetId != null) {
        _setTileSelected(previousTargetId, false);
      }
      _setTileSelected(selectedTarget.selectionId, true);
    }
    _revealSelected(selectedTarget);
  }

  void _setTileSelected(String targetId, bool selected) {
    _tileKeys[targetId]?.currentState?.setSelected(selected);
  }

  GlobalKey<_DesktopAppTileState> _tileKey(String targetId) {
    return _tileKeys.putIfAbsent(
      targetId,
      () => GlobalKey<_DesktopAppTileState>(
        debugLabel: 'desktop-app-tile-$targetId',
      ),
    );
  }

  void _moveSelection(List<_DesktopLauncherTarget> targets, int delta) {
    if (targets.isEmpty) {
      return;
    }
    final current = _selectedIndexFor(targets);
    _selectIndex(targets, (current + delta) % targets.length);
  }

  void _moveSelectionVertically(
    List<_DesktopLauncherTarget> targets,
    int direction,
  ) {
    if (targets.isEmpty) {
      return;
    }
    assert(direction == -1 || direction == 1);
    final current = targets[_selectedIndexFor(targets)];
    final rowCount = targets.last.row + 1;
    final targetRow = (current.row + direction) % rowCount;
    final rowTargets = targets
        .where((target) => target.row == targetRow)
        .toList(growable: false);
    final targetColumn = current.column.clamp(0, rowTargets.length - 1).toInt();
    _selectIndex(targets, targets.indexOf(rowTargets[targetColumn]));
  }

  void _launchSelected(List<_DesktopLauncherTarget> targets) {
    final selectedIndex = _selectedIndexFor(targets);
    if (selectedIndex >= 0) {
      _launch(targets[selectedIndex].entry);
    }
  }

  void _resetGridScroll() {
    if (!_gridController.hasClients) {
      return;
    }
    final position = _gridController.position;
    if (position.pixels != position.minScrollExtent) {
      _gridController.jumpTo(position.minScrollExtent);
    }
  }

  List<LauncherApplication> _resolveInstalledApps() {
    final source = widget.launcher.applications;
    final cached = _cachedInstalledApps;
    if (identical(source, _cachedSource) && cached != null) return cached;
    _cachedSource = source;
    final apps = source.toList(growable: false)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final activeIds = <String>{for (final app in apps) app.id};
    final activeTargetIds = <String>{
      for (final id in activeIds) _catalogLauncherTargetId(id),
      for (final id in activeIds) _suggestedLauncherTargetId(id),
    };
    _tileKeys.removeWhere((id, _) => !activeTargetIds.contains(id));
    if (!activeTargetIds.contains(_selectedTargetId)) {
      _selectedTargetId = null;
    }
    _cachedInstalledApps = apps;
    _cachedFilteredSource = null;
    _cachedNormalizedQuery = null;
    _cachedFilteredApps = null;
    return apps;
  }

  List<LauncherApplication> _resolveSuggestedApps(
    List<LauncherApplication> apps,
    List<String> recentEntryIds,
    int maximumCount,
  ) {
    if (apps.isEmpty || recentEntryIds.isEmpty || maximumCount <= 0) {
      return const <LauncherApplication>[];
    }

    final appsById = <String, LauncherApplication>{
      for (final app in apps) app.id: app,
    };
    final suggested = <LauncherApplication>[];
    for (final entryId in recentEntryIds) {
      final app = appsById[entryId];
      if (app == null) {
        continue;
      }
      suggested.add(app);
      if (suggested.length == maximumCount) {
        break;
      }
    }
    return suggested;
  }

  List<_DesktopLauncherTarget> _resolveNavigationTargets(
    List<LauncherApplication> suggestedApps,
    List<LauncherApplication> catalogApps,
    int columnCount,
  ) {
    final catalogRowOffset = suggestedApps.isEmpty ? 0 : 1;
    final catalogScrollOffset = suggestedApps.isEmpty
        ? 0.0
        : _suggestedTileExtent + _tileSpacing * 2 + 1;
    return <_DesktopLauncherTarget>[
      for (var index = 0; index < suggestedApps.length; index += 1)
        _DesktopLauncherTarget(
          entry: suggestedApps[index],
          selectionId: _suggestedLauncherTargetId(suggestedApps[index].id),
          row: 0,
          column: index,
          scrollTop: 0,
          scrollExtent: _suggestedTileExtent,
        ),
      for (var index = 0; index < catalogApps.length; index += 1)
        _DesktopLauncherTarget(
          entry: catalogApps[index],
          selectionId: _catalogLauncherTargetId(catalogApps[index].id),
          row: catalogRowOffset + (index ~/ columnCount),
          column: index % columnCount,
          scrollTop:
              catalogScrollOffset +
              (index ~/ columnCount) * (_tileExtent + _tileSpacing),
          scrollExtent: _tileExtent,
        ),
    ];
  }

  List<LauncherApplication> _resolveFilteredApps(
    List<LauncherApplication> apps,
    String query,
  ) {
    final normalizedQuery = query.trim().toLowerCase();
    final cached = _cachedFilteredApps;
    if (cached != null &&
        identical(apps, _cachedFilteredSource) &&
        normalizedQuery == _cachedNormalizedQuery) {
      return cached;
    }
    final filtered = _filterInstalledApps(apps, normalizedQuery);
    _cachedFilteredSource = apps;
    _cachedNormalizedQuery = normalizedQuery;
    _cachedFilteredApps = filtered;
    return filtered;
  }

  void _revealSelected(_DesktopLauncherTarget target) {
    if (!_gridController.hasClients) {
      return;
    }
    final position = _gridController.position;
    final itemTop = target.scrollTop;
    final itemBottom = itemTop + target.scrollExtent;
    final viewport = position.viewportDimension;
    final current = position.pixels;
    final double scrollTarget;
    if (itemBottom > current + viewport) {
      scrollTarget = itemBottom - viewport + _tileSpacing;
    } else if (itemTop < current) {
      scrollTarget = itemTop - _tileSpacing;
    } else {
      return;
    }
    final clampedTarget = scrollTarget
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if (MediaQuery.disableAnimationsOf(context)) {
      _gridController.jumpTo(clampedTarget);
      return;
    }
    unawaited(
      _gridController.animateTo(
        clampedTarget,
        duration: Motion.tile,
        curve: Motion.standard,
      ),
    );
  }

  int _crossAxisCountFor(double width) {
    final count = (width / (_tileExtent + _tileSpacing)).ceil();
    return count < 1 ? 1 : count;
  }

  @override
  Widget build(BuildContext context) {
    return _LauncherScope(
      launcher: widget.launcher,
      child: _buildLauncher(context),
    );
  }

  Widget _buildLauncher(BuildContext context) {
    final recentEntryIds = widget.launcher.recentApplicationIds;
    final allApps = _resolveInstalledApps();
    final apps = _resolveFilteredApps(allApps, _searchController.text);
    final theme = ShellTheme.of(context);
    return MouseRegion(
      onEnter: (_) => widget.launcher.onEnter(),
      onExit: (_) => widget.launcher.onExit(),
      child: FocusTraversalGroup(
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape):
                widget.launcher.onDismiss,
            const SingleActivator(LogicalKeyboardKey.tab): () =>
                _moveSelection(_visibleTargets, 1),
            const SingleActivator(LogicalKeyboardKey.tab, shift: true): () =>
                _moveSelection(_visibleTargets, -1),
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                _moveSelectionVertically(_visibleTargets, 1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                _moveSelectionVertically(_visibleTargets, -1),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _moveSelection(_visibleTargets, 1),
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _moveSelection(_visibleTargets, -1),
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.panelColor(context.shellColors.panelBackground),
              borderRadius: BorderRadius.circular(theme.panelRadius),
              border: Border.all(color: context.shellColors.hairline),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DesktopAppSearchField(
                    controller: _searchController,
                    focusNode: widget.launcher.searchFocusNode,
                    onClear: _clearSearch,
                    onSubmit: () => _launchSelected(_visibleTargets),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final columnCount = _crossAxisCountFor(
                          constraints.maxWidth,
                        );
                        final suggestedApps = _resolveSuggestedApps(
                          apps,
                          recentEntryIds,
                          columnCount,
                        );
                        final navigationTargets = _resolveNavigationTargets(
                          suggestedApps,
                          apps,
                          columnCount,
                        );
                        _visibleTargets = navigationTargets;
                        return CustomScrollView(
                          controller: _gridController,
                          scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                          slivers: <Widget>[
                            if (suggestedApps.isNotEmpty) ...<Widget>[
                              SliverToBoxAdapter(
                                child: _DesktopApplicationSuggestionsRow(
                                  apps: suggestedApps,
                                  selectedTargetId: _selectedTargetId,
                                  tileKeyFor: _tileKey,
                                  onLaunch: _launch,
                                ),
                              ),
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: _tileSpacing,
                                  ),
                                  child: Divider(
                                    key:
                                        desktopApplicationSuggestionsDividerKey,
                                    height: 1,
                                    thickness: 1,
                                    color: context.shellColors.hairlineSoft
                                        .withValues(alpha: 0.55),
                                  ),
                                ),
                              ),
                            ],
                            if (allApps.isEmpty)
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: Center(
                                  child: Text(
                                    widget.launcher.strings.loadingApplications,
                                  ),
                                ),
                              )
                            else if (apps.isEmpty)
                              const SliverFillRemaining(
                                hasScrollBody: false,
                                child: _DesktopAppSearchEmptyState(),
                              )
                            else
                              SliverGrid(
                                gridDelegate:
                                    const SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent: _tileExtent,
                                      mainAxisExtent: _tileExtent,
                                      crossAxisSpacing: _tileSpacing,
                                      mainAxisSpacing: _tileSpacing,
                                    ),
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  index,
                                ) {
                                  final app = apps[index];
                                  final targetId = _catalogLauncherTargetId(
                                    app.id,
                                  );
                                  return KeyedSubtree(
                                    key: ValueKey<String>(
                                      'desktop-app-${app.id}',
                                    ),
                                    child: _DesktopAppTile(
                                      key: _tileKey(targetId),
                                      app: app,
                                      selected: _selectedTargetId == null
                                          ? suggestedApps.isEmpty && index == 0
                                          : targetId == _selectedTargetId,
                                      onTap: () => _launch(app),
                                    ),
                                  );
                                }, childCount: apps.length),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LauncherScope extends InheritedWidget {
  const _LauncherScope({required this.launcher, required super.child});
  final LauncherContext launcher;
  static LauncherContext of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LauncherScope>()!.launcher;
  @override
  bool updateShouldNotify(_LauncherScope oldWidget) =>
      !identical(launcher, oldWidget.launcher);
}
