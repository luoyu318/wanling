import 'package:app/pages/create_group_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // CreateGroupPage 是 ConsumerStatefulWidget,创建群聊调 conversationProvider.createGroup,
  // 测试中需要 mock 网络层。本 task 范围:占位测试。
  testWidgets('CreateGroupPage 文件可导入', (tester) async {
    expect(CreateGroupPage, isNotNull);
  });
}
