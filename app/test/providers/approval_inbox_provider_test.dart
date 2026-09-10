// fake_async 是 flutter_test 的传递依赖（不允许为此新增 pubspec 依赖），
// 仅测试文件使用，ignore 掉 depend_on_referenced_packages 提示。
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/providers/approval_inbox_provider.dart';
import 'package:wanling_core/models/ws_message.dart';

import '../helpers/fake_ws.dart';

WSMessage createMsg(String id, String convId, Map<String, dynamic> data) =>
    WSMessage(op: 0, d: {
      'id': id,
      'conversation_id': convId,
      'content': {'msg_type': 'permission_card', 'data': data},
    });

WSMessage updateMsg(String id, String convId, Map<String, dynamic> data) =>
    WSMessage(op: 0, d: {
      'message_id': id,
      'conversation_id': convId,
      'content': {'msg_type': 'permission_card', 'data': data},
    });

/// FakeWS 的 broadcast 流为异步投递，等一个事件循环边界让 listener 处理完。
/// 与 conversation_provider_test.dart 的既有惯例一致。
Future<void> drain() => Future<void>.delayed(Duration.zero);

void main() {
  test('新卡入队：queue 更新、suppressed 重置、300ms 后 exposing=true', () async {
    final ws = FakeWS();
    final c = ApprovalInboxController(ws);
    addTearDown(c.dispose);
    ws.emit(createMsg('m1', 'c1', {'status': 'pending'}));
    await drain();
    expect(c.state.queue, hasLength(1));
    expect(c.state.exposing, isFalse); // 防抖窗口内
    expect(c.state.suppressed, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.state.exposing, isTrue);
  });

  test('终态 UPDATE 收敛出队并清 awaiting，队列空 exposing=false', () async {
    final ws = FakeWS();
    final c = ApprovalInboxController(ws);
    addTearDown(c.dispose);
    ws.emit(createMsg('m1', 'c1', {'status': 'pending'}));
    await drain();
    c.markAwaitingConfirm('m1');
    expect(c.state.awaitingKeys, contains('m1'));
    ws.emitUpdate(updateMsg('m1', 'c1', {'status': 'approved'}));
    await drain();
    expect(c.state.queue, isEmpty);
    expect(c.state.awaitingKeys, isEmpty);
    expect(c.state.exposing, isFalse);
  });

  test('dismissCurrent：suppressed=true 不自动续弹', () async {
    final ws = FakeWS();
    final c = ApprovalInboxController(ws);
    addTearDown(c.dispose);
    ws.emit(createMsg('m1', 'c1', {'status': 'pending'}));
    ws.emit(createMsg('m2', 'c1', {'status': 'pending'}));
    await drain();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    c.dismissCurrent();
    expect(c.state.suppressed, isTrue);
    expect(c.state.exposing, isFalse);
    expect(c.state.queue, hasLength(2)); // 队列保留
    // 非新卡到达不重置 suppress：终态收敛不触发弹窗
    ws.emitUpdate(updateMsg('m1', 'c1', {'status': 'approved'}));
    await drain();
    expect(c.state.exposing, isFalse);
    // 新卡到达重置 suppress 并重新防抖
    ws.emit(createMsg('m3', 'c2', {'status': 'pending'}));
    await drain();
    expect(c.state.suppressed, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.state.exposing, isTrue);
  });

  test('防抖：连续入队只调度一次 exposing（fake_async 假时钟，免真实等待）', () {
    fakeAsync((async) {
      final ws = FakeWS();
      final c = ApprovalInboxController(ws);
      addTearDown(c.dispose);
      ws.emit(createMsg('m1', 'c1', {'status': 'pending'}));
      async.flushMicrotasks(); // FakeWS broadcast 流异步投递，刷微任务入队
      async.elapse(const Duration(milliseconds: 150));
      ws.emit(createMsg('m2', 'c1', {'status': 'pending'}));
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 150));
      // 距首卡 300ms 但距 m2 仅 150ms：仍在防抖窗口
      expect(c.state.exposing, isFalse);
      async.elapse(const Duration(milliseconds: 200));
      expect(c.state.exposing, isTrue);
      expect(c.state.queue, hasLength(2));
    });
  });
}
