import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/materials.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'glass.dart';

/// The conversation's reply field, on the same floating toolbar material as
/// application search fields, with secret dots.
///
/// Hidden replies keep plaintext only in the controller; the dots are drawn
/// from its length. Suggestions, correction, selection and paste are off.
class SecretField extends StatefulWidget {
  const SecretField({
    required this.controller,
    required this.focusNode,
    required this.placeholder,
    required this.echo,
    required this.enabled,
    required this.busy,
    required this.locked,
    required this.error,
    required this.pendingLength,
    required this.capsLock,
    required this.durationScale,
    required this.onSubmitted,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String placeholder;

  /// Whether the conversation allows a visible reply, such as a user name.
  final bool echo;
  final bool enabled;

  /// A submitted reply is being verified; its dots remain as a quiet wave.
  final bool busy;

  /// The account is locked out; replies cannot succeed until it expires.
  final bool locked;

  /// The previous reply was rejected and nothing new is typed yet.
  final bool error;
  final int pendingLength;
  final bool capsLock;
  final double durationScale;
  final VoidCallback onSubmitted;

  @override
  State<SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<SecretField> {
  Timer? _blink;
  bool _caretVisible = true;

  bool get _focused => widget.focusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_changed);
    widget.controller.addListener(_edited);
    _syncBlink();
  }

  @override
  void didUpdateWidget(SecretField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_changed);
      widget.focusNode.addListener(_changed);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_edited);
      widget.controller.addListener(_edited);
    }
    _syncBlink();
  }

  @override
  void dispose() {
    _blink?.cancel();
    widget.focusNode.removeListener(_changed);
    widget.controller.removeListener(_edited);
    super.dispose();
  }

  void _changed() {
    _syncBlink();
    setState(() {});
  }

  void _edited() {
    // Dots grow at the end, so the caret stays there too.
    final value = widget.controller.value;
    final end = TextSelection.collapsed(offset: value.text.length);
    if (!widget.echo && value.selection != end) {
      widget.controller.value = value.copyWith(selection: end);
      return;
    }
    _caretVisible = true;
    _syncBlink();
    setState(() {});
  }

  /// A stepped blink costs two frames a second rather than continuous ones.
  void _syncBlink() {
    final blinking = !widget.echo && widget.enabled && _focused;
    if (!blinking) {
      _blink?.cancel();
      _blink = null;
      return;
    }
    _blink?.cancel();
    _blink = Timer.periodic(const Duration(milliseconds: 530), (_) {
      if (mounted) setState(() => _caretVisible = !_caretVisible);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = PromptPalette.of(ShellTheme.of(context));
    final colors = context.applicationColors;
    final focused = _focused && widget.enabled;
    final length = widget.busy
        ? widget.pendingLength
        : widget.controller.text.characters.length;
    final empty = length == 0 && widget.controller.text.isEmpty;
    final l10n = context.l10n;
    final placeholder = widget.busy
        ? l10n.polkitVerifying
        : widget.locked
        ? l10n.polkitLocked
        : widget.enabled
        ? widget.placeholder
        : l10n.polkitPreparing;
    final field = EditableText(
      controller: widget.controller,
      focusNode: widget.focusNode,
      readOnly: !widget.enabled,
      obscureText: !widget.echo,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      enableInteractiveSelection: false,
      showCursor: widget.echo,
      rendererIgnoresPointer: true,
      maxLines: 1,
      style: TextStyle(
        fontSize: 15,
        height: 1.2,
        color: widget.echo ? colors.foreground : Colors.transparent,
      ),
      cursorColor: palette.accent,
      backgroundCursorColor: colors.secondary,
      cursorWidth: 2,
      cursorRadius: const Radius.circular(1),
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => widget.onSubmitted(),
    );
    final row = SizedBox(
      height: 48,
      child: Row(
        children: [
          const SizedBox(width: 16),
          Expanded(
            child: Stack(
              alignment: AlignmentDirectional.centerStart,
              children: [
                // Selection is disabled; paste is too, as the agent contract
                // asks of every secret reply.
                Actions(
                  actions: {
                    PasteTextIntent: CallbackAction<PasteTextIntent>(
                      onInvoke: (_) => null,
                    ),
                  },
                  child: field,
                ),
                if (!widget.echo)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: _SecretDots(
                        length: length,
                        color: colors.foreground,
                        caret: palette.accent,
                        showCaret: focused && _caretVisible && !widget.busy,
                        busy: widget.busy,
                        durationScale: widget.durationScale,
                      ),
                    ),
                  ),
                if (empty && !focused)
                  IgnorePointer(
                    child: Padding(
                      padding: EdgeInsets.zero,
                      child: Text(
                        placeholder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          color: colors.secondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (widget.capsLock && widget.enabled)
            Semantics(
              label: 'Caps Lock is on',
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.keyboard_capslock_rounded,
                      size: 15,
                      color: palette.warning,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      l10n.polkitCapsLock,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: palette.warning,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(width: 14),
        ],
      ),
    );
    return Semantics(
      textField: true,
      obscured: !widget.echo,
      label: widget.placeholder,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.text
            : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) {
            if (widget.enabled) widget.focusNode.requestFocus();
          },
          child: DenialMaterial(
            role: DenialMaterialRole.toolbar,
            floating: true,
            inset: DenialApplicationFrame.defaultInset,
            child: Builder(
              // A rejected reply outlines the field until typing resumes.
              builder: (context) => CustomPaint(
                foregroundPainter: widget.error && empty
                    ? OutlinePainter(
                        borderRadius: DenialSurfaceGeometry.borderRadiusOf(
                          context,
                        ),
                        color: palette.danger,
                      )
                    : null,
                child: row,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dots that pop into place per character and shrink away when removed.
/// While a reply is verified they carry a travelling wave.
class _SecretDots extends StatefulWidget {
  const _SecretDots({
    required this.length,
    required this.color,
    required this.caret,
    required this.showCaret,
    required this.busy,
    required this.durationScale,
  });

  final int length;
  final Color color;
  final Color caret;
  final bool showCaret;
  final bool busy;
  final double durationScale;

  @override
  State<_SecretDots> createState() => _SecretDotsState();
}

class _SecretDotsState extends State<_SecretDots>
    with SingleTickerProviderStateMixin {
  static const _birth = Duration(milliseconds: 240);
  static const _death = Duration(milliseconds: 150);

  final _clock = Stopwatch()..start();
  late final Ticker _ticker = createTicker((_) => setState(() {}));
  final List<Duration> _born = [];
  final List<({int index, Duration start})> _dying = [];

  bool get _animated => widget.durationScale > 0;

  @override
  void initState() {
    super.initState();
    // Dots present at mount are already settled.
    _born.addAll(List.filled(widget.length, -_birth));
    _sync();
  }

  @override
  void didUpdateWidget(_SecretDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    final now = _clock.elapsed;
    if (widget.length > _born.length) {
      final count = widget.length - _born.length;
      _born.addAll(List.filled(count, _animated ? now : -_birth));
    } else if (widget.length < _born.length) {
      if (_animated) {
        for (var index = _born.length - 1; index >= widget.length; index--) {
          // Clearing a long reply collapses it right to left.
          final stagger = Duration(
            milliseconds: math.min(14 * (_born.length - 1 - index), 120),
          );
          _dying.add((index: index, start: now + stagger));
        }
      }
      _born.removeRange(widget.length, _born.length);
    }
    _sync();
  }

  void _sync() {
    final now = _clock.elapsed;
    final scale = math.max(widget.durationScale, .01);
    _dying.removeWhere((dot) => now - dot.start > _death * scale);
    final settling = _born.any((born) => now - born < _birth * scale);
    final active = _animated && (widget.busy || settling || _dying.isNotEmpty);
    if (active && !_ticker.isActive) {
      _ticker.start();
    } else if (!active && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    return CustomPaint(
      painter: _SecretDotsPainter(
        now: _clock.elapsed,
        born: _born,
        dying: _dying,
        color: widget.color,
        caret: widget.caret,
        showCaret: widget.showCaret,
        busy: widget.busy && _animated,
        timeScale: math.max(widget.durationScale, .01),
      ),
    );
  }
}

class _SecretDotsPainter extends CustomPainter {
  _SecretDotsPainter({
    required this.now,
    required List<Duration> born,
    required List<({int index, Duration start})> dying,
    required this.color,
    required this.caret,
    required this.showCaret,
    required this.busy,
    required this.timeScale,
  }) : born = List.of(born),
       dying = List.of(dying);

  static const _spacing = 14.0;
  static const _radius = 4.2;

  final Duration now;
  final List<Duration> born;
  final List<({int index, Duration start})> dying;
  final Color color;
  final Color caret;
  final bool showCaret;
  final bool busy;
  final double timeScale;

  double _progress(Duration start, Duration length) =>
      ((now - start).inMicroseconds / (length.inMicroseconds * timeScale))
          .clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final count = born.length;
    // Long replies scroll; the oldest dots leave past the leading edge.
    final room = size.width - 14;
    final shift = math.min(0.0, room - count * _spacing);
    double x(int index) => _spacing / 2 + index * _spacing + shift;
    final paint = Paint()..color = color;
    final seconds = now.inMicroseconds / 1e6;
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    for (final dot in dying) {
      final t = _progress(dot.start, _SecretDotsState._death);
      if (t >= 1) continue;
      canvas.drawCircle(
        Offset(x(dot.index), y),
        _radius * (1 - Curves.easeIn.transform(t)),
        paint,
      );
    }

    for (var index = 0; index < count; index++) {
      final t = _progress(born[index], _SecretDotsState._birth);
      var scale = .35 + .65 * Curves.easeOutBack.transform(t);
      if (busy) {
        final wave = .5 + .5 * math.sin(seconds * math.pi * 1.7 - index * .55);
        scale *= .62 + .38 * wave;
      }
      canvas.drawCircle(Offset(x(index), y), _radius * scale, paint);
    }

    if (showCaret) {
      final caretX = count == 0 ? 1.0 : x(count - 1) + _spacing / 2 + 3;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(caretX, y), width: 2, height: 20),
          const Radius.circular(1),
        ),
        Paint()..color = caret,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SecretDotsPainter oldDelegate) => true;
}
