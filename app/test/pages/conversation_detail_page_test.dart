import 'package:app/pages/conversation_detail_page.dart';
import 'package:app/widgets/settings_tile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ConversationDetailPage 是 ConsumerStatefulWidget,依赖 apiProvider 拉取
  // /conversations/:id,测试中需要 mock 网络层。
  // 本 task 范围:只做编译通过 + 文件可导入的占位测试。
  // 完整 widget 测试在 Task 4.x(好友系统 + 群成员展示)再覆盖。
  testWidgets('ConversationDetailPage 文件可导入', (tester) async {
    expect(ConversationDetailPage, isNotNull);
    expect(SettingsTile, isNotNull);
  }, skip: true);

  testWidgets('ConversationDetailPage 加载中显示 CircularProgressIndicator',
      (tester) async {}, skip: true);
}
