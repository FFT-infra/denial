part of 'lock_screen_layer.dart';

/// Mobile PIN entry: dots and a numeric keypad over the lock backdrop.
///
/// Digits stay in this widget until the PIN is complete, then reach deniald
/// as one response; the length comes from deniald, so the last digit submits.
/// Motion follows the shell rules: the stage fades through a snapshot and
/// moves its layer, and the shake only moves the dots' layer.
class _MobileLockPinStage extends ConsumerStatefulWidget {
  const _MobileLockPinStage({
    super.key,
    required this.reveal,
    required this.onBegin,
    required this.onCancel,
    required this.onUsePassword,
  });

  /// 0 hidden, 1 fully shown; already curved.
  final Animation<double> reveal;
  final VoidCallback onBegin;
  final VoidCallback onCancel;
  final VoidCallback onUsePassword;

  @override
  ConsumerState<_MobileLockPinStage> createState() =>
      _MobileLockPinStageState();
}

class _MobileLockPinStageState extends ConsumerState<_MobileLockPinStage>
    with SingleTickerProviderStateMixin {
  static const Duration _shakeDuration = Duration(milliseconds: 440);

  /// Character codes, scrubbed as soon as they are sent or dropped.
  final List<int> _digits = <int>[];
  final FocusNode _keys = FocusNode(debugLabel: 'lock-pin-keys');
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: _shakeDuration,
  );
  late final Animation<Offset> _shakeOffset = _shake.drive(
    const _PinShakeOffset(),
  );
  late final Animation<Offset> _rise = widget.reveal.drive(
    Tween<Offset>(begin: const Offset(0, 28), end: Offset.zero),
  );

  /// Dots shown filled; stays full while deniald checks a submitted PIN.
  int _filled = 0;
  bool _submitted = false;
  bool _pendingSubmit = false;
  bool _wrong = false;

  @override
  void dispose() {
    _scrub();
    _keys.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _scrub() {
    _digits.fillRange(0, _digits.length, 0);
    _digits.clear();
  }

  bool _acceptsInput(AuthenticationState state) =>
      state.locked &&
      state.available &&
      !state.rateLimited &&
      !_submitted &&
      !_shake.isAnimating;

  void _press(int digit) {
    final state = ref.read(authenticationProvider);
    if (!_acceptsInput(state) || _digits.length >= state.pinLength) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _digits.add(0x30 + digit);
      _filled = _digits.length;
      _wrong = false;
    });
    // A failed attempt ends deniald's prompt; the next digit opens another.
    if (!state.busy) {
      widget.onBegin();
    }
    if (_digits.length == state.pinLength) {
      _submit();
    }
  }

  void _delete() {
    if (_submitted || _digits.isEmpty || _shake.isAnimating) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _digits.last = 0;
      _digits.removeLast();
      _filled = _digits.length;
    });
  }

  void _clear() {
    if (_submitted || _digits.isEmpty || _shake.isAnimating) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _scrub();
      _filled = 0;
    });
  }

  void _submit() {
    final state = ref.read(authenticationProvider);
    final prompt = state.prompt;
    if (!state.busy || prompt == null || !prompt.isPin) {
      // The prompt is still on its way; submit as soon as it lands.
      _pendingSubmit = true;
      return;
    }
    _pendingSubmit = false;
    final pin = String.fromCharCodes(_digits);
    _scrub();
    setState(() => _submitted = true);
    ref.read(authenticationProvider.notifier).respond(pin);
  }

  void _attemptFinished(AuthenticationState state) {
    _submitted = false;
    if (!state.locked) {
      return;
    }
    if (!state.resultIsError || state.resultMessage == null) {
      // Cancelled or timed out: start over quietly.
      setState(() => _filled = 0);
      return;
    }
    final haptics = ref.read(hapticsServiceProvider)..pulse();
    Future<void>.delayed(const Duration(milliseconds: 110), haptics.pulse);
    setState(() => _wrong = true);
    void settle() {
      if (mounted) setState(() => _filled = 0);
    }

    if (MediaQuery.disableAnimationsOf(context)) {
      settle();
    } else {
      _shake.forward(from: 0).whenCompleteOrCancel(settle);
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final digit = _digitKeys.indexOf(key);
    final numpad = _numpadKeys.indexOf(key);
    if (digit >= 0 || numpad >= 0) {
      _press(digit >= 0 ? digit : numpad);
    } else if (key == LogicalKeyboardKey.backspace) {
      _delete();
    } else if (key == LogicalKeyboardKey.escape) {
      widget.onCancel();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final authentication = ref.watch(authenticationProvider);
    ref.listen<AuthenticationState>(authenticationProvider, (previous, next) {
      if (_pendingSubmit && next.busy && (next.prompt?.isPin ?? false)) {
        _submit();
      }
      if (_submitted && (previous?.busy ?? false) && !next.busy) {
        _attemptFinished(next);
      }
    });
    final l10n = context.l10n;
    final length = authentication.pinLength.clamp(1, 12);
    final enabled = _acceptsInput(authentication);
    final cooldownSeconds = (authentication.cooldown.inMilliseconds / 1000)
        .ceil()
        .clamp(1, 30);
    final (message, messageColor) = authentication.rateLimited
        ? (
            l10n.lockRetryInSeconds(cooldownSeconds),
            ShellTelemetryColors.warning,
          )
        : _wrong
        ? (l10n.lockWrongPin, ShellTelemetryColors.danger)
        : !authentication.available
        ? (
            authentication.statusMessage ?? l10n.lockAuthenticationUnavailable,
            ShellMediaColors.lightForegroundSecondary,
          )
        : (null, ShellMediaColors.lightForegroundSecondary);

    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: CustomPaint(
              painter: _PinStageScrimPainter(
                reveal: widget.reveal,
                color: ShellMediaColors.darkness.withValues(alpha: 0.42),
              ),
            ),
          ),
          FadeSnapshot(
            opacity: widget.reveal,
            child: CompositedTranslation(
              translation: _rise,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              child: Focus(
                focusNode: _keys,
                autofocus: true,
                onKeyEvent: _handleKey,
                child: SafeArea(
                  minimum: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final keySize = (constraints.maxWidth * 0.205)
                          .clamp(62.0, 80.0)
                          .toDouble();
                      final compact = constraints.maxHeight < 600;
                      return Column(
                        children: [
                          Spacer(flex: compact ? 1 : 3),
                          Icon(
                            Icons.lock_rounded,
                            size: 20,
                            color: ShellMediaColors.lightForegroundSecondary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            l10n.lockEnterPin,
                            textAlign: TextAlign.center,
                            style: ShellText.base.copyWith(
                              color: ShellMediaColors.lightForeground,
                              fontSize: 21,
                              height: 1.15,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 22),
                          CompositedTranslation(
                            translation: _shakeOffset,
                            devicePixelRatio: MediaQuery.devicePixelRatioOf(
                              context,
                            ),
                            child: _PinDots(
                              length: length,
                              filled: _filled,
                              error: _wrong,
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            height: 18,
                            child: message == null
                                ? null
                                : Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      message,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: ShellText.base.copyWith(
                                        color: messageColor,
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                          ),
                          Spacer(flex: compact ? 1 : 2),
                          _PinPad(
                            keySize: keySize,
                            enabled: enabled,
                            onDigit: _press,
                            trailing: _filled == 0 || _submitted
                                ? _PinTextKey(
                                    size: keySize,
                                    label: l10n.commonCancel,
                                    onPressed: widget.onCancel,
                                  )
                                : _PinIconKey(
                                    size: keySize,
                                    icon: Icons.backspace_outlined,
                                    label: l10n.lockPinDelete,
                                    onPressed: _delete,
                                    onLongPress: _clear,
                                  ),
                          ),
                          SizedBox(height: compact ? 10 : 22),
                          _PinLink(
                            label: l10n.lockUsePassword,
                            onPressed: widget.onUsePassword,
                            color: ShellMediaColors.lightForegroundSecondary,
                          ),
                          SizedBox(height: compact ? 4 : 10),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const List<LogicalKeyboardKey> _digitKeys = <LogicalKeyboardKey>[
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

const List<LogicalKeyboardKey> _numpadKeys = <LogicalKeyboardKey>[
  LogicalKeyboardKey.numpad0,
  LogicalKeyboardKey.numpad1,
  LogicalKeyboardKey.numpad2,
  LogicalKeyboardKey.numpad3,
  LogicalKeyboardKey.numpad4,
  LogicalKeyboardKey.numpad5,
  LogicalKeyboardKey.numpad6,
  LogicalKeyboardKey.numpad7,
  LogicalKeyboardKey.numpad8,
  LogicalKeyboardKey.numpad9,
];

/// A damped side-to-side shake, three swings that settle back to zero.
class _PinShakeOffset extends Animatable<Offset> {
  const _PinShakeOffset();

  @override
  Offset transform(double t) =>
      Offset(math.sin(t * math.pi * 6) * 13 * (1 - t), 0);
}

/// Dims the wallpaper toward the theme background as the stage appears,
/// repainting only this layer.
class _PinStageScrimPainter extends CustomPainter {
  _PinStageScrimPainter({required this.reveal, required this.color})
    : super(repaint: reveal);

  final Animation<double> reveal;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final opacity = reveal.value.clamp(0.0, 1.0);
    if (opacity == 0) {
      return;
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = color.withValues(alpha: color.a * opacity),
    );
  }

  @override
  bool shouldRepaint(covariant _PinStageScrimPainter oldDelegate) =>
      oldDelegate.reveal != reveal || oldDelegate.color != color;
}

class _PinDots extends StatelessWidget {
  const _PinDots({
    required this.length,
    required this.filled,
    required this.error,
  });

  final int length;
  final int filled;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final ink = error
        ? ShellTelemetryColors.danger
        : ShellMediaColors.lightForeground;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 150);
    return Semantics(
      label: context.l10n.lockPinProgress(filled, length),
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < length; index++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9),
                child: AnimatedScale(
                  scale: index < filled ? 1.0 : 0.84,
                  duration: duration,
                  curve: Curves.easeOutBack,
                  child: AnimatedContainer(
                    duration: duration,
                    curve: Curves.easeOut,
                    width: 13,
                    height: 13,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: index < filled ? ink : ink.withValues(alpha: 0),
                      border: Border.all(
                        color: index < filled
                            ? ink
                            : ink.withValues(alpha: 0.55),
                        width: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PinPad extends StatelessWidget {
  const _PinPad({
    required this.keySize,
    required this.enabled,
    required this.onDigit,
    required this.trailing,
  });

  final double keySize;
  final bool enabled;
  final ValueChanged<int> onDigit;
  final Widget trailing;

  static const List<String> _letters = <String>[
    '',
    '',
    'ABC',
    'DEF',
    'GHI',
    'JKL',
    'MNO',
    'PQRS',
    'TUV',
    'WXYZ',
  ];

  @override
  Widget build(BuildContext context) {
    final columnGap = keySize * 0.36;
    final rowGap = keySize * 0.2;
    Widget digit(int value) => _PinDigitKey(
      size: keySize,
      digit: value,
      letters: _letters[value],
      enabled: enabled,
      onPressed: () => onDigit(value),
    );
    Widget row(List<Widget> keys) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        keys[0],
        SizedBox(width: columnGap),
        keys[1],
        SizedBox(width: columnGap),
        keys[2],
      ],
    );
    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row([digit(1), digit(2), digit(3)]),
          SizedBox(height: rowGap),
          row([digit(4), digit(5), digit(6)]),
          SizedBox(height: rowGap),
          row([digit(7), digit(8), digit(9)]),
          SizedBox(height: rowGap),
          row([SizedBox.square(dimension: keySize), digit(0), trailing]),
        ],
      ),
    );
  }
}

/// Responds on touch-down, like a dial pad: the highlight appears at once and
/// fades after release. Only the key's own layer repaints.
class _PinKeyPress extends StatefulWidget {
  const _PinKeyPress({
    required this.size,
    required this.enabled,
    required this.label,
    required this.onPressed,
    required this.builder,
    this.onLongPress,
  });

  final double size;
  final bool enabled;
  final String label;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final Widget Function(BuildContext context, Animation<double> press) builder;

  @override
  State<_PinKeyPress> createState() => _PinKeyPressState();
}

class _PinKeyPressState extends State<_PinKeyPress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _release() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _press.value = 0;
    } else {
      _press.animateTo(0, curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      onTap: widget.enabled ? widget.onPressed : null,
      onLongPress: widget.enabled ? widget.onLongPress : null,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: widget.enabled ? widget.onLongPress : null,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) {
              if (!widget.enabled) return;
              _press.value = 1;
              widget.onPressed();
            },
            onPointerUp: (_) => _release(),
            onPointerCancel: (_) => _release(),
            child: SizedBox.square(
              dimension: widget.size,
              child: RepaintBoundary(child: widget.builder(context, _press)),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinDigitKey extends StatelessWidget {
  const _PinDigitKey({
    required this.size,
    required this.digit,
    required this.letters,
    required this.enabled,
    required this.onPressed,
  });

  final double size;
  final int digit;
  final String letters;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ink = enabled
        ? ShellMediaColors.lightForeground
        : ShellMediaColors.lightForeground.withValues(alpha: 0.38);
    return _PinKeyPress(
      size: size,
      enabled: enabled,
      label: '$digit',
      onPressed: onPressed,
      builder: (context, press) => CustomPaint(
        painter: _PinKeyFillPainter(
          press: press,
          rest: ShellMediaColors.lightForeground.withValues(
            alpha: enabled ? 0.11 : 0.06,
          ),
          pressed: ShellMediaColors.lightForeground.withValues(alpha: 0.32),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$digit',
                style: ShellText.base.copyWith(
                  color: ink,
                  fontSize: size * 0.42,
                  height: 1.0,
                  fontWeight: FontWeight.w300,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              SizedBox(
                height: size * 0.15,
                child: letters.isEmpty
                    ? null
                    : Text(
                        letters,
                        style: ShellText.base.copyWith(
                          color: ink.withValues(alpha: ink.a * 0.72),
                          fontSize: size * 0.12,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          letterSpacing: size * 0.024,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PinIconKey extends StatelessWidget {
  const _PinIconKey({
    required this.size,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.onLongPress,
  });

  final double size;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return _PinKeyPress(
      size: size,
      enabled: true,
      label: label,
      onPressed: onPressed,
      onLongPress: onLongPress,
      builder: (context, press) => CustomPaint(
        painter: _PinKeyFillPainter(
          press: press,
          rest: ShellMediaColors.lightForeground.withValues(alpha: 0),
          pressed: ShellMediaColors.lightForeground.withValues(alpha: 0.16),
        ),
        child: Center(
          child: Icon(
            icon,
            size: size * 0.32,
            color: ShellMediaColors.lightForeground,
          ),
        ),
      ),
    );
  }
}

class _PinTextKey extends StatelessWidget {
  const _PinTextKey({
    required this.size,
    required this.label,
    required this.onPressed,
  });

  final double size;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _PinKeyPress(
      size: size,
      enabled: true,
      label: label,
      onPressed: onPressed,
      builder: (context, press) => CustomPaint(
        painter: _PinKeyFillPainter(
          press: press,
          rest: ShellMediaColors.lightForeground.withValues(alpha: 0),
          pressed: ShellMediaColors.lightForeground.withValues(alpha: 0.16),
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: ShellText.base.copyWith(
              color: ShellMediaColors.lightForeground,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _PinKeyFillPainter extends CustomPainter {
  _PinKeyFillPainter({
    required this.press,
    required this.rest,
    required this.pressed,
  }) : super(repaint: press);

  final Animation<double> press;
  final Color rest;
  final Color pressed;

  @override
  void paint(Canvas canvas, Size size) {
    final color = Color.lerp(rest, pressed, press.value)!;
    if (color.a == 0) {
      return;
    }
    canvas.drawCircle(
      size.center(Offset.zero),
      size.shortestSide / 2,
      Paint()
        ..isAntiAlias = true
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _PinKeyFillPainter oldDelegate) =>
      oldDelegate.press != press ||
      oldDelegate.rest != rest ||
      oldDelegate.pressed != pressed;
}

class _PinLink extends StatelessWidget {
  const _PinLink({required this.label, required this.onPressed, this.color});

  final String label;
  final VoidCallback onPressed;

  /// Theme ink by default; the PIN stage passes its fixed light ink.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Text(
                label,
                style: ShellText.base.copyWith(
                  color: color ?? context.shellColors.textSecondary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
