import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/providers/chat_state.dart' show ModelOverride;

/// agent_session 输入栏下方的副标题条:
/// 「mode icon + Build · model icon + glm-5.2 zhipuai · max」
/// mode 段支持点击切换 Build↔Plan, model 段支持点击换模型。
///
/// StatefulWidget 持有 TapGestureRecognizer,在 dispose 时释放。
class SessionMetaStrip extends StatefulWidget {
  final SessionMeta meta;
  final String? modeOverride;
  final VoidCallback? onModeTap;
  final ModelOverride? modelOverride;
  final VoidCallback? onModelTap;

  const SessionMetaStrip({
    super.key,
    required this.meta,
    this.modeOverride,
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
    const sep = ' · ';
    const sepStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: Color(0xFF000000),
    );
    const baseStyle = TextStyle(fontSize: 12);

    final children = <InlineSpan>[];

    if (m.mode.isNotEmpty) {
      final effectiveMode = widget.modeOverride ?? m.mode;
      final isBuild = effectiveMode.toLowerCase() == 'build';
      final modeColor =
          isBuild ? const Color(0xFF597BFF) : const Color(0xFFF4A742);

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
      children.add(TextSpan(
        text: ' ',
        style: baseStyle.copyWith(color: modeColor),
      ));
      children.add(TextSpan(
        text: effectiveMode[0].toUpperCase() + effectiveMode.substring(1),
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
        children.add(const TextSpan(text: sep, style: sepStyle));
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
          child: Icon(Icons.unfold_more, size: 14, color: const Color(0xFF000000)),
        ),
      ));
      children.add(TextSpan(
        text: ' ',
        style: baseStyle.copyWith(color: const Color(0xFF000000)),
      ));
      children.add(TextSpan(
        text: displayModelName,
        style: baseStyle.copyWith(
          color: const Color(0xFF000000),
          fontWeight: FontWeight.w400,
        ),
        recognizer: _modelTapRecognizer,
      ));
      final providerDisplay = mo != null
          ? mo.providerName
          : (m.providerName ?? _formatProvider(m.providerId));
      if (providerDisplay != null && providerDisplay.isNotEmpty) {
        children.add(TextSpan(
          text: ' $providerDisplay',
          style: baseStyle.copyWith(
            color: const Color(0xFF999999),
            fontWeight: FontWeight.w400,
          ),
        ));
      }
    } else if (widget.onModelTap != null) {
      // fallback 入口:modelId 空 + modelOverride null + onModelTap 非空。
      // 场景:新建 agent_session 会话,plugin lazy 建模前 model_id 一直空。
      // 显式渲染「默认模型」入口,让用户能点击选 model(走 _showModelPicker)。
      // 不点 → sendText 不带 _model,OC 用自己默认(语义正确)。
      if (children.isNotEmpty) {
        children.add(const TextSpan(text: sep, style: sepStyle));
      }
      _modelTapRecognizer ??= TapGestureRecognizer();
      _modelTapRecognizer!.onTap = widget.onModelTap;
      children.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: GestureDetector(
          onTap: widget.onModelTap,
          child: const Icon(Icons.unfold_more, size: 14, color: Color(0xFF999999)),
        ),
      ));
      children.add(TextSpan(
        text: ' ',
        style: baseStyle.copyWith(color: const Color(0xFF999999)),
      ));
      children.add(TextSpan(
        text: '默认模型',
        style: baseStyle.copyWith(
          color: const Color(0xFF999999),
          fontWeight: FontWeight.w400,
        ),
        recognizer: _modelTapRecognizer,
      ));
    }

    if (m.variant != null &&
        m.variant!.isNotEmpty &&
        m.variant!.toLowerCase() != 'default') {
      if (children.isNotEmpty) {
        children.add(const TextSpan(text: sep, style: sepStyle));
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
