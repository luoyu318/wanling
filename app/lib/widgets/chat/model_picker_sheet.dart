import 'package:flutter/material.dart';

import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/conversation.dart' show SessionMeta;
import 'package:wanling_core/providers/chat_state.dart' show ModelOverride;

/// 模型选择弹出框（紧凑列表 + 搜索 + provider 过滤 pill）。
/// 列表按 provider 分段，radio 选中标记，搜索同时匹配 name 和 id。
class ModelPickerDialog extends StatefulWidget {
  final List<AgentModel> models;
  final ModelOverride? currentOverride;
  final SessionMeta? currentSessionMeta;

  const ModelPickerDialog({
    super.key,
    required this.models,
    this.currentOverride,
    this.currentSessionMeta,
  });

  static Future<ModelOverride?> show({
    required BuildContext context,
    required List<AgentModel> models,
    ModelOverride? currentOverride,
    SessionMeta? currentSessionMeta,
  }) {
    return showDialog<ModelOverride>(
      context: context,
      builder: (_) => ModelPickerDialog(
        models: models,
        currentOverride: currentOverride,
        currentSessionMeta: currentSessionMeta,
      ),
    );
  }

  @override
  State<ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<ModelPickerDialog> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String? _filterProvider; // null = 全部

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<AgentModel>>{};
    for (final m in widget.models) {
      final key = m.providerName.isEmpty ? m.providerId : m.providerName;
      groups.putIfAbsent(key, () => []).add(m);
    }
    final allProviderNames = groups.keys.toList();

    final currentModelId =
        widget.currentOverride?.modelID ?? widget.currentSessionMeta?.modelId ?? '';
    final currentProviderId =
        widget.currentOverride?.providerID ?? widget.currentSessionMeta?.providerId ?? '';

    // 过滤
    final filteredGroups = <String, List<AgentModel>>{};
    for (final entry in groups.entries) {
      if (_filterProvider != null && entry.key != _filterProvider) continue;
      if (_query.isEmpty) {
        filteredGroups[entry.key] = entry.value;
      } else {
        final matched = entry.value.where((m) =>
            m.modelId.toLowerCase().contains(_query) ||
            (m.modelName.isNotEmpty && m.modelName.toLowerCase().contains(_query))).toList();
        if (matched.isNotEmpty) filteredGroups[entry.key] = matched;
      }
    }

    final filteredNames = filteredGroups.keys.toList();

    if (widget.models.isEmpty) {
      return Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: const Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '选择模型',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFF111111)),
              ),
              SizedBox(height: 16),
              Text(
                '暂无可选模型',
                style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
              ),
            ],
          ),
        ),
      );
    }

    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '选择模型',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111111),
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 28, height: 28,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF2F2F2), shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close, size: 16, color: Color(0xFF999999)),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(fontSize: 14, color: Color(0xFF111111)),
                decoration: InputDecoration(
                  hintText: '搜索模型名称…',
                  hintStyle: const TextStyle(fontSize: 14, color: Color(0xFFBBBBBB)),
                  prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFFBBBBBB)),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 9),
                  filled: true,
                  fillColor: const Color(0xFFF8F8F8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _buildFilterPill('全部', null),
                  for (final name in allProviderNames)
                    _buildFilterPill(name, name),
                ],
              ),
            ),
            const Divider(height: 16, indent: 20, endIndent: 20),
            if (filteredNames.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    '无匹配模型',
                    style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
                  ),
                ),
              )
            else
              Flexible(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final name in filteredNames) ...[
                      _ProviderHeader(providerName: name),
                      for (final m in filteredGroups[name]!)
                        _ModelRow(
                          model: m,
                          selected: m.modelId == currentModelId &&
                              m.providerId == currentProviderId,
                        ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterPill(String label, String? value) {
    final active = _filterProvider == value;
    return GestureDetector(
      onTap: () => setState(() => _filterProvider = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF111111) : const Color(0xFFF2F2F2),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: active ? Colors.white : const Color(0xFF666666),
          ),
        ),
      ),
    );
  }
}

class _ProviderHeader extends StatelessWidget {
  final String providerName;
  const _ProviderHeader({required this.providerName});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
      child: Row(
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(
              color: const Color(0xFF597BFF),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            providerName.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF999999),
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  final AgentModel model;
  final bool selected;

  const _ModelRow({required this.model, required this.selected});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).pop(ModelOverride(
        providerID: model.providerId,
        modelID: model.modelId,
        modelName: model.modelName.isEmpty ? null : model.modelName,
        providerName: model.providerName.isEmpty ? null : model.providerName,
      )),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            SizedBox(
              width: 18, height: 18,
              child: selected
                  ? _CheckedRadio()
                  : const Icon(Icons.radio_button_unchecked,
                      size: 18, color: Color(0xFFDDDDDD)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            model.modelName.isEmpty ? model.modelId : model.modelName,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                              color: Color(0xFF111111),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (selected)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEEF1FF),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: const Text(
                              '当前',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF597BFF),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      model.modelId,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckedRadio extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18, height: 18,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFF597BFF),
      ),
      child: const Center(
        child: Icon(Icons.check, size: 11, color: Colors.white),
      ),
    );
  }
}
