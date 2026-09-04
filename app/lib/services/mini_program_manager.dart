import 'package:flutter/foundation.dart';

/// 一个保活中的小程序实例(纯状态,WebView 由 Host 层持有)。
class MiniProgramInstance {
  MiniProgramInstance({required this.appid, required this.openedAt});

  final String appid;
  final DateTime openedAt;
  DateTime lastForegroundAt = DateTime.now();

  /// 展示元信息(浮球/多任务视图用),打开时若调用方提供则更新。
  String name = '';
  String iconUrl = '';
}

/// 小程序保活管理器:多实例 + 前台切换 + LRU 上限。
/// 只管状态;路由同步(live 壳)由 [mini_program_launcher] 负责。
class MiniProgramManager extends ChangeNotifier {
  static const int maxInstances = 5;

  final Map<String, MiniProgramInstance> _instances = {};
  String? _foregroundAppid;

  Map<String, MiniProgramInstance> get instances =>
      Map.unmodifiable(_instances);
  String? get foregroundAppid => _foregroundAppid;
  bool get hasForeground => _foregroundAppid != null;
  MiniProgramInstance? get foreground => _instances[_foregroundAppid];

  /// 按打开时间倒序(最近打开在前)。
  List<MiniProgramInstance> get list {
    final l = _instances.values.toList()
      ..sort((a, b) => b.openedAt.compareTo(a.openedAt));
    return l;
  }

  /// 打开(或恢复)并置前台。超上限时按 lastForegroundAt 淘汰最久未前台者,
  /// 返回被淘汰的 appid(无淘汰返回 null)。
  String? open(String appid, {String name = '', String iconUrl = ''}) {
    assert(appid.isNotEmpty);
    String? evicted;
    if (!_instances.containsKey(appid) && _instances.length >= maxInstances) {
      MiniProgramInstance? oldest;
      for (final i in _instances.values) {
        if (oldest == null ||
            i.lastForegroundAt.isBefore(oldest.lastForegroundAt)) {
          oldest = i;
        }
      }
      evicted = oldest!.appid;
      _instances.remove(evicted);
    }
    final inst = _instances.putIfAbsent(
        appid, () => MiniProgramInstance(appid: appid, openedAt: DateTime.now()));
    if (name.isNotEmpty) inst.name = name;
    if (iconUrl.isNotEmpty) inst.iconUrl = iconUrl;
    _foregroundAppid = appid;
    inst.lastForegroundAt = DateTime.now();
    notifyListeners();
    return evicted;
  }

  /// 前台置空,实例保留(保活)。
  void minimize() {
    _foregroundAppid = null;
    notifyListeners();
  }

  void restore(String appid) {
    final inst = _instances[appid];
    if (inst == null) return;
    _foregroundAppid = appid;
    inst.lastForegroundAt = DateTime.now();
    notifyListeners();
  }

  /// 销毁实例;关的是前台则前台清空。
  void close(String appid) {
    _instances.remove(appid);
    if (_foregroundAppid == appid) _foregroundAppid = null;
    notifyListeners();
  }
}
