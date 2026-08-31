import 'package:flutter/foundation.dart';

/// 小程序 JSBridge 门禁(纯逻辑,WebView 无关,可单测)。
/// 安全基线:
/// - token 不进 JS:所有万灵 API 调用经 proxy 原生代理
/// - 权限 fail fast:manifest 未声明对应权限直接拒绝,不静默降级
/// - 路径白名单:仅放行 /api/ 前缀,归一化后复检,防 /api/../xxx 绕过
class MiniProgramBridge {
  final Set<String> permissions;
  final Future<Object?> Function(String path, String method, Object? body)
      proxy;
  final VoidCallback? onClose;

  MiniProgramBridge({
    required this.permissions,
    required this.proxy,
    this.onClose,
  });

  Future<Object?> handle(String handlerName, List<dynamic> args) async {
    try {
      switch (handlerName) {
        case 'wanlingRequest':
          if (!permissions.contains('wanling.api')) {
            return {'ok': false, 'error': 'permission denied: wanling.api'};
          }
          final opts = (args.isNotEmpty ? args.first : null) as Map?;
          final path = opts?['path'] as String? ?? '';
          if (!path.startsWith('/api/')) {
            return {'ok': false, 'error': '仅允许 /api/ 前缀路径'};
          }
          final normalized = _normalizeApiPath(path);
          if (normalized == null || !normalized.startsWith('/api/')) {
            return {'ok': false, 'error': '路径归一化后越出 /api/ 白名单'};
          }
          final method = opts?['method'] as String? ?? 'GET';
          final body = opts?['body'];
          final data = await proxy(normalized, method, body);
          return {'ok': true, 'data': data};
        case 'wanlingClose':
          onClose?.call();
          return null;
        default:
          return {'ok': false, 'error': 'unknown method: $handlerName'};
      }
    } catch (e) {
      // 仅把错误转成 JS 可读 envelope,不吞栈(原生日志由调用方记)
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// 归一化待请求路径:剥离 query/fragment,对路径段做 URI 解码 + 点段清理
  /// (Uri.parse 解析时即解码 %2e 并消解 . / ..),再拼回原始 query。
  /// 返回 null 表示无法解析(拒绝)。
  static String? _normalizeApiPath(String path) {
    final qIdx = path.indexOf('?');
    final fIdx = path.indexOf('#');
    var cut = path.length;
    if (qIdx >= 0 && qIdx < cut) cut = qIdx;
    if (fIdx >= 0 && fIdx < cut) cut = fIdx;
    final rawPath = path.substring(0, cut);
    final query = qIdx >= 0 && qIdx < path.length ? path.substring(qIdx) : '';
    try {
      final normalized = Uri.parse(rawPath).normalizePath().path;
      return query.isEmpty ? normalized : '$normalized$query';
    } on FormatException {
      return null;
    }
  }
}