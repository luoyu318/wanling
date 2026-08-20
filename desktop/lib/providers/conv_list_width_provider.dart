import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 会话列表卡片宽度:ResizeHandle 拖拽驱动,clamp 200-400,持久化
/// SharedPreferences(key desktop.convListWidth),恢复失败/越界回退默认 280。
class ConvListWidthNotifier extends StateNotifier<double> {
  ConvListWidthNotifier() : super(defaultWidth) {
    _restore();
  }

  static const double defaultWidth = 280;
  static const double minWidth = 200;
  static const double maxWidth = 400;
  static const _key = 'desktop.convListWidth';

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getDouble(_key);
      if (v != null && v >= minWidth && v <= maxWidth) {
        state = v;
      }
    } catch (_) {
      // 读失败保持默认,不阻启动
    }
  }

  void setWidth(double w) {
    final clamped = w.clamp(minWidth, maxWidth).toDouble();
    if (clamped == state) return;
    state = clamped;
    SharedPreferences.getInstance().then((p) => p.setDouble(_key, clamped));
  }
}

final convListWidthProvider =
    StateNotifierProvider<ConvListWidthNotifier, double>(
      (ref) => ConvListWidthNotifier(),
    );
