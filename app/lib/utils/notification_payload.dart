import 'dart:convert' show jsonDecode, jsonEncode;

/// 通知 payload：携带会话/agent 信息用于点击路由。
/// flutter_local_notifications 的 payload 是 String，
/// 用 JSON 序列化后传入，点击时反序列化。
class NotificationPayload {
  final String convId;
  final String agentId;
  final String agentName;

  const NotificationPayload({
    required this.convId,
    required this.agentId,
    required this.agentName,
  });

  Map<String, dynamic> toJson() => {
        'convId': convId,
        'agentId': agentId,
        'agentName': agentName,
      };

  factory NotificationPayload.fromJson(Map<String, dynamic> json) {
    final convId = json['convId'] as String?;
    final agentId = json['agentId'] as String?;
    final agentName = json['agentName'] as String?;
    if (convId == null || agentId == null || agentName == null) {
      throw FormatException('payload 缺字段: $json');
    }
    return NotificationPayload(
      convId: convId,
      agentId: agentId,
      agentName: agentName,
    );
  }

  /// 从字符串 payload 反序列化（flutter_local_notifications 传 string）。
  /// 非法 JSON / 缺字段返回 null（容错，不抛异常）。
  static NotificationPayload? fromJsonString(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final jsonMap = jsonDecode(s) as Map<String, dynamic>;
      return NotificationPayload.fromJson(jsonMap);
    } catch (_) {
      return null;
    }
  }

  String toJsonString() => jsonEncode(toJson());
}

/// 按消息类型生成通知正文预览。
/// - text/markdown：取 data.text 前 50 字符
/// - image：「[图片]」
/// - file：「[文件] 文件名」或「[文件]」
/// - 其他：「[新消息]」
String messagePreview({
  required String msgType,
  required Map<String, dynamic>? data,
}) {
  if (data == null) return '[新消息]';
  switch (msgType) {
    case 'text':
    case 'markdown':
      final text = data['text'] as String? ?? '';
      return text.length > 50 ? text.substring(0, 50) : text;
    case 'image':
      return '[图片]';
    case 'file':
      final filename = data['filename'] as String? ?? '';
      return filename.isEmpty ? '[文件]' : '[文件] $filename';
    default:
      return '[新消息]';
  }
}
