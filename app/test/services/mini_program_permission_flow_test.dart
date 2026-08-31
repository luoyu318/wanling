import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/mini_program_permission_flow.dart';

void main() {
  group('resolvePermissionFlow', () {
    test('全部声明已授权 → pending 空、effective 含 chat 权限', () {
      final flow = resolvePermissionFlow(
        declared: {'wanling.api', 'wanling.chat.read', 'wanling.chat.share'},
        granted: {'wanling.api', 'wanling.chat.read', 'wanling.chat.share'},
      );
      expect(flow.pending, isEmpty);
      expect(flow.effective,
          {'wanling.api', 'wanling.chat.read', 'wanling.chat.share'});
    });

    test('未授权 chat 权限进 pending(保持声明顺序),granted 越集不生效', () {
      final flow = resolvePermissionFlow(
        declared: {'wanling.api', 'wanling.chat.share', 'wanling.chat.read'},
        granted: {'wanling.chat.evil'},
      );
      expect(flow.pending, ['wanling.chat.share', 'wanling.chat.read']);
      expect(flow.effective, {'wanling.api'});
    });
  });

  group('runPermissionFlow', () {
    test('全部声明已授权 → 不调 askUser/persist,返回含 chat 权限的有效集', () async {
      var asked = 0;
      var persisted = 0;
      final effective = await runPermissionFlow(
        declared: {'wanling.api', 'wanling.chat.read'},
        granted: {'wanling.api', 'wanling.chat.read'},
        askUser: (_) async {
          asked++;
          return true;
        },
        persist: (_) async => persisted++,
      );
      expect(asked, 0);
      expect(persisted, 0);
      expect(effective, {'wanling.api', 'wanling.chat.read'});
    });

    test('未授权 chat 权限依次弹窗;允许进生效集,拒绝不进', () async {
      final askedOrder = <String>[];
      final persistedSets = <Set<String>>[];
      final effective = await runPermissionFlow(
        declared: {'wanling.chat.read', 'wanling.chat.share'},
        granted: {},
        askUser: (perm) async {
          askedOrder.add(perm);
          return perm == 'wanling.chat.read';
        },
        persist: (g) async => persistedSets.add(Set.of(g)),
      );
      expect(askedOrder, ['wanling.chat.read', 'wanling.chat.share']);
      expect(persistedSets, [
        {'wanling.chat.read'}
      ]);
      expect(effective, {'wanling.chat.read'});
    });

    test('拒绝全部 → persist 仍被调(落库含既有授权),返回集不含被拒项', () async {
      final persistedSets = <Set<String>>[];
      final effective = await runPermissionFlow(
        declared: {'wanling.api', 'wanling.chat.read'},
        granted: {'wanling.api'},
        askUser: (_) async => false,
        persist: (g) async => persistedSets.add(Set.of(g)),
      );
      expect(persistedSets, [
        {'wanling.api'}
      ]);
      expect(effective, {'wanling.api'});
    });

    test('wanling.api 不弹窗(askUser 不被调)但出现在生效集', () async {
      final asked = <String>[];
      final effective = await runPermissionFlow(
        declared: {'wanling.api'},
        granted: {},
        askUser: (perm) async {
          asked.add(perm);
          return false;
        },
        persist: (_) async {},
      );
      expect(asked, isEmpty);
      expect(effective, {'wanling.api'});
    });
  });
}
