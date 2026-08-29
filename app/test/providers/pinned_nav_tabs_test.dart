// pinnedNavTabsNotifier 纯单元测试:pin/unpin/reorder 语义 + SP 持久化 + 账号隔离。
// 不经 riverpod(无 UI 依赖),直接构造 Notifier,SharedPreferences 用 setMockInitialValues。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/providers/pinned_nav_tabs_provider.dart';

void main() {
  Future<(SharedPreferences, PinnedNavTabsNotifier)> make(String ownerId,
      [Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    final prefs = await SharedPreferences.getInstance();
    return (prefs, PinnedNavTabsNotifier(prefs: prefs, ownerId: ownerId));
  }

  test('初始为空;pin 追加队尾,重复 pin no-op', () async {
    final (_, n) = await make('u1');
    expect(n.state, isEmpty);
    n.pin('a1');
    n.pin('a2');
    n.pin('a1'); // 重复
    expect(n.state, ['a1', 'a2']);
  });

  test('pin 持久化:重建 notifier 后状态还原', () async {
    final (prefs, n) = await make('u1');
    n.pin('a1');
    final reloaded = PinnedNavTabsNotifier(prefs: prefs, ownerId: 'u1');
    expect(reloaded.state, ['a1']);
  });

  test('unpin 移除;未 pin 的 id no-op', () async {
    final (_, n) = await make('u1', {'nav_pins_u1': ['a1', 'a2']});
    n.unpin('a9'); // 不存在
    expect(n.state, ['a1', 'a2']);
    n.unpin('a1');
    expect(n.state, ['a2']);
  });

  test('isPinned 判定', () async {
    final (_, n) = await make('u1', {'nav_pins_u1': ['a1']});
    expect(n.isPinned('a1'), isTrue);
    expect(n.isPinned('a2'), isFalse);
  });

  test('reorderTo 移动到目标下标;越界/同位/不存在 no-op', () async {
    final (_, n) = await make('u1',
        {'nav_pins_u1': ['a1', 'a2', 'a3']});
    n.reorderTo('a9', 0); // 不存在
    expect(n.state, ['a1', 'a2', 'a3']);
    n.reorderTo('a1', 3); // 越界
    expect(n.state, ['a1', 'a2', 'a3']);
    n.reorderTo('a1', 0); // 同位
    expect(n.state, ['a1', 'a2', 'a3']);
    n.reorderTo('a1', 2); // 后移
    expect(n.state, ['a2', 'a3', 'a1']);
    n.reorderTo('a1', 0); // 前移
    expect(n.state, ['a1', 'a2', 'a3']);
  });

  test('reorderTo 持久化', () async {
    final (prefs, n) = await make('u1',
        {'nav_pins_u1': ['a1', 'a2']});
    n.reorderTo('a1', 1);
    final reloaded = PinnedNavTabsNotifier(prefs: prefs, ownerId: 'u1');
    expect(reloaded.state, ['a2', 'a1']);
  });

  test('账号隔离:同 prefs 不同 ownerId 各自独立', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final u1 = PinnedNavTabsNotifier(prefs: prefs, ownerId: 'u1')..pin('a1');
    final u2 = PinnedNavTabsNotifier(prefs: prefs, ownerId: 'u2');
    expect(u2.state, isEmpty);
    expect(u1.state, ['a1']);
  });
}
