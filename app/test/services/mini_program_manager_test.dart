import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/mini_program_info.dart';
import 'package:app/services/mini_program_manager.dart';

MiniProgramInfo _mp(String appid, String name, String icon) =>
    MiniProgramInfo(
      id: 'id-$appid',
      appid: appid,
      ownerId: 'u1',
      name: name,
      version: 1,
      status: 'published',
      sha256: 'x',
      size: 1,
      icon: icon,
    );

void main() {
  late MiniProgramManager m;
  setUp(() => m = MiniProgramManager());

  test('open 置前台并记录实例', () {
    m.open('a', name: 'A');
    expect(m.hasForeground, isTrue);
    expect(m.foregroundAppid, 'a');
    expect(m.foreground!.name, 'A');
  });

  test('open 已存在实例只更新元信息不重建', () {
    m.open('a');
    final first = m.instances['a']!;
    m.open('a', name: 'AA');
    expect(identical(m.instances['a'], first), isTrue);
    expect(first.name, 'AA');
  });

  test('minimize/restore 切前台,实例保留', () async {
    m.open('a');
    m.minimize();
    expect(m.hasForeground, isFalse);
    expect(m.instances.containsKey('a'), isTrue);
    await Future.delayed(const Duration(milliseconds: 5));
    m.restore('a');
    expect(m.foregroundAppid, 'a');
  });

  test('restore 不存在的 appid 是 no-op', () {
    m.restore('ghost');
    expect(m.hasForeground, isFalse);
  });

  test('close 销毁实例;关的是前台则前台清空', () {
    m.open('a');
    m.close('a');
    expect(m.instances, isEmpty);
    expect(m.hasForeground, isFalse);
  });

  test('closeAll 清空全部实例+前台,登出/切账号用', () async {
    m.open('a');
    await Future.delayed(const Duration(milliseconds: 5));
    m.open('b');
    m.minimize();

    m.closeAll();
    expect(m.instances, isEmpty);
    expect(m.hasForeground, isFalse);
    expect(m.list, isEmpty);
  });

  test('closeAll 幂等:已空时重复调用不再通知', () {
    var notified = 0;
    m.addListener(() => notified++);
    m.closeAll();
    m.closeAll();
    expect(notified, 0); // 无状态变化不触发空通知
  });

  test('open 带 conv/launch 参数 → 存入实例元数据(I2)', () {
    m.open('a', conversationId: 'c1', launchParams: '{"x":1}');
    expect(m.instances['a']!.conversationId, 'c1');
    expect(m.instances['a']!.launchParams, '{"x":1}');
  });

  test('重复打开参数相同/为空 → 实例复用不重建(I2)', () {
    m.open('a', conversationId: 'c1', launchParams: '{"x":1}');
    final first = m.instances['a']!;
    m.open('a', conversationId: 'c1', launchParams: '{"x":1}');
    expect(identical(m.instances['a'], first), isTrue);
    // 参数未提供(null)=不更新不重建(列表入口重开场景)
    m.open('a');
    expect(identical(m.instances['a'], first), isTrue);
    expect(m.instances['a']!.conversationId, 'c1');
  });

  test('重复打开参数变化 → 销毁重建实例(卡片语境正确性优先,I2)', () {
    m.open('a', conversationId: 'c1', launchParams: '{"x":1}');
    final first = m.instances['a']!;
    final evicted = m.open('a', conversationId: 'c2', launchParams: '{"x":2}');
    expect(evicted, isNull); // 重建不是 LRU 淘汰
    expect(identical(m.instances['a'], first), isFalse); // 新实例
    expect(m.instances['a']!.conversationId, 'c2');
    expect(m.instances['a']!.launchParams, '{"x":2}');
    expect(m.foregroundAppid, 'a');
    expect(m.instances.length, 1); // 无多余实例残留
  });

  test('list 按打开时间倒序', () async {
    m.open('a');
    await Future.delayed(const Duration(milliseconds: 5));
    m.open('b');
    expect(m.list.map((e) => e.appid).toList(), ['b', 'a']);
  });

  test('超上限 LRU 淘汰最久未前台者', () async {
    m.open('a');
    await Future.delayed(const Duration(milliseconds: 5));
    m.open('b');
    await Future.delayed(const Duration(milliseconds: 5));
    m.open('c');
    await Future.delayed(const Duration(milliseconds: 5));
    m.open('d');
    await Future.delayed(const Duration(milliseconds: 5));
    m.open('e');
    await Future.delayed(const Duration(milliseconds: 5));
    m.restore('b'); // b 变成最近前台,a 成为目标淘汰者
    await Future.delayed(const Duration(milliseconds: 5));
    final evicted = m.open('f');
    expect(evicted, 'a');
    expect(m.instances.containsKey('a'), isFalse);
    expect(m.instances.containsKey('b'), isTrue);
    expect(m.foregroundAppid, 'f');
  });

  test('变更通知监听器收到回调', () {
    var notified = 0;
    m.addListener(() => notified++);
    m.open('a');
    expect(notified, 1);
  });

  group('resolveInstanceMeta 实例元数据回填(D)', () {
    test('实例快照 name/iconUrl 非空:快照优先,不查 provider', () {
      m.open('a', name: '快照名', iconUrl: 'http://snap.local/icon.png');
      final inst = m.instances['a']!;

      final meta = resolveInstanceMeta(inst, [_mp('a', '注册名', '/reg.png')],
          'http://base.local');

      expect(meta.name, '快照名');
      expect(meta.iconUrl, 'http://snap.local/icon.png');
    });

    test('实例 name/iconUrl 为空 + provider 有数据:回填真名与 baseUrl 拼接的 icon',
        () {
      m.open('a'); // 打开瞬间无元信息(面板路径只传 appid)
      final inst = m.instances['a']!;

      final meta = resolveInstanceMeta(
          inst, [_mp('a', '跳跳球大冒险', '/api/files/icon.png')], 'http://base.local');

      expect(meta.name, '跳跳球大冒险');
      expect(meta.iconUrl, 'http://base.local/api/files/icon.png');
    });

    test('provider 无该 appid 数据:name 回退 appid,iconUrl 回退空', () {
      m.open('ghost-app');
      final inst = m.instances['ghost-app']!;

      final meta =
          resolveInstanceMeta(inst, [_mp('a', '别的', '/x.png')], 'http://b.local');

      expect(meta.name, 'ghost-app');
      expect(meta.iconUrl, '');
    });

    test('provider 未加载(空列表)同样回退快照/appid', () {
      m.open('a');
      final inst = m.instances['a']!;

      final meta = resolveInstanceMeta(inst, const [], 'http://b.local');

      expect(meta.name, 'a');
      expect(meta.iconUrl, '');
    });
  });

  group('WebView 快照帧管理(E)', () {
    test('updateSnapshot 写入帧并通知;实例不存在时 no-op', () {
      m.open('a');
      var notified = 0;
      m.addListener(() => notified++);

      final frame = Uint8List.fromList([1, 2, 3]);
      m.updateSnapshot('a', frame);
      expect(m.instances['a']!.snapshot, same(frame));
      expect(notified, 1);

      // 抓帧完成时实例可能已被关闭(竞态):静默丢弃,不得重建实例
      m.close('a');
      notified = 0;
      m.updateSnapshot('a', frame);
      expect(m.instances.containsKey('a'), isFalse);
      expect(notified, 0);
    });

    test('takeScreenshot 返回 null → 清空帧回退占位', () {
      m.open('a');
      m.updateSnapshot('a', Uint8List.fromList([1]));
      m.updateSnapshot('a', null);
      expect(m.instances['a']!.snapshot, isNull);
    });

    test('restore 置前台清空旧帧(前台实时渲染,帧只在后台态有意义)', () {
      m.open('a');
      m.updateSnapshot('a', Uint8List.fromList([1]));
      m.minimize();
      m.updateSnapshot('a', Uint8List.fromList([2]));
      m.restore('a');
      expect(m.instances['a']!.snapshot, isNull);
    });

    test('close/closeAll 释放帧引用', () {
      final frame = Uint8List.fromList([1]);
      m.open('a');
      m.updateSnapshot('a', frame);
      final instA = m.instances['a']!;
      m.close('a');
      expect(instA.snapshot, isNull, reason: '关闭先断帧引用再移除实例');

      m.open('b');
      m.updateSnapshot('b', frame);
      m.closeAll();
      expect(m.list, isEmpty);
    });

    test('LRU 淘汰:被淘汰实例帧引用断开', () async {
      final frame = Uint8List.fromList([1]);
      for (final id in ['a', 'b', 'c', 'd', 'e']) {
        m.open(id);
        m.updateSnapshot(id, frame);
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      m.restore('b');
      await Future<void>.delayed(const Duration(milliseconds: 2));

      final evicted = m.open('f');
      expect(evicted, 'a');
      // 实例已移除;帧字段随实例对象可 GC,manager 不再持有
      expect(m.instances.containsKey('a'), isFalse);
      // b 曾被 restore 置前台 → 旧帧已按「前台实时渲染」语义清空
      expect(m.instances['b']!.snapshot, isNull);
      // 未被动过的后台实例帧仍在
      expect(m.instances['c']!.snapshot, same(frame));
    });
  });
}
