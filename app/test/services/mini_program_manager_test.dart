import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/mini_program_manager.dart';

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
}
