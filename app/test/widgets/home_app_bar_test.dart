import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/user.dart';
import 'package:app/pages/home_page.dart';
import 'package:app/widgets/avatar.dart';

void main() {
  group('truncateBio', () {
    test('null → null', () {
      expect(truncateBio(null), isNull);
    });

    test('空字符串 → null', () {
      expect(truncateBio(''), isNull);
    });

    test('≤10 字原样返回', () {
      expect(truncateBio('万物有灵'), '万物有灵');
      expect(truncateBio('一二三四五六七八九十'), '一二三四五六七八九十');
    });

    test('>10 字取前 10 + …', () {
      expect(truncateBio('一二三四五六七八九十一'), '一二三四五六七八九十…');
    });

    test('emoji 按字素簇算 1 字', () {
      // 5 emoji + 6 字 = 11 字素簇
      expect(truncateBio('😀😃😄😁😆一二三四五六'), '😀😃😄😁😆一二三四五…');
    });
  });

  group('buildHomeAppBar', () {
    /// Avatar 是 ConsumerWidget，需 ProviderScope。
    /// 默认 ProviderScope 在 test 环境能跑（settingsProvider / authProvider
    /// 构造不触发平台调用，url=null 时不走网络）。见 avatar_test.dart 先例。
    Future<void> pumpAppBar(
      WidgetTester tester, {
      required bool isWanling,
      User? user,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              appBar: buildHomeAppBar(
                isWanling: isWanling,
                user: user,
                onScan: () {},
                onCreateAgent: () {},
              ),
            ),
          ),
        ),
      );
    }

    final baseUser = User(
      id: 'u1',
      username: 'kira',
      nickname: '羅宇',
      bio: '万物有灵',
      avatarUrl: null,
      createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
    );

    testWidgets('消息 tab：渲染头像 + 昵称 + 简介', (tester) async {
      await pumpAppBar(tester, isWanling: false, user: baseUser);
      expect(find.text('羅宇'), findsOneWidget);
      expect(find.text('万物有灵'), findsOneWidget);
      // Avatar 首字母 fallback
      expect(find.text('羅'), findsOneWidget);
    });

    testWidgets('消息 tab：无 nickname 时用 username', (tester) async {
      final u = User(
        id: 'u1',
        username: 'alice',
        nickname: null,
        createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
      );
      await pumpAppBar(tester, isWanling: false, user: u);
      expect(find.text('alice'), findsOneWidget);
    });

    testWidgets('消息 tab：bio 为空时不渲染简介行', (tester) async {
      final u = User(
        id: 'u1',
        username: 'kira',
        nickname: '羅宇',
        bio: null,
        createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
      );
      await pumpAppBar(tester, isWanling: false, user: u);
      expect(find.text('羅宇'), findsOneWidget);
      // 无简介：只有用户名 + Avatar 字母 = 2 个 Text
      expect(find.byType(Text), findsNWidgets(2));
    });

    testWidgets('消息 tab：bio >10 字截断 + …', (tester) async {
      final u = User(
        id: 'u1',
        username: 'kira',
        nickname: '羅宇',
        bio: '这是一段很长的简介文字超过十个字了',
        avatarUrl: null,
        createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
      );
      await pumpAppBar(tester, isWanling: false, user: u);
      expect(find.textContaining('…'), findsOneWidget);
    });

    testWidgets('万灵 tab：渲染头像 + 万灵标题', (tester) async {
      await pumpAppBar(tester, isWanling: true, user: baseUser);
      expect(find.text('万灵'), findsOneWidget);
      expect(find.text('羅'), findsOneWidget);
      // 不应有昵称
      expect(find.text('羅宇'), findsNothing);
    });

    testWidgets('user 为 null 时不崩溃', (tester) async {
      await pumpAppBar(tester, isWanling: false, user: null);
      // displayName='' → Avatar fallback '?'
      expect(find.text('?'), findsOneWidget);
    });

    testWidgets('头像可点击触发 onAvatarTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              appBar: buildHomeAppBar(
                isWanling: false,
                user: baseUser,
                onScan: () {},
                onCreateAgent: () {},
                onAvatarTap: () => tapped = true,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(Avatar));
      expect(tapped, isTrue);
    });
  });
}
