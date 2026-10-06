import 'dart:io';

import 'package:denial_desktop/src/state/window_emphasis_requests.dart';

void check(Object? actual, Object? expected) {
  if (actual != expected) throw StateError('$actual != $expected');
}

void main() {
  WindowEmphasisTarget target(int id, {int monitor = 10, int? workspace = 1}) =>
      (windowId: id, monitorId: monitor, workspaceId: workspace);
  final changes = <WindowEmphasisTarget?>[];
  final requests = WindowEmphasisRequests(changes.add);
  final releaseFirst = requests.begin(target(1));
  check(requests.target?.windowId, 1);
  final releaseSecond = requests.begin(target(2));
  releaseFirst();
  check(requests.target?.windowId, 2);
  releaseSecond();
  releaseSecond();
  check(requests.target?.windowId, null);
  check(changes.map((value) => value?.windowId).join(','), '1,2,null');

  final releaseOld = requests.begin(target(3));
  requests
      .clear(); // Target closed, focus/workspace changed, or session locked.
  final releaseNew = requests.begin(target(3));
  releaseOld();
  check(requests.target?.windowId, 3);
  releaseNew();
  check(requests.target?.windowId, null);

  final releaseSameOld = requests.begin(target(4));
  final count = changes.length;
  final releaseSameNew = requests.begin(target(4));
  check(changes.length, count);
  releaseSameOld();
  check(requests.target?.windowId, 4);
  releaseSameNew();
  check(requests.target?.windowId, null);
  // Same ID in another scope is a distinct request and owns its release.
  final previousScope = requests.begin(target(4));
  final newScope = requests.begin(target(4, monitor: 20, workspace: 2));
  previousScope();
  check(requests.target, target(4, monitor: 20, workspace: 2));
  newScope();
  check(requests.target, null);

  final scoped = target(1);
  bool faded({
    int id = 2,
    int monitor = 10,
    int workspace = 1,
    bool pinned = false,
    WindowEmphasisTarget? scope,
  }) => windowIsDeemphasized(
    scope ?? scoped,
    windowId: id,
    monitorId: monitor,
    workspaceId: workspace,
    pinned: pinned,
  );
  check(faded(), true);
  check(faded(id: 1), false); // Hovered window stays unchanged.
  check(faded(monitor: 20), false); // Same workspace number, different output.
  check(faded(workspace: 2), false); // Same output, different workspace.
  check(faded(monitor: 20, workspace: 2), false);
  check(faded(workspace: 2, pinned: true), true); // Visible on every workspace.
  check(faded(monitor: 20, pinned: true), false);
  check(faded(scope: target(1, workspace: null), workspace: 7), true);
  check(faded(scope: target(1, workspace: null), monitor: 20), false);
  check(
    windowIsDeemphasized(
      null,
      windowId: 2,
      monitorId: 10,
      workspaceId: 1,
      pinned: false,
    ),
    false,
  );
  stdout.writeln(
    'Window emphasis scope, ownership and cancellation checks passed.',
  );
}
