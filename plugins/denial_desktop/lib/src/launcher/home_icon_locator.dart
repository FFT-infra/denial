import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/models.dart';

/// A home icon a window transition starts or ends on.
@immutable
class HomeIconTarget {
  const HomeIconTarget({required this.item, required this.rect});

  /// The app, or the closed folder that holds it.
  final HomeGridItem item;

  /// The icon's bounds in global logical coordinates.
  final Rect rect;
}

/// Lets window transitions find an application's icon on home, and hide it
/// while they draw it themselves.
class HomeIconLocator {
  /// The home item a transition currently draws in home's place.
  final hidden = ValueNotifier<String?>(null);

  HomeIconTarget? Function(DenialWindow window)? _find;

  /// Home answers for the icons it shows; one surface at a time.
  void attach(HomeIconTarget? Function(DenialWindow window) find) =>
      _find = find;

  void detach(HomeIconTarget? Function(DenialWindow window) find) {
    if (identical(_find, find)) _find = null;
  }

  /// The visible home icon of [window]'s application: on the current page,
  /// or in the open folder. Null when home does not show it.
  HomeIconTarget? iconFor(DenialWindow window) => _find?.call(window);

  void hide(String itemId) => hidden.value = itemId;

  /// Shows [itemId] again, unless another transition has hidden an icon
  /// since.
  void reveal(String itemId) {
    if (hidden.value == itemId) hidden.value = null;
  }

  void dispose() => hidden.dispose();
}

final homeIconLocatorProvider = Provider<HomeIconLocator>((ref) {
  final locator = HomeIconLocator();
  ref.onDispose(locator.dispose);
  return locator;
});

/// Whether [window] belongs to the home application [app].
bool launcherAppShowsWindow(
  HomeGridItem app,
  DenialWindow window,
  AppLauncher launcher,
) {
  if (app.localApp case final local?) {
    return local.id == window.appId;
  }
  final desktop = app.app;
  if (desktop == null) return false;
  final identity = launcherAppIdentity(window.appId);
  return launcher
      .expectedWindowAppIds(desktop)
      .any((candidate) => launcherAppIdentity(candidate) == identity);
}

/// The form in which window and desktop-entry app ids compare.
String launcherAppIdentity(String id) =>
    id.trim().toLowerCase().replaceFirst(RegExp(r'\.desktop$'), '');
