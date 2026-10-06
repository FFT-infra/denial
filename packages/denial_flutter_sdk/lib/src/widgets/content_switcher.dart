import 'package:flutter/widgets.dart';

/// Changes page content without applying opacity to the page's material.
/// DenialContentPane consumes the animation only around its content slivers.
/// Outgoing content fades away before the next page enters, so opaque page
/// backings never cover a second page's partially visible content.
class DenialContentSwitcher extends StatefulWidget {
  const DenialContentSwitcher({
    required this.contentKey,
    required this.child,
    this.duration = const Duration(milliseconds: 160),
    super.key,
  });

  final Key contentKey;
  final Widget child;
  final Duration duration;

  @override
  State<DenialContentSwitcher> createState() => _DenialContentSwitcherState();
}

class _DenialContentSwitcherState extends State<DenialContentSwitcher>
    with SingleTickerProviderStateMixin {
  late Key displayedKey = widget.contentKey;
  late Widget displayedChild = widget.child;
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: widget.duration ~/ 2,
      value: 1,
    )..addStatusListener(onStatus);
  }

  void onStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || !mounted) return;
    setState(() {
      displayedKey = widget.contentKey;
      displayedChild = widget.child;
    });
    controller.forward();
  }

  @override
  void didUpdateWidget(DenialContentSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    controller.duration = widget.duration ~/ 2;
    if (widget.duration == Duration.zero) {
      controller.stop();
      displayedKey = widget.contentKey;
      displayedChild = widget.child;
      controller.value = 1;
    } else if (widget.contentKey != displayedKey) {
      controller.reverse();
    } else {
      displayedChild = widget.child;
      // Returning to the outgoing tab cancels the pending change smoothly.
      if (controller.status == AnimationStatus.reverse) controller.forward();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DenialContentTransition(
    opacity: controller,
    child: IgnorePointer(
      ignoring: displayedKey != widget.contentKey,
      child: KeyedSubtree(key: displayedKey, child: displayedChild),
    ),
  );
}

/// An animation channel, not an opacity layer. Surface backings stay opaque.
class DenialContentTransition extends InheritedWidget {
  const DenialContentTransition({
    required this.opacity,
    required super.child,
    super.key,
  });

  final Animation<double> opacity;

  static Animation<double> opacityOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DenialContentTransition>()
          ?.opacity ??
      const AlwaysStoppedAnimation(1);

  @override
  bool updateShouldNotify(DenialContentTransition oldWidget) =>
      opacity != oldWidget.opacity;
}
