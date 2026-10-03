import 'dart:math' as math;

import 'package:denial_flutter_sdk/settings.dart';
import 'package:flutter/widgets.dart';

/// One window considered by the managed-layout workspace overview.
class DesktopWorkspaceOverviewItem {
  const DesktopWorkspaceOverviewItem({
    required this.objectId,
    required this.frame,
    required this.z,
    required this.workspaceId,
    required this.minimized,
  });

  final int objectId;
  final Rect frame;
  final int z;
  final int workspaceId;
  final bool minimized;

  double get aspectRatio {
    if (frame.width <= 0.0 || frame.height <= 0.0) {
      return 16.0 / 10.0;
    }
    return (frame.width / frame.height).clamp(0.4, 3.0).toDouble();
  }
}

/// The miniature of one monitor-local workspace.
///
/// Every card shares the overview's scale, so a window keeps the same
/// relative size on every workspace. [project] and [unproject] form the camera
/// used by the zoom transition: unprojecting with the active card maps that
/// workspace back onto the screen and every other card beside it.
@immutable
class DesktopWorkspaceOverviewCard {
  const DesktopWorkspaceOverviewCard({
    required this.workspaceId,
    required this.rect,
    required this.contentRect,
    required this.sourceRect,
    required this.viewportRect,
  });

  final int workspaceId;

  /// Card bounds in scene coordinates.
  final Rect rect;

  /// Where [sourceRect] is drawn inside [rect].
  final Rect contentRect;

  /// The real scene area represented by this card: the output work area plus
  /// every window extending beyond it, such as off-screen scrolling columns.
  final Rect sourceRect;

  /// The output work area as drawn inside this card.
  final Rect viewportRect;

  double get scale =>
      sourceRect.width > 0.0 ? contentRect.width / sourceRect.width : 1.0;

  /// Whether some of this workspace lies outside the visible work area.
  bool get extendsBeyondViewport =>
      contentRect.width - viewportRect.width > 0.5 ||
      contentRect.height - viewportRect.height > 0.5;

  /// Maps a real scene rectangle into this card.
  Rect project(Rect real) {
    final scale = this.scale;
    return Rect.fromLTWH(
      contentRect.left + (real.left - sourceRect.left) * scale,
      contentRect.top + (real.top - sourceRect.top) * scale,
      real.width * scale,
      real.height * scale,
    );
  }

  /// Maps an overview rectangle back to scene space as if this card filled
  /// the screen again.
  Rect unproject(Rect overview) {
    final scale = this.scale;
    if (scale <= 0.0) {
      return overview;
    }
    return Rect.fromLTWH(
      sourceRect.left + (overview.left - contentRect.left) / scale,
      sourceRect.top + (overview.top - contentRect.top) / scale,
      overview.width / scale,
      overview.height / scale,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DesktopWorkspaceOverviewCard &&
        other.workspaceId == workspaceId &&
        other.rect == rect &&
        other.contentRect == contentRect &&
        other.sourceRect == sourceRect &&
        other.viewportRect == viewportRect;
  }

  @override
  int get hashCode =>
      Object.hash(workspaceId, rect, contentRect, sourceRect, viewportRect);
}

@immutable
class DesktopWorkspaceOverviewArrangement {
  const DesktopWorkspaceOverviewArrangement({
    required this.cards,
    required this.shelf,
    required this.frames,
    this.landing,
  });

  static const empty = DesktopWorkspaceOverviewArrangement(
    cards: <DesktopWorkspaceOverviewCard>[],
    shelf: Rect.zero,
    frames: <int, Rect>{},
  );

  final List<DesktopWorkspaceOverviewCard> cards;

  /// Background of the minimized-window shelf, or [Rect.zero] when empty.
  final Rect shelf;
  final Map<int, Rect> frames;

  /// The planned landing rectangle projected into its card, if any.
  final Rect? landing;
}

/// Lays out every workspace of one monitor as a true-to-layout miniature.
///
/// Managed layouts carry meaning in their geometry, so this overview never
/// re-packs windows. Each card is a uniformly scaled copy of its workspace,
/// including scrolling columns outside the visible viewport. Cards fill the
/// largest grid that keeps one common scale; the configured switching
/// orientation chooses whether workspaces read across rows or down columns.
/// Minimized windows belong to no workspace and sit on a shelf below.
abstract final class DesktopWorkspaceOverviewLayout {
  static const double maximumScale = 0.55;
  static const double cardInset = 8.0;
  static const double labelExtent = 28.0;
  static const double shelfPadding = 10.0;
  static const double shelfGap = 12.0;

  static DesktopWorkspaceOverviewArrangement arrange({
    required Rect bounds,
    required Rect viewport,
    required int workspaceCount,
    required WorkspaceSwitchingOrientation orientation,
    required List<DesktopWorkspaceOverviewItem> items,
    ({int workspaceId, Rect frame})? landing,
  }) {
    if (bounds.isEmpty || viewport.isEmpty) {
      return DesktopWorkspaceOverviewArrangement.empty;
    }
    final count = math.max(1, workspaceCount);
    final padding = (math.min(bounds.width, bounds.height) * 0.035)
        .clamp(16.0, 44.0)
        .toDouble();
    var area = bounds.deflate(padding);
    if (area.isEmpty) {
      return DesktopWorkspaceOverviewArrangement.empty;
    }
    final gap = (math.min(area.width, area.height) * 0.035)
        .clamp(16.0, 40.0)
        .toDouble();
    final frames = <int, Rect>{};

    final minimized =
        items.where((item) => item.minimized).toList(growable: false)
          ..sort((left, right) {
            final order = right.z.compareTo(left.z);
            return order != 0 ? order : left.objectId.compareTo(right.objectId);
          });
    var shelf = Rect.zero;
    if (minimized.isNotEmpty) {
      final shelfHeight = (area.height * 0.16).clamp(72.0, 168.0).toDouble();
      final shelfBounds = Rect.fromLTRB(
        area.left,
        area.bottom - shelfHeight,
        area.right,
        area.bottom,
      );
      shelf = _arrangeShelf(minimized, shelfBounds, frames);
      area = Rect.fromLTRB(
        area.left,
        area.top,
        area.right,
        math.max(area.top, shelfBounds.top - gap),
      );
    }

    final sources = <int, Rect>{
      for (var workspace = 1; workspace <= count; workspace += 1)
        workspace: viewport,
    };
    for (final item in items) {
      if (item.minimized) {
        continue;
      }
      final source = sources[item.workspaceId];
      if (source != null) {
        sources[item.workspaceId] = source.expandToInclude(item.frame);
      }
    }
    // A planned drop is part of its target workspace already, so that card
    // makes room for it; the dragged window keeps its own place meanwhile.
    if (landing != null) {
      final source = sources[landing.workspaceId];
      if (source != null) {
        sources[landing.workspaceId] = source.expandToInclude(landing.frame);
      }
    }
    final sourceWidth = sources.values
        .map((rect) => rect.width)
        .reduce(math.max);
    final sourceHeight = sources.values
        .map((rect) => rect.height)
        .reduce(math.max);
    final label = count > 1 ? labelExtent : 0.0;
    final grid = _bestGrid(
      count: count,
      area: area,
      gap: gap,
      label: label,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      orientation: orientation,
    );
    if (grid == null) {
      return DesktopWorkspaceOverviewArrangement(
        cards: const <DesktopWorkspaceOverviewCard>[],
        shelf: shelf,
        frames: frames,
      );
    }

    final scale = grid.scale;
    final cardWidth = sourceWidth * scale + cardInset * 2.0;
    final cardHeight = sourceHeight * scale + cardInset * 2.0;
    final cellHeight = cardHeight + label;
    final gridWidth = grid.columns * cardWidth + gap * (grid.columns - 1);
    final gridHeight = grid.rows * cellHeight + gap * (grid.rows - 1);
    final origin = area.center - Offset(gridWidth / 2.0, gridHeight / 2.0);
    final acrossRows = orientation == WorkspaceSwitchingOrientation.horizontal;
    final cards = <DesktopWorkspaceOverviewCard>[];
    for (var index = 0; index < count; index += 1) {
      final double left;
      final double top;
      if (acrossRows) {
        final row = index ~/ grid.columns;
        final column = index % grid.columns;
        final itemsInRow = math.min(grid.columns, count - row * grid.columns);
        final centering = (grid.columns - itemsInRow) * (cardWidth + gap) / 2;
        left = origin.dx + centering + column * (cardWidth + gap);
        top = origin.dy + row * (cellHeight + gap) + label;
      } else {
        final column = index ~/ grid.rows;
        final row = index % grid.rows;
        final itemsInColumn = math.min(grid.rows, count - column * grid.rows);
        final centering = (grid.rows - itemsInColumn) * (cellHeight + gap) / 2;
        left = origin.dx + column * (cardWidth + gap);
        top = origin.dy + centering + row * (cellHeight + gap) + label;
      }
      final workspaceId = index + 1;
      final rect = Rect.fromLTWH(left, top, cardWidth, cardHeight);
      final source = sources[workspaceId]!;
      final contentRect = Rect.fromCenter(
        center: rect.center,
        width: source.width * scale,
        height: source.height * scale,
      );
      cards.add(
        DesktopWorkspaceOverviewCard(
          workspaceId: workspaceId,
          rect: rect,
          contentRect: contentRect,
          sourceRect: source,
          viewportRect: Rect.fromLTWH(
            contentRect.left + (viewport.left - source.left) * scale,
            contentRect.top + (viewport.top - source.top) * scale,
            viewport.width * scale,
            viewport.height * scale,
          ),
        ),
      );
    }

    final cardsByWorkspace = <int, DesktopWorkspaceOverviewCard>{
      for (final card in cards) card.workspaceId: card,
    };
    for (final item in items) {
      if (item.minimized) {
        continue;
      }
      final card = cardsByWorkspace[item.workspaceId];
      if (card != null) {
        frames[item.objectId] = card.project(item.frame);
      }
    }
    return DesktopWorkspaceOverviewArrangement(
      cards: List<DesktopWorkspaceOverviewCard>.unmodifiable(cards),
      shelf: shelf,
      frames: frames,
      landing: landing == null
          ? null
          : cardsByWorkspace[landing.workspaceId]?.project(landing.frame),
    );
  }

  static Rect _arrangeShelf(
    List<DesktopWorkspaceOverviewItem> items,
    Rect bounds,
    Map<int, Rect> frames,
  ) {
    final aspectSum = items.fold<double>(
      0.0,
      (sum, item) => sum + item.aspectRatio,
    );
    final gaps = shelfGap * (items.length - 1);
    final availableWidth = bounds.width - shelfPadding * 2.0 - gaps;
    var height = bounds.height - shelfPadding * 2.0;
    if (aspectSum * height > availableWidth) {
      height = math.max(16.0, availableWidth / aspectSum);
    }
    if (height <= 0.0) {
      return Rect.zero;
    }
    final rowWidth = aspectSum * height + gaps;
    final shelfHeight = height + shelfPadding * 2.0;
    final shelf = Rect.fromLTWH(
      bounds.center.dx - (rowWidth + shelfPadding * 2.0) / 2.0,
      bounds.bottom - shelfHeight,
      rowWidth + shelfPadding * 2.0,
      shelfHeight,
    );
    var left = shelf.left + shelfPadding;
    for (final item in items) {
      final width = item.aspectRatio * height;
      frames[item.objectId] = Rect.fromLTWH(
        left,
        shelf.top + shelfPadding,
        width,
        height,
      );
      left += width + shelfGap;
    }
    return shelf;
  }

  static ({int columns, int rows, double scale})? _bestGrid({
    required int count,
    required Rect area,
    required double gap,
    required double label,
    required double sourceWidth,
    required double sourceHeight,
    required WorkspaceSwitchingOrientation orientation,
  }) {
    if (sourceWidth <= 0.0 || sourceHeight <= 0.0) {
      return null;
    }
    final acrossRows = orientation == WorkspaceSwitchingOrientation.horizontal;
    ({int columns, int rows, double scale})? best;
    var bestEmptySlots = count;
    // Search from the orientation's longest line so ties keep workspaces
    // reading in their switching direction.
    for (var major = count; major >= 1; major -= 1) {
      final minor = (count / major).ceil();
      final columns = acrossRows ? major : minor;
      final rows = acrossRows ? minor : major;
      final cellWidth = (area.width - gap * (columns - 1)) / columns;
      final cellHeight = (area.height - gap * (rows - 1)) / rows;
      final scale = math.min(
        maximumScale,
        math.min(
          (cellWidth - cardInset * 2.0) / sourceWidth,
          (cellHeight - label - cardInset * 2.0) / sourceHeight,
        ),
      );
      if (scale <= 0.0) {
        continue;
      }
      final emptySlots = columns * rows - count;
      final better =
          best == null ||
          scale > best.scale + 0.0001 ||
          ((scale - best.scale).abs() <= 0.0001 && emptySlots < bestEmptySlots);
      if (better) {
        best = (columns: columns, rows: rows, scale: scale);
        bestEmptySlots = emptySlots;
      }
    }
    return best;
  }
}
