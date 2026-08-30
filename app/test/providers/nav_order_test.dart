// NavOrderNotifier 纯单元测试:迁移/sanitize/reorder move 语义/固定项守卫/持久化/账号隔离。
// 不经 riverpod(无 UI 依赖),直接构造 Notifier,SharedPreferences 用 setMockInitialValues。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/providers/nav_order_provider.dart';

void main() {
  Future<(SharedPreferences, NavOrderNotifier)> make(String ownerId,
      {Map<String, List<String>>? seed}) async {
    SharedPreferences.setMockInitialValues({
      for (final e in (seed ?? const {}).entries) e.key: e.value,
    });
    final prefs = await SharedPreferences.getInstance();
    return (prefs, NavOrderNotifier(prefs: prefs, ownerId: ownerId));
  }

  test('无任何持久化数据:初始为固定项前二', () async {
    final (prefs, n) = await make('u1');
    expect(n.state, [kNavTabMsg, kNavTabWanling]);
    expect(prefs.getStringList('nav_order_u1'), isNull); // 未写盘
  });

  test('旧 nav_pins 一次性迁移:固定项前置 + 立即写新 key', () async {
    final (prefs, n) = await make('u1', seed: {
      'nav_pins_u1': ['a1', 'a2'],
    });
    expect(n.state, [kNavTabMsg, kNavTabWanling, 'a1', 'a2']);
    expect(prefs.getStringList('nav_order_u1'),
        [kNavTabMsg, kNavTabWanling, 'a1', 'a2']);
    // 旧 key 保留(降级回滚用)
    expect(prefs.getStringList('nav_pins_u1'), ['a1', 'a2']);
  });

  test('已有新 key 时不迁移', () async {
    final (_, n) = await make('u1', seed: {
      'nav_order_u1': ['a1', kNavTabMsg],
      'nav_pins_u1': ['a9'],
    });
    // 不迁移(a9 不进来);缺失的 wanling 按不变式补到 msg 前
    expect(n.state, ['a1', kNavTabWanling, kNavTabMsg]);
  });

  test('sanitize:去空/去重保序,固定项位置不强制', () async {
    final (_, n) = await make('u1', seed: {
      'nav_order_u1': ['', kNavTabMsg, 'a1', kNavTabMsg, kNavTabWanling],
    });
    // 去空/去重保序,固定项位置保留;仅缺失才补(本用例不缺)
    expect(n.state, [kNavTabMsg, 'a1', kNavTabWanling]);
    final (_, n2) = await make('u2', seed: {
      'nav_order_u2': ['a1', 'a2'], // 固定项全缺(数据损坏)
    });
    expect(n2.state, [kNavTabMsg, kNavTabWanling, 'a1', 'a2']);
  });

  test('空 ownerId 登出中间态:空列表,不迁移不写幽灵 key', () async {
    SharedPreferences.setMockInitialValues({
      'nav_pins_': ['stale'], // 幽灵 legacy key 即使存在也不迁移
    });
    final prefs = await SharedPreferences.getInstance();
    final n = NavOrderNotifier(prefs: prefs, ownerId: '');
    expect(n.state, isEmpty);
    expect(prefs.getStringList('nav_order_'), isNull); // 未写幽灵 key
  });

  test('reorder move 语义:任意项(含固定项)可移动,其余顺移', () async {
    final (_, n) = await make('u1', seed: {
      'nav_order_u1': [kNavTabMsg, kNavTabWanling, 'a1', 'a2'],
    });
    n.reorder(kNavTabMsg, 2); // 固定项后移
    expect(n.state, [kNavTabWanling, 'a1', kNavTabMsg, 'a2']);
    n.reorder('a2', 0); // agent 插到最前
    expect(n.state, ['a2', kNavTabWanling, 'a1', kNavTabMsg]);
  });

  test('reorder 越界/同位/不存在 no-op', () async {
    final (_, n) = await make('u1', seed: {
      'nav_order_u1': [kNavTabMsg, kNavTabWanling, 'a1'],
    });
    n.reorder('a9', 0);
    n.reorder('a1', 3); // 越界
    n.reorder('a1', 2); // 同位
    expect(n.state, [kNavTabMsg, kNavTabWanling, 'a1']);
  });

  test('reorder 持久化 + 重载还原', () async {
    final (prefs, n) = await make('u1', seed: {
      'nav_order_u1': [kNavTabMsg, kNavTabWanling, 'a1', 'a2'],
    });
    n.reorder('a1', 0);
    final reloaded = NavOrderNotifier(prefs: prefs, ownerId: 'u1');
    expect(reloaded.state, ['a1', kNavTabMsg, kNavTabWanling, 'a2']);
  });

  test('unpin 拒绝固定项;agent 可 unpin', () async {
    final (_, n) = await make('u1', seed: {
      'nav_order_u1': [kNavTabMsg, kNavTabWanling, 'a1'],
    });
    n.unpin(kNavTabMsg);
    n.unpin(kNavTabWanling);
    expect(n.state, [kNavTabMsg, kNavTabWanling, 'a1']);
    n.unpin('a1');
    expect(n.state, [kNavTabMsg, kNavTabWanling]);
    n.unpin('a1'); // 未 pin no-op
    expect(n.state, [kNavTabMsg, kNavTabWanling]);
  });

  test('pin 追加队尾;isPinned 判定', () async {
    final (_, n) = await make('u1');
    expect(n.isPinned('a1'), isFalse);
    n.pin('a1');
    expect(n.isPinned('a1'), isTrue);
    expect(n.state, [kNavTabMsg, kNavTabWanling, 'a1']);
    n.pin('a1'); // 重复 no-op
    expect(n.state, [kNavTabMsg, kNavTabWanling, 'a1']);
  });

  test('账号隔离', () async {
    final (prefs, u1) = await make('u1');
    u1.pin('a1');
    final u2 = NavOrderNotifier(prefs: prefs, ownerId: 'u2');
    expect(u2.state, [kNavTabMsg, kNavTabWanling]);
  });

  group('可见槽数 NavVisibleCountNotifier', () {
    test('未设置:-1 自动,resolveVisibleCount 按 total 推导', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final n = NavVisibleCountNotifier(prefs: prefs, ownerId: 'u1');
      expect(n.state, autoVisibleCount);
      // 自动规则:≤4 全可见,>4 可见 4;最少保留 1。
      expect(resolveVisibleCount(autoVisibleCount, 2), 2);
      expect(resolveVisibleCount(autoVisibleCount, 4), 4);
      expect(resolveVisibleCount(autoVisibleCount, 6), 4);
      expect(resolveVisibleCount(autoVisibleCount, 0), 1);
    });

    test('set 写盘 + clamp 1..4;重载还原;空 ownerId 不写', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final n = NavVisibleCountNotifier(prefs: prefs, ownerId: 'u1');
      n.set(2);
      expect(n.state, 2);
      expect(prefs.getInt('nav_visible_u1'), 2);
      n.set(0); // 低于下限 clamp 到 1
      expect(n.state, 1);
      n.set(9); // 高于上限 clamp 到 4
      expect(n.state, 4);
      expect(resolveVisibleCount(4, 2), 2); // 显式值 ≤ 总项
      final reloaded = NavVisibleCountNotifier(prefs: prefs, ownerId: 'u1');
      expect(reloaded.state, 4);

      final anon = NavVisibleCountNotifier(prefs: prefs, ownerId: '');
      anon.set(3);
      expect(anon.state, autoVisibleCount);
      expect(prefs.getInt('nav_visible_'), isNull);
    });
  });
}
