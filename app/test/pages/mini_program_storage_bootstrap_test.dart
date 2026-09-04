// 云数据 bootstrap 注入与事件过滤纯函数回归测试(Task 8)。
// bootstrap 源码走 visibleForTesting 别名断言(库私有 const 单测不可见);
// WebView 侧集成(handlers 注册/evaluateJavascript 转发)靠 Task 11 手工验证。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:app/pages/mini_program_page.dart';

void main() {
  group('bootstrap 云数据注入包含性', () {
    test('包含 window.wanling.storage 七方法桥', () {
      const src = jsBridgeBootstrapSource;
      expect(src, contains('window.wanling.storage'));
      for (final m in [
        'wanlingStorageGet',
        'wanlingStorageSet',
        'wanlingStorageRemove',
        'wanlingStorageItems',
        'wanlingStorageQuota',
        'wanlingStorageSubscribe',
        'wanlingStorageUnsubscribe',
      ]) {
        expect(src, contains(m), reason: '缺 $m');
      }
    });

    test('包含事件发射器与监听器注册/off 语义', () {
      const src = jsBridgeBootstrapSource;
      expect(src, contains('_emitMpStorageEvent'));
      expect(src, contains('_mpListeners'));
      // off = indexOf 命中后 splice 移除该监听器
      expect(src, contains('splice'));
    });

    test('注释含事件消费语义:按到达序应用,version 仅丢弃旧 set', () {
      expect(jsBridgeBootstrapSource, contains('按到达序'));
      expect(jsBridgeBootstrapSource, contains('version'));
    });
  });

  group('mpEventFilter 纯函数', () {
    final frame = <String, dynamic>{
      'appid': 'demo-app',
      'coll': 'default',
      'key': 'k1',
      'value': {'n': 1},
      'deleted': false,
      'version': 3,
      'writer_openid': 'o-1',
    };

    test('appid 匹配返回可往返的 json 字符串', () {
      final json = mpEventFilter(
          WSMessage(op: 0, t: 'MP_DATA_UPDATE', d: frame), 'demo-app');
      expect(json, isNotNull);
      expect(jsonDecode(json!), frame);
    });

    test('appid 不匹配返回 null', () {
      expect(
        mpEventFilter(
            WSMessage(op: 0, t: 'MP_DATA_UPDATE', d: frame), 'other-app'),
        isNull,
      );
    });

    test('d 缺失或非 Map 返回 null(防御畸形帧)', () {
      expect(mpEventFilter(WSMessage(op: 0, t: 'MP_DATA_UPDATE'), 'demo-app'),
          isNull);
      expect(
          mpEventFilter(
              WSMessage(op: 0, t: 'MP_DATA_UPDATE', d: 'oops'), 'demo-app'),
          isNull);
    });
  });
}
