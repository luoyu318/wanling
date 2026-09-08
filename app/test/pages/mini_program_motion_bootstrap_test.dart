// 设备运动 bootstrap 注入包含性回归测试(Task 2)。
// bootstrap 源码走 visibleForTesting 别名断言(库私有 const 单测不可见);
// 原生侧 handler 注册与 _emitMpMotionEvent 推帧靠 Task 4 手工验证。
import 'package:flutter_test/flutter_test.dart';
import 'package:app/pages/mini_program_page.dart';

void main() {
  test('bootstrap 注入 deviceMotion 桥(start/stop/onEvent/_emitMpMotionEvent)',
      () {
    expect(jsBridgeBootstrapSource, contains('wanling.deviceMotion'));
    expect(jsBridgeBootstrapSource, contains('wanlingDeviceMotionStart'));
    expect(jsBridgeBootstrapSource, contains('wanlingDeviceMotionStop'));
    expect(jsBridgeBootstrapSource, contains('_emitMpMotionEvent'));
    expect(jsBridgeBootstrapSource, contains('opts.onEvent'));
  });
}
