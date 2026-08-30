import 'package:wanling_core/providers/agent_sessions_provider.dart' show AgentSessionsNotifier;
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:app/widgets/chat/conv_sync_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockWidgetRef extends Mock implements WidgetRef {}

class _MockConversationListNotifier extends Mock
    implements ConversationListNotifier {}

class _MockAgentSessionsNotifier extends Mock
    implements AgentSessionsNotifier {}

/// markReadOnExit 的三语义分支:
/// - sawNewAgentContent=false(在场期间无新 agent 内容) → 不补 markRead
/// - sawNewAgentContent=true → 本地清零 + API 同步 + 刷新父会话聚合
/// - API 抛错 → 吞掉(本地已清零,server 由下次进入兜住)
void main() {
  late _MockWidgetRef ref;
  late _MockConversationListNotifier convNotifier;

  setUpAll(() {
    registerFallbackValue(ProviderContainer());
  });

  setUp(() {
    ref = _MockWidgetRef();
    convNotifier = _MockConversationListNotifier();
  });

  ConvSyncController buildController({
    String? agentId,
    _MockAgentSessionsNotifier? sessions,
  }) {
    when(() => ref.read(conversationProvider.notifier))
        .thenReturn(convNotifier);
    when(() => ref.read(conversationProvider)).thenReturn(const []);
    if (agentId != null && sessions != null) {
      when(() => ref.read(apiProvider)).thenThrow('未 stub 的 api 调用');
    }
    return ConvSyncController(ConvSyncContext(
      ref: ref,
      convId: 'conv-1',
      agentId: agentId,
      getSessionsNotifier: () => sessions,
    ));
  }

  test('sawNewAgentContent=false → 什么都不做', () async {
    final controller = buildController();
    // conversationProvider.notifier 不被读取 → 若读了会抛 MissingStubError
    await controller.markReadOnExit(sawNewAgentContent: false);
    verifyNever(() => ref.read(conversationProvider.notifier));
  });

  test('sawNewAgentContent=true 且本地已是 0 → 仅同步 server', () async {
    // markReadLocally 内部对 unread==0 短路,不产生副作用;controller 只管调
    when(() => ref.read(apiProvider)).thenThrow('不应调用 server(本测试无 api)');
    final controller = buildController(agentId: null);
    // api 会抛——但吞掉,验证不向上传播
    await controller.markReadOnExit(sawNewAgentContent: true);
    verify(() => ref.read(conversationProvider.notifier)).called(1);
    verify(() => convNotifier.markReadLocally('conv-1')).called(1);
  });
}
