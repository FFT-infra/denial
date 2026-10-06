import 'dart:async';
import 'dart:convert';

import 'package:denial_flutter_sdk/actions.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/denial_bridge.dart';
import '../platform/denial_bridge_provider.dart';

/// Binds a generated action list to the native shortcut bridge. Custom shells
/// can use this host without adopting the reference desktop's widget hierarchy.
class ShellActionsBinding extends ConsumerStatefulWidget {
  const ShellActionsBinding({
    super.key,
    required this.actions,
    required this.services,
    required this.child,
  });
  final List<ShellAction> actions;
  final ShellServices services;
  final Widget child;
  @override
  ConsumerState<ShellActionsBinding> createState() =>
      _ShellActionsBindingState();
}

class _ShellActionsBindingState extends ConsumerState<ShellActionsBinding> {
  late final DenialBridge _bridge;
  StreamSubscription<({int generation, String id, int? monitorId})>?
  _subscription;
  Map<String, ShellAction> _handlers = const {};
  int _generation = 0;
  String? _published;
  static int _nextGeneration = DateTime.now().microsecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    _bridge = ref.read(denialBridgeProvider);
    _subscription = _bridge.pluginActions.listen((event) {
      if (!mounted || event.generation != _generation) return;
      final handler = _handlers[event.id];
      if (handler == null) return;
      unawaited(
        Future<void>.sync(
          () => handler.invoke(
            ShellActionContext(
              services: widget.services,
              monitorId: event.monitorId,
            ),
          ),
        ).catchError((Object error, StackTrace stack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'Denial plugin actions',
              context: ErrorDescription('invoking ${event.id}'),
            ),
          );
        }),
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _publish();
  }

  @override
  void didUpdateWidget(covariant ShellActionsBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    _publish();
  }

  void _publish() {
    final handlers = <String, ShellAction>{};
    final descriptors = <Map<String, Object>>[];
    final identity = RegExp(r'^[a-z0-9_]+\.[A-Za-z0-9_.-]+$');
    if (widget.actions.length > 256) {
      throw StateError('Too many plugin actions (maximum 256)');
    }
    bool validText(String value, int limit, {bool required = false}) =>
        (!required || value.isNotEmpty) &&
        utf8.encode(value).length <= limit &&
        !value.runes.any((rune) => rune < 32 || (rune >= 127 && rune <= 159));
    for (final action in widget.actions) {
      if (action.id.length > 256 ||
          !identity.hasMatch(action.id) ||
          action.id.startsWith('native.') ||
          handlers.containsKey(action.id)) {
        throw StateError('Invalid or duplicate plugin action ID: ${action.id}');
      }
      final label = action.label(context);
      final description = action.description(context);
      if (!validText(label, 256, required: true) ||
          !validText(description, 2048) ||
          !validText(action.provider, 256, required: true)) {
        throw StateError('Invalid plugin action metadata: ${action.id}');
      }
      handlers[action.id] = action;
      descriptors.add({
        'id': action.id,
        'label': label,
        'description': description,
        'provider': action.provider,
      });
    }
    final signature = jsonEncode(descriptors);
    if (utf8.encode(signature).length > 128 * 1024) {
      throw StateError('Plugin action catalog exceeds 128 KiB');
    }
    _handlers = handlers;
    if (_published == signature) return;
    _published = signature;
    _generation = ++_nextGeneration;
    _bridge.publishPluginActions(_generation, descriptors);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _handlers = const {};
    _bridge.publishPluginActions(++_nextGeneration, const []);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
