// InboxPopupPrefNotifier 纯单元测试:默认值/持久化/登出中间态/账号隔离。
// 照 nav_order_test.dart 惯例:直接构造 Notifier,SharedPreferences.setMockInitialValues。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/providers/inbox_popup_pref_provider.dart';

void main() {
  Future<(SharedPreferences, InboxPopupPrefNotifier)> make(String ownerId,
      {Map<String, Object> seed = const {}}) async {
    SharedPreferences.setMockInitialValues(seed);
    final prefs = await SharedPreferences.getInstance();
    return (prefs, InboxPopupPrefNotifier(prefs: prefs, ownerId: ownerId));
  }

  test('无存量默认 true 且不写盘', () async {
    final (prefs, n) = await make('u1');
    expect(n.state, isTrue);
    expect(prefs.getBool('inbox_auto_popup_u1'), isNull);
  });

  test('set(false) 更新 state 并落盘', () async {
    final (prefs, n) = await make('u1');
    await n.set(false);
    expect(n.state, isFalse);
    expect(prefs.getBool('inbox_auto_popup_u1'), isFalse);
  });

  test('set 同值幂等:不重复写盘', () async {
    final (prefs, n) = await make('u1');
    await n.set(true); // state 已是 true
    expect(prefs.getBool('inbox_auto_popup_u1'), isNull); // 未写盘
  });

  test('存量 false 构造后读出 false', () async {
    final (_, n) = await make('u1', seed: {'inbox_auto_popup_u1': false});
    expect(n.state, isFalse);
  });

  test('空 ownerId 登出中间态:恒 true,set 不生效不落盘', () async {
    final (prefs, n) = await make('');
    expect(n.state, isTrue);
    await n.set(false);
    expect(n.state, isTrue);
    expect(prefs.getBool('inbox_auto_popup_'), isNull); // 幽灵 key 不写
  });

  test('账号隔离:各自读各自值', () async {
    final (_, n1) = await make('u1', seed: {'inbox_auto_popup_u1': false});
    final (_, n2) = await make('u2');
    expect(n1.state, isFalse);
    expect(n2.state, isTrue);
  });
}
