// virtualHostFor 纯函数回归测试 —— 钉住小程序虚拟 origin 账号隔离语义。
// 回归锁: 虚拟 host 含账号段,同设备多账号打开同一小程序 storage 互不可见。
import 'package:flutter_test/flutter_test.dart';
import 'package:app/pages/mini_program_page.dart';

void main() {
  test('appid + uid 组合为 <appid>.<uid>.mini.wanling.local', () {
    expect(virtualHostFor('showcase', 'u-123'),
        'showcase.u-123.mini.wanling.local');
  });

  test('不同 uid 产出不同 host(origin 级隔离)', () {
    final a = virtualHostFor('showcase', 'u-1');
    final b = virtualHostFor('showcase', 'u-2');
    expect(a, isNot(b));
  });

  test('不同 appid 产出不同 host', () {
    expect(virtualHostFor('memo', 'u-1'),
        isNot(virtualHostFor('showcase', 'u-1')));
  });
}
