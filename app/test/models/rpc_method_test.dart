import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/rpc_method.dart';

void main() {
  group('RpcMethod', () {
    test('fromJson 解析 snake_case 字段', () {
      final json = {
        'name': 'echo',
        'timeout_hint_ms': 3000,
      };

      final m = RpcMethod.fromJson(json);

      expect(m.name, 'echo');
      expect(m.timeoutHintMs, 3000);
    });

    test('toJson 往返一致', () {
      const m = RpcMethod(name: 'file.read', timeoutHintMs: 5000);
      final json = m.toJson();

      expect(json['name'], 'file.read');
      expect(json['timeout_hint_ms'], 5000);
    });

    test('fromJson 缺 timeout_hint_ms 字段时防御为 0', () {
      final json = {'name': 'unknown'};

      final m = RpcMethod.fromJson(json);

      expect(m.name, 'unknown');
      expect(m.timeoutHintMs, 0);
    });

    test('props 用于 equatable 比较', () {
      const a = RpcMethod(name: 'echo', timeoutHintMs: 3000);
      const b = RpcMethod(name: 'echo', timeoutHintMs: 3000);

      expect(a, equals(b));
    });
  });
}
