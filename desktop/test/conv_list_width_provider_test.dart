import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_desktop/providers/conv_list_width_provider.dart';

void main() {
  test('初始宽度取持久化值', () async {
    SharedPreferences.setMockInitialValues({'desktop.convListWidth': 320.0});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(convListWidthProvider.notifier); // 触发懒构造,否则恢复任务不会启动
    // _restore 是异步,等一帧微任务
    await Future<void>.delayed(Duration.zero);
    expect(container.read(convListWidthProvider), 320);
  });

  test('恢复值越界回退默认 280', () async {
    SharedPreferences.setMockInitialValues({'desktop.convListWidth': 999.0});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(convListWidthProvider.notifier); // 触发懒构造,否则恢复任务不会启动
    await Future<void>.delayed(Duration.zero);
    expect(container.read(convListWidthProvider), 280);
  });

  test('setWidth clamp 到 200-400 并持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(convListWidthProvider.notifier);
    notifier.setWidth(120);
    expect(container.read(convListWidthProvider), 200);
    notifier.setWidth(999);
    expect(container.read(convListWidthProvider), 400);
    notifier.setWidth(280);
    // setWidth 的持久化写入是异步微任务,等一帧再断言
    await Future<void>.delayed(Duration.zero);
    expect(prefs.getDouble('desktop.convListWidth'), 280);
  });
}
