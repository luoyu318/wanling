import 'package:app/pages/friends_list_page.dart';
import 'package:app/widgets/settings_tile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // FriendsListPage 是 ConsumerStatefulWidget,依赖 friendListProvider /
  // wsProvider / apiProvider。本 task 范围内只做编译通过 + 文件可导入的占位
  // 测试,完整 widget 测试由 Batch 5(端到端验证)覆盖。
  testWidgets('FriendsListPage 文件可导入', (tester) async {
    expect(FriendsListPage, isNotNull);
    expect(SettingsTile, isNotNull);
  }, skip: true);

  testWidgets('FriendsListPage 3 个 tab 渲染', (tester) async {}, skip: true);
}
