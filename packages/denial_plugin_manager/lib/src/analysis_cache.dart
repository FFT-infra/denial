import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
// The public factory always creates a fresh MemoryByteStore. Keep the narrow
// internal-API adapter here and exercise it with the lock-matched analyzer.
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';

/// Analyzer keys include source/dependency signatures, language options and
/// serialization salts. Its file store validates checksums and publishes via
/// rename; missing/corrupt entries are misses, never permission to skip analysis.
AnalysisContextCollection pluginAnalysisContexts({
  required String applicationRoot,
  String? sdkPath,
  String? cacheDirectory,
}) {
  if (cacheDirectory != null) {
    try {
      Directory(cacheDirectory).createSync(recursive: true);
      return AnalysisContextCollectionImpl(
        includedPaths: [applicationRoot],
        sdkPath: sdkPath,
        byteStore: FileByteStore(cacheDirectory),
      );
    } on FileSystemException {
      // An unavailable acceleration cache must not block valid plugin work.
    }
  }
  return AnalysisContextCollection(
    includedPaths: [applicationRoot],
    sdkPath: sdkPath,
  );
}
