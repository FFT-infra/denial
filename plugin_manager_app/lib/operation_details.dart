import 'package:flutter/material.dart';

import 'backend.dart';
import 'job_feedback.dart';

/// A readable failure first; diagnostics and the operation log are separate.
class OperationDetailsDialog extends StatefulWidget {
  const OperationDetailsDialog({
    required this.error,
    required this.backend,
    this.jobId,
    super.key,
  });
  final String error;
  final PluginBackend backend;
  final String? jobId;
  @override
  State<OperationDetailsDialog> createState() => _OperationDetailsDialogState();
}

class _OperationDetailsDialogState extends State<OperationDetailsDialog> {
  String? log;
  String? logError;
  bool loading = false;
  Future<void> loadLog(bool expanded) async {
    if (!expanded || log != null || loading) return;
    if (widget.jobId == null) {
      setState(() => log = legacyBuildLog(widget.error));
      return;
    }
    setState(() => loading = true);
    try {
      final result = object(
        await widget.backend.invoke(['job-details', widget.jobId!]),
      );
      if (mounted) {
        setState(() {
          log = result['log'] as String? ?? '';
          logError = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => logError = 'The build log could not be loaded.');
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cause = failureCause(widget.error);
    return AlertDialog(
      icon: Icon(
        Icons.error_outline_rounded,
        color: Theme.of(context).colorScheme.error,
      ),
      title: const Text('Change couldn’t be completed'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(failureSummary(cause)),
              const SizedBox(height: 16),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Technical details'),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      cause,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Build log'),
                onExpansionChanged: loadLog,
                children: [
                  if (loading)
                    const LinearProgressIndicator()
                  else
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        logError ??
                            (log?.trim().isNotEmpty == true
                                ? log!
                                : 'No build output was recorded.'),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(fontFamily: 'monospace'),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
