import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';

enum ShellDismissPolicy { none, outsideTap, outsideTapAndEscape }

typedef ShellPopupBuilder = Widget Function(
  BuildContext context,
  ShellPopupHandle handle,
);

@immutable
class ManagedShellPopup {
  const ManagedShellPopup({
    required this.id,
    required this.keyName,
    required this.debugLabel,
    required this.builder,
    required this.pointerPolicy,
    required this.keyboardPolicy,
    required this.compositorPolicy,
    required this.dismissPolicy,
    required this.transitionDuration,
    required this.barrierColor,
    required this.closing,
    required this.restoreFocus,
  });

  final int id;
  final String? keyName;
  final String debugLabel;
  final ShellPopupBuilder builder;
  final ShellPointerPolicy pointerPolicy;
  final ShellKeyboardPolicy keyboardPolicy;
  final ShellCompositorPolicy compositorPolicy;
  final ShellDismissPolicy dismissPolicy;
  final Duration transitionDuration;
  final Color? barrierColor;
  final bool closing;
  final FocusNode? restoreFocus;

  ManagedShellPopup copyWith({bool? closing}) {
    return ManagedShellPopup(
      id: id,
      keyName: keyName,
      debugLabel: debugLabel,
      builder: builder,
      pointerPolicy: pointerPolicy,
      keyboardPolicy: keyboardPolicy,
      compositorPolicy: compositorPolicy,
      dismissPolicy: dismissPolicy,
      transitionDuration: transitionDuration,
      barrierColor: barrierColor,
      closing: closing ?? this.closing,
      restoreFocus: restoreFocus,
    );
  }
}

final shellPopupControllerProvider =
    NotifierProvider<ShellPopupController, List<ManagedShellPopup>>(
      ShellPopupController.new,
    );

class ShellPopupController extends Notifier<List<ManagedShellPopup>> {
  late ShellInteractionRegistry _interactions;

  @override
  List<ManagedShellPopup> build() {
    _interactions = ref.watch(shellInteractionRegistryProvider.notifier);
    return const <ManagedShellPopup>[];
  }

  ShellPopupHandle show({
    required String debugLabel,
    required ShellPopupBuilder builder,
    String? keyName,
    ShellPointerPolicy pointerPolicy = ShellPointerPolicy.fullScene,
    ShellKeyboardPolicy keyboardPolicy = ShellKeyboardPolicy.capture,
    ShellCompositorPolicy compositorPolicy = ShellCompositorPolicy.normal,
    ShellDismissPolicy dismissPolicy = ShellDismissPolicy.outsideTapAndEscape,
    Duration transitionDuration = Motion.cardSettle,
    Color? barrierColor,
  }) {
    if (keyName != null) {
      for (final surface in state.reversed) {
        if (surface.keyName == keyName && !surface.closing) {
          return ShellPopupHandle._(this, surface.id);
        }
      }
    }

    final id = _interactions.reserveSurfaceId();
    final surface = ManagedShellPopup(
      id: id,
      keyName: keyName,
      debugLabel: debugLabel,
      builder: builder,
      pointerPolicy: pointerPolicy,
      keyboardPolicy: keyboardPolicy,
      compositorPolicy: compositorPolicy,
      dismissPolicy: dismissPolicy,
      transitionDuration: transitionDuration,
      barrierColor: barrierColor,
      closing: false,
      restoreFocus: FocusManager.instance.primaryFocus,
    );
    state = List<ManagedShellPopup>.unmodifiable(<ManagedShellPopup>[
      ...state,
      surface,
    ]);
    _interactions.upsert(
      ShellInteractionSurface(
        id: id,
        debugLabel: debugLabel,
        pointerPolicy: pointerPolicy,
        keyboardPolicy: keyboardPolicy,
        compositorPolicy: compositorPolicy,
      ),
    );
    return ShellPopupHandle._(this, id);
  }

  void close(int id) {
    var changed = false;
    final next = <ManagedShellPopup>[];
    for (final surface in state) {
      if (surface.id == id && !surface.closing) {
        changed = true;
        next.add(surface.copyWith(closing: true));
      } else {
        next.add(surface);
      }
    }
    if (changed) {
      state = List<ManagedShellPopup>.unmodifiable(next);
    }
  }

  void completeClose(int id) {
    ManagedShellPopup? removed;
    final next = <ManagedShellPopup>[];
    for (final surface in state) {
      if (surface.id == id) {
        removed = surface;
      } else {
        next.add(surface);
      }
    }
    if (removed == null) {
      return;
    }
    state = List<ManagedShellPopup>.unmodifiable(next);
    _interactions.remove(id);
    final restoreFocus = removed.restoreFocus;
    if (restoreFocus != null && restoreFocus.canRequestFocus) {
      restoreFocus.requestFocus();
    }
  }

  /// Removes every transient surface synchronously.
  ///
  /// Locking uses this path so credential fields are disposed before the lock
  /// layer becomes interactive. Focus is deliberately not restored into the
  /// now-secured scene.
  void dismissAllImmediately() {
    if (state.isEmpty) {
      return;
    }
    for (final surface in state) {
      _interactions.remove(surface.id);
    }
    state = const <ManagedShellPopup>[];
  }
}

class ShellPopupHandle {
  const ShellPopupHandle._(this._controller, this.id);

  final ShellPopupController _controller;
  final int id;

  void close() => _controller.close(id);
}

/// The only host for transient shell surfaces. Entries remain registered with
/// native input routing until their closing transition has fully completed.
class ShellPopupHost extends ConsumerWidget {
  const ShellPopupHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surfaces = ref.watch(shellPopupControllerProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        for (final surface in surfaces)
          _ManagedShellPopupLayer(
            key: ValueKey<int>(surface.id),
            surface: surface,
          ),
      ],
    );
  }
}

class _ManagedShellPopupLayer extends ConsumerStatefulWidget {
  const _ManagedShellPopupLayer({required this.surface, super.key});

  final ManagedShellPopup surface;

  @override
  ConsumerState<_ManagedShellPopupLayer> createState() =>
      _ManagedShellPopupLayerState();
}

class _ManagedShellPopupLayerState
    extends ConsumerState<_ManagedShellPopupLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;
  final FocusScopeNode _focusScopeNode = FocusScopeNode(
    debugLabel: 'managed-shell-surface',
  );
  bool _completingClose = false;

  @override
  void initState() {
    super.initState();
    final reduceMotion = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    _controller = AnimationController(
      vsync: this,
      duration: reduceMotion
          ? Duration.zero
          : widget.surface.transitionDuration,
      reverseDuration: reduceMotion
          ? Duration.zero
          : widget.surface.transitionDuration,
    );
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Motion.md3EmphasizedDecelerate,
      reverseCurve: Motion.md3EmphasizedAccelerate,
    );
    _opacity = curved;
    _scale = Tween<double>(begin: 0.96, end: 1.0).animate(curved);
    unawaited(_controller.forward());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.surface.closing) {
        _focusScopeNode.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _ManagedShellPopupLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.surface.closing && !oldWidget.surface.closing) {
      _beginClose();
    }
  }

  void _beginClose() {
    if (_completingClose) {
      return;
    }
    _completingClose = true;
    _controller.reverse().whenCompleteOrCancel(() {
      if (!mounted) {
        return;
      }
      ref
          .read(shellPopupControllerProvider.notifier)
          .completeClose(widget.surface.id);
    });
  }

  @override
  void dispose() {
    _focusScopeNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = widget.surface;
    final handle = ShellPopupHandle._(
      ref.read(shellPopupControllerProvider.notifier),
      surface.id,
    );
    final dismissOnOutside =
        surface.dismissPolicy == ShellDismissPolicy.outsideTap ||
        surface.dismissPolicy == ShellDismissPolicy.outsideTapAndEscape;
    final dismissOnEscape =
        surface.dismissPolicy == ShellDismissPolicy.outsideTapAndEscape;

    return IgnorePointer(
      ignoring: surface.closing,
      child: FadeTransition(
        opacity: _opacity,
        child: FocusScope(
          node: _focusScopeNode,
          onKeyEvent: (_, event) {
            if (dismissOnEscape &&
                event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              handle.close();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Semantics(
            scopesRoute: true,
            explicitChildNodes: true,
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: dismissOnOutside ? handle.close : null,
                  child: ColoredBox(
                    color:
                        surface.barrierColor ??
                        context.shellColors.overviewScrim,
                  ),
                ),
                ScaleTransition(
                  scale: _scale,
                  child: surface.builder(context, handle),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
