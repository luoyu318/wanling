import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;

typedef DirectoryPickerResult = ({String? directory, bool cancelled});

Future<DirectoryPickerResult?> showDirectoryPickerSheet(
  BuildContext context, {
  required String agentId,
  String? defaultDirectory,
}) {
  return showModalBottomSheet<DirectoryPickerResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (_) => DirectoryPickerSheet(
      agentId: agentId,
      defaultDirectory: defaultDirectory,
    ),
  );
}

class DirectoryPickerSheet extends ConsumerStatefulWidget {
  final String agentId;
  final String? defaultDirectory;

  const DirectoryPickerSheet({
    super.key,
    required this.agentId,
    this.defaultDirectory,
  });

  @override
  ConsumerState<DirectoryPickerSheet> createState() =>
      _DirectoryPickerSheetState();
}

class _DirectoryPickerSheetState extends ConsumerState<DirectoryPickerSheet> {
  List<({String path, String name})>? _projects;
  String? _error;
  late String? _selectedPath;

  @override
  void initState() {
    super.initState();
    _selectedPath = widget.defaultDirectory;
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    setState(() {
      _error = null;
      _projects = null;
    });
    try {
      final api = ref.read(apiProvider);
      final result = await api.rpc(
        widget.agentId,
        'project.list',
        const <String, dynamic>{},
      );
      final list = (result['projects'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _projects = list
            .map((p) => (
                  path: (p as Map<String, dynamic>)['path'] as String,
                  name: p['name'] as String,
                ))
            .toList();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    }
  }

  void _return(String? directory, {required bool cancelled}) =>
      Navigator.of(context)
          .pop((directory: directory, cancelled: cancelled));

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text('选择工作目录',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                const Spacer(),
                GestureDetector(
                  onTap: () => _return(null, cancelled: true),
                  child: const Icon(Icons.close, size: 22),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_error != null) ...[
              Text('加载失败: $_error',
                  style: const TextStyle(color: Colors.red, fontSize: 13)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _loadProjects,
                  child: const Text('重试'),
                ),
              ),
            ] else if (_projects == null) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ] else if (_projects!.isEmpty) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('暂无项目',
                    style: TextStyle(color: Color(0xFF999999), fontSize: 13)),
              ),
            ] else ...[
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _projects!.length,
                  itemBuilder: (_, i) {
                    final p = _projects![i];
                    return _ProjectCard(
                      name: p.name,
                      path: p.path,
                      isSelected: _selectedPath == p.path,
                      onTap: () => setState(() => _selectedPath = p.path),
                    );
                  },
                ),
              ),
            ],
            const Divider(),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => _return(null, cancelled: false),
                    child: const Text('不选(用默认)'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _selectedPath == null
                        ? null
                        : () => _return(_selectedPath, cancelled: false),
                    child: const Text('确认'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  final String name;
  final String path;
  final bool isSelected;
  final VoidCallback onTap;

  const _ProjectCard({
    required this.name,
    required this.path,
    required this.onTap,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isSelected
            ? const Color(0xFFE8F0FE)
            : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: isSelected
                  ? const Border(
                      right:
                          BorderSide(color: Color(0xFF007AFF), width: 3),
                    )
                  : null,
            ),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(path,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF999999))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
