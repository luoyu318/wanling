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
