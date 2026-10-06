import 'dart:collection';

import 'package:dbus/dbus.dart';

import '../core/bounded_text.dart';
import '../models/logind.dart';

LogindCapability parseLogindCapability(String value) => switch (value) {
  'yes' => LogindCapability.available,
  'challenge' => LogindCapability.authenticationRequired,
  'no' => LogindCapability.denied,
  'na' => LogindCapability.unsupported,
  _ => LogindCapability.unavailable,
};

List<LogindInhibitor> parseLogindInhibitors(
  DBusValue value, {
  int maximum = 64,
}) {
  if (value is! DBusArray || maximum <= 0) {
    return const <LogindInhibitor>[];
  }

  final result = <LogindInhibitor>[];
  for (final entry in value.children) {
    if (entry is! DBusStruct || entry.children.length != 6) {
      continue;
    }
    try {
      final fields = entry.children;
      final mode = fields[3].asString();
      if (mode != 'block' && mode != 'delay') {
        continue;
      }
      final what = _parseInhibitorClasses(fields[0].asString());
      if (what.isEmpty) {
        continue;
      }
      result.add(
        LogindInhibitor(
          what: what,
          who: normalizeBoundedText(fields[1].asString(), 160),
          why: normalizeBoundedText(fields[2].asString(), 256),
          mode: mode,
          uid: fields[4].asUint32(),
          pid: fields[5].asUint32(),
        ),
      );
      if (result.length == maximum) break;
    } on Object {
      // A malformed third-party inhibitor must not poison the entire surface.
    }
  }
  return UnmodifiableListView(result);
}

Set<String> _parseInhibitorClasses(String value) {
  final classes = <String>{};
  var start = 0;
  var accepted = 0;
  while (start <= value.length && accepted < 16) {
    final separator = value.indexOf(':', start);
    final end = separator < 0 ? value.length : separator;
    final normalized = normalizeBoundedText(value.substring(start, end), 64);
    if (normalized.isNotEmpty) {
      classes.add(normalized);
      // The protocol limit counts tokens before deduplication.
      accepted++;
    }
    if (separator < 0) break;
    start = separator + 1;
  }
  return classes;
}
