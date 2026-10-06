import 'package:flutter/material.dart';

import 'backend.dart';
import 'controller.dart';
import 'presentation.dart';

class RepositoryDialog extends StatefulWidget {
  const RepositoryDialog({required this.controller, super.key});
  final ManagerController controller;
  @override
  State<RepositoryDialog> createState() => _RepositoryDialogState();
}

class _RepositoryDialogState extends State<RepositoryDialog> {
  final url = TextEditingController();
  final ref = TextEditingController();
  List<Map<String, Object?>> candidates = [];
  String? selected;
  String? error;
  bool loading = false;
  bool local = false;
  @override
  void dispose() {
    url.dispose();
    ref.dispose();
    super.dispose();
  }

  Future<void> inspect() async {
    setState(() {
      loading = true;
      error = null;
      candidates = [];
      selected = null;
    });
    try {
      final result = await widget.controller.backend.invoke([
        'inspect',
        url.text.trim(),
        if (local) '--local',
        if (ref.text.trim().isNotEmpty) ...['--ref', ref.text.trim()],
      ]);
      if (!mounted) return;
      setState(() {
        candidates = objects(result);
        selected = candidates.length == 1
            ? candidates.single['path']! as String
            : null;
        if (candidates.isEmpty) {
          error = 'No plugin package candidates were found in this repository.';
        }
      });
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.add_link_rounded),
    title: const Text('Bring something new.'),
    scrollable: true,
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste a repository link to find its plugins. Plugins become part of your desktop, so choose code you trust.',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: url,
              autofocus: true,
              enabled: !loading,
              decoration: InputDecoration(
                labelText: local
                    ? 'Local package or repository directory'
                    : 'Repository link',
              ),
              onChanged: (_) => setState(() {
                selected = null;
                candidates = [];
              }),
            ),
            const SizedBox(height: 12),
            if (!local)
              ExpansionTile(
                title: const Text('Advanced options'),
                tilePadding: EdgeInsets.zero,
                children: [
                  TextField(
                    controller: ref,
                    enabled: !loading,
                    decoration: const InputDecoration(
                      labelText: 'Branch, tag, or commit (optional)',
                    ),
                    onChanged: (_) => setState(() {
                      selected = null;
                      candidates = [];
                    }),
                  ),
                ],
              ),
            ExpansionTile(
              title: const Text('Local development'),
              tilePadding: EdgeInsets.zero,
              children: [
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use a local development checkout'),
                  value: local,
                  onChanged: loading
                      ? null
                      : (value) => setState(() {
                          local = value!;
                          candidates = [];
                          selected = null;
                        }),
                ),
              ],
            ),
            if (loading) const LinearProgressIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SelectableText(error!),
              ),
            if (candidates.isNotEmpty) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: selected,
                decoration: const InputDecoration(labelText: 'Choose a plugin'),
                isExpanded: true,
                items: [
                  for (final item in candidates)
                    DropdownMenuItem(
                      value: item['path']! as String,
                      child: Text(
                        '${pluginTitle(item['name']! as String)} · ${item['path']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => selected = value),
              ),
              const SizedBox(height: 12),
              const Text(
                'We’ll include anything this plugin needs automatically.',
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      if (candidates.isEmpty)
        FilledButton(
          onPressed: loading || url.text.trim().isEmpty ? null : inspect,
          child: Text(loading ? 'Finding plugins…' : 'Find plugins'),
        ),
      if (candidates.isNotEmpty)
        FilledButton(
          onPressed: selected == null || loading
              ? null
              : () {
                  final candidate = candidates.firstWhere(
                    (item) => item['path'] == selected,
                  );
                  widget.controller.enable({
                    ...candidate,
                    'source': {
                      'kind': local ? 'local' : 'git',
                      'location': url.text.trim(),
                      'path': selected!,
                      if (!local && ref.text.trim().isNotEmpty)
                        'ref': ref.text.trim(),
                    },
                  });
                  Navigator.pop(context);
                },
          child: const Text('Add plugin'),
        ),
    ],
  );
}

class ConfigurationDialog extends StatelessWidget {
  const ConfigurationDialog({required this.controller, super.key});
  final ManagerController controller;

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.extension_outlined),
    title: const Text('Your plugins'),
    content: const SizedBox(
      width: 440,
      child: Text(
        'Choose plugins from your library, then apply your changes together. '
        'Denial takes care of preparing everything your desktop needs.\n\n'
        'You can also add plugins using a repository link. '
        'Previous working desktops remain available in the desktop menu.',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ],
  );
}
