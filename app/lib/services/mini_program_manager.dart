import 'package:flutter/foundation.dart';

import 'package:wanling_core/models/mini_program_info.dart';

/// 一个保活中的小程序实例(纯状态,WebView 由 Host 层持有)。
class MiniProgramInstance {
  MiniProgramInstance({required this.appid, required this.openedAt});

  final String appid;
  final DateTime openedAt;
  DateTime lastForegroundAt = DateTime.now();

  /// 展示元信息(浮球/多任务视图用),打开时若调用方提供则更新。
  String name = '';
  String iconUrl = '';

  /// 来源会话(getChatContext 返回 conversation_id;I2 恢复 M2 契约)。
  String? conversationId;

  /// 卡片 launch 参数(已解码 params JSON,透传入口 URL query)。
  String? launchParams;

  /// 最小化前抓取的 WebView 真实帧(任务视图卡片显示用,增强非关键路径)。
  /// 只在后台态有意义:恢复前台即清空(前台实时渲染)。
  Uint8List? snapshot;
}

/// 实例展示元数据解析(纯函数,任务视图/浮球/面板统一走它):
/// 打开瞬间的快照 name/iconUrl 常为空(面板路径只传 appid),此时回退查
/// [programs](miniProgramsProvider 注册列表)取最新 name 与 iconUrlFor(baseUrl)
/// 拼接的完整 URL;provider 也无该 appid 时再回退快照/appid(首字母色块)。
({String name, String iconUrl}) resolveInstanceMeta(
  MiniProgramInstance inst,
  List<MiniProgramInfo> programs,
  String baseUrl,
) {
  MiniProgramInfo? mp;
  for (final m in programs) {
    if (m.appid == inst.appid) {
      mp = m;
      break;
    }
  }
  final name = inst.name.isNotEmpty ? inst.name : (mp?.name ?? inst.appid);
  final iconUrl = inst.iconUrl.isNotEmpty
      ? inst.iconUrl
      : (mp?.iconUrlFor(baseUrl) ?? '');
  return (name: name, iconUrl: iconUrl);
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
  ///
  /// [conversationId]/[launchParams]:入口元数据(I2)。重复打开且新参数
  /// 非空且与现值不同 → 销毁重建实例(卡片语境正确性优先;重建丢 JS 状态
  /// 是可接受代价,Host 按 openedAt 键控,WebView 整棵换新带上新参数)。
  String? open(
    String appid, {
    String name = '',
    String iconUrl = '',
    String? conversationId,
    String? launchParams,
  }) {
    assert(appid.isNotEmpty);
    String? evicted;
    final existing = _instances[appid];
    // 参数变化检测:提供(null=未提供不参与)且非空且与现值不同即重建
    final paramsChanged = existing != null &&
        ((conversationId != null &&
                conversationId.isNotEmpty &&
                conversationId != existing.conversationId) ||
            (launchParams != null &&
                launchParams.isNotEmpty &&
                launchParams != existing.launchParams));
    if (paramsChanged) {
      _instances.remove(appid);
    }
    if (!_instances.containsKey(appid) && _instances.length >= maxInstances) {
      MiniProgramInstance? oldest;
      for (final i in _instances.values) {
        if (oldest == null ||
            i.lastForegroundAt.isBefore(oldest.lastForegroundAt)) {
          oldest = i;
        }
      }
      evicted = oldest!.appid;
      oldest.snapshot = null; // 淘汰即断帧引用
      _instances.remove(evicted);
    }
    final inst = _instances.putIfAbsent(
        appid, () => MiniProgramInstance(appid: appid, openedAt: DateTime.now()));
    if (name.isNotEmpty) inst.name = name;
    if (iconUrl.isNotEmpty) inst.iconUrl = iconUrl;
    if (conversationId != null) inst.conversationId = conversationId;
    if (launchParams != null) inst.launchParams = launchParams;
    _foregroundAppid = appid;
    inst.lastForegroundAt = DateTime.now();
    notifyListeners();
    return evicted;
  }

  /// 写入实例快照帧(最小化前抓取)。实例已不存在(抓帧期间被关闭的竞态)时
  /// 静默丢弃:快照是增强非关键路径,不重建实例。[bytes] 传 null 即清空回退占位。
  void updateSnapshot(String appid, Uint8List? bytes) {
    final inst = _instances[appid];
    if (inst == null) return;
    inst.snapshot = bytes;
    notifyListeners();
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
    // 前台实时渲染,快照只在后台态有意义:置前台即释放旧帧
    inst.snapshot = null;
    notifyListeners();
  }

  /// 销毁实例;关的是前台则前台清空。
  void close(String appid) {
    // 先断帧引用再移除:实例对象若被外部临时持有,字节也尽早可回收
    _instances[appid]?.snapshot = null;
    _instances.remove(appid);
    if (_foregroundAppid == appid) _foregroundAppid = null;
    notifyListeners();
  }

  /// 清空全部实例 + 前台(登出/切账号):WebView 随实例视图卸载销毁,
  /// JS 状态/登录态内存一并丢弃,防旧账号实例恢复或 WebView 盖住登录页。
  /// 已空时 no-op 不通知(幂等,防登出风暴下的空重建)。
  void closeAll() {
    if (_instances.isEmpty && _foregroundAppid == null) return;
    for (final inst in _instances.values) {
      inst.snapshot = null;
    }
    _instances.clear();
    _foregroundAppid = null;
    notifyListeners();
  }
}
