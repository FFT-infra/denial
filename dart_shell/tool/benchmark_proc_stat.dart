import 'package:denial_flutter_sdk/src/services/linux_cpu_usage.dart'
    show parseProcStat;

// Compile with the pinned SDK, then run the resulting AOT executable:
// dart compile exe tool/benchmark_proc_stat.dart -o /tmp/proc-stat-bench
// /tmp/proc-stat-bench
import 'dart:io';

import 'package:denial_flutter_sdk/system_services.dart';

int _checksum = 0;
void main() {
  for (final cores in [8, 64, 256]) {
    const counters = '100000 200 30000 4000000 5000 600 7000 800 900 100';
    final content = StringBuffer('cpu  $counters\n');
    for (var core = 0; core < cores; core++) {
      content.writeln('cpu$core $counters');
    }
    content.writeln('intr ${List.filled(1024, '10240').join(' ')}');
    content.writeln('ctxt 1234000\nbtime 1700000000\nprocesses 43210');
    final text = content.toString();
    const count = 20000;
    _measure(_previousParseProcStat, text, count ~/ 10);
    _measure(parseProcStat, text, count ~/ 10);
    final before = <double>[];
    final after = <double>[];
    for (var sample = 0; sample < 7; sample++) {
      if (sample.isEven) {
        before.add(_measure(_previousParseProcStat, text, count));
        after.add(_measure(parseProcStat, text, count));
      } else {
        after.add(_measure(parseProcStat, text, count));
        before.add(_measure(_previousParseProcStat, text, count));
      }
    }
    before.sort();
    after.sort();
    stdout.writeln(
      '$cores cores, ${text.length} characters: ${before[3].toStringAsFixed(1)} -> ${after[3].toStringAsFixed(1)} ns/parse (${(before[3] / after[3]).toStringAsFixed(2)}x)',
    );
  }
  stdout.writeln('checksum=$_checksum');
}

double _measure(CpuSample? Function(String) parse, String input, int count) {
  final clock = Stopwatch()..start();
  for (var index = 0; index < count; index++) {
    final sample = parse(input)!;
    _checksum += sample.busy + sample.total;
  }
  clock.stop();
  return clock.elapsedTicks * 1e9 / clock.frequency / count;
}

// Previous split/filter/map implementation, including ignored trailing rows.
CpuSample? _previousParseProcStat(String content) {
  for (final line in content.split('\n')) {
    if (!line.startsWith('cpu ')) continue;
    final fields = line
        .split(' ')
        .where((field) => field.isNotEmpty)
        .skip(1)
        .map(int.tryParse)
        .toList(growable: false);
    if (fields.length < 8 || fields.any((field) => field == null)) return null;
    final jiffies = fields.take(8).cast<int>().toList(growable: false);
    final total = jiffies.fold<int>(0, (sum, value) => sum + value);
    return CpuSample(busy: total - jiffies[3] - jiffies[4], total: total);
  }
  return null;
}
