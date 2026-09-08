// motionSuspendedForInstance 纯函数回归测试 —— 钉住实例级设备运动停推语义。
// 回归锁: 嵌入实例非 manager 前台(被最小化/被覆盖)即停推,路由模式永不停推。
import 'package:flutter_test/flutter_test.dart';
import 'package:app/pages/mini_program_page.dart';

void main() {
  test('嵌入实例为 manager 前台:不停推', () {
    expect(
      motionSuspendedForInstance(
        embedded: true,
        hasForeground: true,
        foregroundAppid: 'showcase',
        appid: 'showcase',
      ),
      isFalse,
    );
  });

  test('嵌入实例被其他实例覆盖:停推', () {
    expect(
      motionSuspendedForInstance(
        embedded: true,
        hasForeground: true,
        foregroundAppid: 'other-app',
        appid: 'showcase',
      ),
      isTrue,
    );
  });

  test('嵌入实例被最小化(无前台):停推', () {
    expect(
      motionSuspendedForInstance(
        embedded: true,
        hasForeground: false,
        foregroundAppid: null,
        appid: 'showcase',
      ),
      isTrue,
    );
  });

  test('路由模式无实例编排:任何前台态都不停推', () {
    expect(
      motionSuspendedForInstance(
        embedded: false,
        hasForeground: true,
        foregroundAppid: 'other-app',
        appid: 'showcase',
      ),
      isFalse,
    );
    expect(
      motionSuspendedForInstance(
        embedded: false,
        hasForeground: false,
        foregroundAppid: null,
        appid: 'showcase',
      ),
      isFalse,
    );
  });
}
