import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:wanling_core/models/agent_mode.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/providers/chat_state.dart' show ModelOverride;

/// agent_session 消息列表上方的副标题条(移植自 app 壳,适配深浅主题):
/// 「mode icon + Build · model icon + glm-5.2 zhipuai · max」
/// mode 段支持点击切换 Build↔Plan, model 段支持点击换模型。
///
/// mode 渲染清单驱动:[modes] 为 plugin 上报的模式清单,命中时取
/// label/style 档位;未命中/空清单回退既有 'plan' 特例(老插件兼容期)。
/// StatefulWidget 持有 TapGestureRecognizer,在 dispose 时释放。
class SessionMetaStrip extends StatefulWidget {
  final SessionMeta meta;
  final String? modeOverride;
  /// plugin 上报的模式清单(空 = 未上报,走回退渲染)。
  final List<AgentMode> modes;
  final VoidCallback? onModeTap;
  final ModelOverride? modelOverride;
  final VoidCallback? onModelTap;

  const SessionMetaStrip({
    super.key,
    required this.meta,
    this.modeOverride,
    this.modes = const [],
    this.onModeTap,
    this.modelOverride,
    this.onModelTap,
  });

  @override
  State<SessionMetaStrip> createState() => _SessionMetaStripState();
}

class _SessionMetaStripState extends State<SessionMetaStrip> {
  TapGestureRecognizer? _modeTapRecognizer;
  TapGestureRecognizer? _modelTapRecognizer;

  @override
  void didUpdateWidget(covariant SessionMetaStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    _modeTapRecognizer?.onTap = widget.onModeTap;
    _modelTapRecognizer?.onTap = widget.onModelTap;
  }

  @override
  void dispose() {
    _modeTapRecognizer?.dispose();
    _modelTapRecognizer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.meta;
    final scheme = Theme.of(context).colorScheme;
    final sepStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: scheme.onSurface,
    );
    final baseStyle = TextStyle(fontSize: 12, color: scheme.onSurface);
    final dimStyle = TextStyle(
      fontSize: 12,
      color: scheme.onSurface.withValues(alpha: 0.5),
    );

    final children = <InlineSpan>[];

    if (m.mode.isNotEmpty) {
      final effectiveMode = widget.modeOverride ?? m.mode;
      // 清单驱动:命中取 label + style 档位;未命中回退 id 首字母大写
      // + 'build 蓝其余橙' 既有特例(老插件兼容期)。
      final hit = findModeById(widget.modes, effectiveMode);
      final displayMode = hit?.label ??
          (effectiveMode[0].toUpperCase() + effectiveMode.substring(1));
      final modeColor = hit != null
          ? switch (hit.style.visualStyle) {
              AgentModeVisualStyle.plan => const Color(0xFFF4A742),
              AgentModeVisualStyle.warn => const Color(0xFFE5484D),
              AgentModeVisualStyle.brand => const Color(0xFF597BFF),
            }
          : (effectiveMode.toLowerCase() == 'build'
              ? const Color(0xFF597BFF)
              : const Color(0xFFF4A742));
      final isBuild = effectiveMode.toLowerCase() == 'build';

      if (widget.onModeTap != null) {
        _modeTapRecognizer ??= TapGestureRecognizer();
        _modeTapRecognizer!.onTap = widget.onModeTap;
      }

      children.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: GestureDetector(
          onTap: widget.onModeTap,
          child: Icon(Icons.sync, size: 14, color: modeColor),
        ),
      ));
      children.add(TextSpan(text: ' ', style: baseStyle.copyWith(color: modeColor)));
      children.add(TextSpan(
        text: displayMode,
        style: baseStyle.copyWith(
          color: modeColor,
          fontWeight: isBuild ? FontWeight.w400 : FontWeight.w500,
        ),
        recognizer: _modeTapRecognizer,
      ));
    }

    final mo = widget.modelOverride;
    if (mo != null || m.modelId.isNotEmpty) {
      if (children.isNotEmpty) {
        children.add(TextSpan(text: ' · ', style: sepStyle));
      }
      final displayModelName = mo != null
          ? (mo.modelName ?? mo.modelID)
          : (m.modelName ?? m.modelId);

      if (widget.onModelTap != null) {
        _modelTapRecognizer ??= TapGestureRecognizer();
        _modelTapRecognizer!.onTap = widget.onModelTap;
      }

      children.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: GestureDetector(
          onTap: widget.onModelTap,
          child: Icon(
            Icons.unfold_more,
            size: 14,
            color: scheme.onSurface,
          ),
        ),
      ));
      children.add(TextSpan(text: ' ', style: baseStyle));
      children.add(TextSpan(
        text: displayModelName,
        style: baseStyle.copyWith(fontWeight: FontWeight.w400),
        recognizer: _modelTapRecognizer,
      ));
      final providerDisplay = mo != null
          ? mo.providerName
          : (m.providerName ?? _formatProvider(m.providerId));
      if (providerDisplay != null && providerDisplay.isNotEmpty) {
        children.add(TextSpan(
          text: ' $providerDisplay',
          style: dimStyle.copyWith(fontWeight: FontWeight.w400),
        ));
      }
    } else if (widget.onModelTap != null) {
      // fallback 入口:modelId 空 + modelOverride null + onModelTap 非空。
      // 场景:新建 agent_session 会话,plugin lazy 建模前 model_id 一直空。
      // 显式渲染「默认模型」入口,让用户能点击选 model。不点 → sendText
      // 不带 _model,OC 用自己默认(语义正确)。
      if (children.isNotEmpty) {
        children.add(TextSpan(text: ' · ', style: sepStyle));
      }
      _modelTapRecognizer ??= TapGestureRecognizer();
      _modelTapRecognizer!.onTap = widget.onModelTap;
      children.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: GestureDetector(
          onTap: widget.onModelTap,
          child: Icon(
            Icons.unfold_more,
            size: 14,
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ));
      children.add(TextSpan(text: ' ', style: dimStyle));
      children.add(TextSpan(
        text: '默认模型',
        style: dimStyle.copyWith(fontWeight: FontWeight.w400),
        recognizer: _modelTapRecognizer,
      ));
    }

    if (m.variant != null &&
        m.variant!.isNotEmpty &&
        m.variant!.toLowerCase() != 'default') {
      if (children.isNotEmpty) {
        children.add(TextSpan(text: ' · ', style: sepStyle));
      }
      children.add(TextSpan(
        text: m.variant,
        style: baseStyle.copyWith(
          color: const Color(0xFFF4A742),
          fontWeight: FontWeight.w500,
        ),
      ));
    }

    // 横向超出屏幕时水平滑动查看,不显示滚动条。
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Text.rich(
        TextSpan(children: children),
        maxLines: 1,
      ),
    );
  }
}

/// providerId 格式化：zhipuai-coding-plan → Zhipuai Coding Plan
String _formatProvider(String raw) {
  return raw
      .split('-')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}
