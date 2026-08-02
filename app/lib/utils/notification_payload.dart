import 'dart:convert' show jsonDecode, jsonEncode;

import '../models/msg_type.dart';

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
/// 薄封装:调 [MsgTypeX.preview] 单一真相源,null fallback `[新消息]`(通知不允许空 body)。
/// 保留独立函数签名便于 bg-service 直接以 String msgType 调用,不需先转枚举。
String messagePreview({
  required String msgType,
  required Map<String, dynamic>? data,
}) {
  return MsgTypeX.preview(MsgTypeX.fromString(msgType), data) ?? '[新消息]';
}
