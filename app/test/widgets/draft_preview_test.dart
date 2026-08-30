import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/local_message_store_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:app/widgets/draft_preview.dart';

import '../helpers/fake_local_message_store.dart';

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(super.api);
}

void main() {
  late FakeLocalMessageStore store;
  late _FakeAuthNotifier authNotifier;

  setUp(() {
    store = FakeLocalMessageStore();
    authNotifier = _FakeAuthNotifier(
      ApiService(baseUrl: 'http://test.local'),
    );
    authNotifier.state = AuthState(
      user: User(
        id: 'u1',
        username: 'alice',
        nickname: 'Alice',
        bio: '',
        createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
      ),
      token: 't',
      isRestoring: false,
    );
  });

  Widget harness() => UncontrolledProviderScope(
        container: ProviderContainer(overrides: [
          authProvider.overrideWith((ref) => authNotifier),
          localMessageStoreProvider.overrideWith((ref) async => store),
        ]),
        child: const MaterialApp(
          home: Scaffold(
            body: DraftAwarePreview(
              convId: 'conv-x',
              fallback: Text('最后一条:123'),
            ),
          ),
        ),
      );

  testWidgets('无草稿显示 fallback 原摘要', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.text('最后一条:123'), findsOneWidget);
    expect(find.byIcon(Icons.edit_note), findsNothing);
  });

  testWidgets('有草稿显示红色书写 icon + 草稿文本(替换摘要)', (tester) async {
    await store.putDraft('u1', 'conv-x', '未发送的草稿');
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_note), findsOneWidget);
    expect(find.text('未发送的草稿'), findsOneWidget);
    expect(find.text('最后一条:123'), findsNothing);
    // 红色 #FA5151
    final icon = tester.widget<Icon>(find.byIcon(Icons.edit_note));
    expect(icon.color, const Color(0xFFFA5151));
  });

  testWidgets('长草稿单行省略', (tester) async {
    await store.putDraft('u1', 'conv-x', '很长的草稿' * 50);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(find.text('很长的草稿' * 50));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
  });
}
