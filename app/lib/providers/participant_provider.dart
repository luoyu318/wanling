import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/participant.dart';
import '../services/api_service.dart';
import 'auth_provider.dart' show apiProvider;

/// 单会话参与者列表 provider(family by convId)。
///
/// 用于 ConversationDetailPage 渲染群成员 / 邀请新成员 / 踢人。
/// 调用 [ConversationListNotifier] 的群管理方法时,server 会广播
/// CONVERSATION_PARTICIPANT_JOIN/LEAVE 事件,conversationProvider 自动更新
/// 该会话的 participants 字段;本 provider 监听 conversationProvider 的对应会话
/// 数据,自动跟随。
///
/// 单独 provider 而非复用 conversationProvider.list[convId].participants:
/// ConversationDetailPage 只关心单个会话的 participants,避免每次 list 变化重建。
class ParticipantNotifier extends StateNotifier<List<Participant>> {
  final ApiService _api;
  final String _convId;

  ParticipantNotifier(this._api, this._convId) : super(const []) {
    _load();
  }

  /// 拉取会话详情(server GET /api/conversations/:id 返回 participants[])。
  Future<void> _load() async {
    try {
      final raw = await _api.getConversation(_convId);
      final participantsJson = raw['participants'] as List? ?? [];
      state = participantsJson
          .map((e) => Participant.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // 拉取失败保留空列表,UI 显示加载失败提示
    }
  }

  /// 重新拉取(外部触发,如收到 JOIN/LEAVE 事件后)。
  Future<void> refresh() async => _load();

  /// 邀请成员。server 广播 JOIN,本 provider 通过 refresh() 拉最新列表。
  Future<void> invite(String memberId, String memberType) async {
    await _api.inviteMember(_convId, memberId, memberType);
    await refresh();
  }

  /// 踢人。server 广播 LEAVE,本 provider 通过 refresh() 拉最新列表。
  Future<void> kick(String memberId) async {
    await _api.kickMember(_convId, memberId);
    await refresh();
  }
}

final participantProvider = StateNotifierProvider.family<
    ParticipantNotifier, List<Participant>, String>((ref, convId) {
  return ParticipantNotifier(ref.watch(apiProvider), convId);
});
