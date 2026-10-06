// Previous parser retained for differential tests and local benchmarks.
import 'package:dbus/dbus.dart';
import 'package:denial_flutter_sdk/models.dart';

LogindCapability legacyLogindCapability(String value) => switch (value) {
  'yes' => LogindCapability.available,
  'challenge' => LogindCapability.authenticationRequired,
  'no' => LogindCapability.denied,
  'na' => LogindCapability.unsupported,
  _ => LogindCapability.unavailable,
};

List<LogindInhibitor> legacyLogindInhibitors(
  DBusValue value, {
  int maximum = 64,
}) {
  if (value is! DBusArray || maximum <= 0) {
    return const <LogindInhibitor>[];
  }

  final result = <LogindInhibitor>[];
  for (final entry in value.children) {
    if (result.length >= maximum ||
        entry is! DBusStruct ||
        entry.children.length != 6) {
      continue;
    }
    try {
      final fields = entry.children;
      final mode = fields[3].asString();
      if (mode != 'block' && mode != 'delay') {
        continue;
      }
      final what = fields[0]
          .asString()
          .split(':')
          .map((part) => legacyBoundedText(part, 64))
          .where((part) => part.isNotEmpty)
          .take(16)
          .toSet();
      if (what.isEmpty) {
        continue;
      }
      result.add(
        LogindInhibitor(
          what: what,
          who: legacyBoundedText(fields[1].asString(), 160),
          why: legacyBoundedText(fields[2].asString(), 256),
          mode: mode,
          uid: fields[4].asUint32(),
          pid: fields[5].asUint32(),
        ),
      );
    } on Object {
      // A malformed third-party inhibitor must not poison the entire surface.
    }
  }
  return List<LogindInhibitor>.unmodifiable(result);
}

String legacyBoundedText(String value, int maximumRunes) {
  final normalized = value
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final runes = normalized.runes.take(maximumRunes).toList(growable: false);
  return String.fromCharCodes(runes);
}
