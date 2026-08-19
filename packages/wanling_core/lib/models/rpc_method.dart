/// RPC 方法条目(对应 server GET /api/agents/:id/rpc-methods 返回的 model.RpcMethod)。
/// capability 协商后,APP 据此渲染命令面板 / 设置默认超时。
/// fromJson 容错(server 缺 timeout_hint_ms 字段时回退 0,避免老 server 崩 client)。
class RpcMethod {
  final String name;
  final int timeoutHintMs;

  const RpcMethod({
    required this.name,
    required this.timeoutHintMs,
  });

  factory RpcMethod.fromJson(Map<String, dynamic> json) {
    return RpcMethod(
      name: json['name'] as String? ?? '',
      timeoutHintMs: (json['timeout_hint_ms'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'timeout_hint_ms': timeoutHintMs,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RpcMethod &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          timeoutHintMs == other.timeoutHintMs;

  @override
  int get hashCode => Object.hash(name, timeoutHintMs);
}
