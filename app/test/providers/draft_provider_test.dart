import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/providers/draft_provider.dart';

import '../helpers/fake_local_message_store.dart';

void main() {
  late FakeLocalMessageStore store;
  // 防抖注入 10ms,测试免真等 500ms
  const deb = Duration(milliseconds: 10);

  setUp(() => store = FakeLocalMessageStore());

  DraftNotifier make() => DraftNotifier(store, 'u1', 'conv1', debounce: deb);

  test('构造时异步加载已存草稿', () async {
    await store.putDraft('u1', 'conv1', '旧草稿');
    final n = make();
    await Future.delayed(Duration.zero);
    expect(n.state, '旧草稿');
    n.disposeTest();
  });

  test('加载不覆盖用户已输入内容(state 非空)', () async {
    await store.putDraft('u1', 'conv1', '旧草稿');
    final n = make();
    n.setText('新输入'); // 加载完成前用户已输入
    await Future.delayed(deb * 2);
    expect(n.state, '新输入');
    expect(await store.getDraft('u1', 'conv1'), '新输入');
    n.disposeTest();
  });

  test('setText 防抖落库', () async {
    final n = make();
    n.setText('草稿A');
    n.setText('草稿AB'); // 防抖窗口内连续输入,只落最后一版
    expect(await store.getDraft('u1', 'conv1'), isNull); // 尚未落库
    await Future.delayed(deb * 2);
    expect(await store.getDraft('u1', 'conv1'), '草稿AB');
    n.disposeTest();
  });

  test('setText 空串立即删库(用户删光文字)', () async {
    await store.putDraft('u1', 'conv1', '旧');
    final n = make();
    await Future.delayed(Duration.zero);
    n.setText('');
    expect(n.state, '');
    expect(await store.getDraft('u1', 'conv1'), isNull);
    n.disposeTest();
  });

  test('clear 清内存 + 删库', () async {
    await store.putDraft('u1', 'conv1', '旧');
    final n = make();
    await Future.delayed(Duration.zero);
    n.setText('正在打字');
    await n.clear();
    expect(n.state, '');
    expect(await store.getDraft('u1', 'conv1'), isNull);
    n.disposeTest();
  });

  test('dispose 时 pending 文本兜底落库', () async {
    final n = make();
    n.setText('没等到防抖就退出');
    n.disposeTest(); // 直接触发 dispose flush
    await Future.delayed(deb * 2);
    expect(await store.getDraft('u1', 'conv1'), '没等到防抖就退出');
  });

  test('store 抛错不 crash(throwOnNextOp)', () async {
    store.throwOnNextOp = 'putDraft';
    final n = make();
    n.setText('落库会失败');
    await Future.delayed(deb * 2); // 不抛即通过
    n.disposeTest();
  });
}
