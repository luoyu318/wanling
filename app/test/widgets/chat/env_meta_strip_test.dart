import 'package:app/widgets/chat/env_meta_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('cwd + gitBranch 都有,渲染 basename + branch', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: EnvMetaStrip(cwd: '/home/user/projects/foo', gitBranch: 'main'),
      ),
    ));
    expect(find.textContaining('foo'), findsOneWidget);
    expect(find.textContaining('main'), findsOneWidget);
  });

  testWidgets('gitBranch 为 null,只渲染 cwd', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: EnvMetaStrip(cwd: '/tmp/plain')),
    ));
    expect(find.textContaining('plain'), findsOneWidget);
    expect(find.textContaining('⎇'), findsNothing);
  });

  testWidgets('cwd 为 null,返回 SizedBox.shrink', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: EnvMetaStrip(cwd: null, gitBranch: 'main')),
    ));
    expect(find.byType(SizedBox), findsWidgets);
    expect(find.textContaining('main'), findsNothing);
  });

  testWidgets('cwd 不含 / 原样显示', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: EnvMetaStrip(cwd: 'plainname')),
    ));
    expect(find.textContaining('plainname'), findsOneWidget);
  });

  group('EnvMetaStrip token 段渲染', () {
    Future<void> pumpStrip(
      WidgetTester tester, {
      String? cwd,
      String? gitBranch,
      int? tokensTotal,
      int? contextUsed,
      int? contextLimit,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EnvMetaStrip(
            cwd: cwd,
            gitBranch: gitBranch,
            tokensTotal: tokensTotal,
            contextUsed: contextUsed,
            contextLimit: contextLimit,
          ),
        ),
      ));
    }

    testWidgets('有 contextUsed 数据 → 渲染 used + pct', (tester) async {
      await pumpStrip(
        tester,
        cwd: '/home/u/chat',
        gitBranch: 'develop',
        tokensTotal: 1200000, // 仍传,但不再渲染
        contextUsed: 16935,
        contextLimit: 1000000,
      );
      expect(find.textContaining('16.9k'), findsOneWidget); // 16935 → "16.9k"(1 位小数)
      expect(find.textContaining('2%'), findsOneWidget); // 1.69% → round 2%
      // tokensTotal 不再渲染
      expect(find.textContaining('1.2M'), findsNothing);
    });

    testWidgets('contextUsed 缺失 → 不渲染 token 段(即使 tokensTotal 有值)', (tester) async {
      await pumpStrip(
        tester,
        cwd: '/home/u/chat',
        gitBranch: 'develop',
        tokensTotal: 1200000, // 有值,但 contextUsed 缺
        // contextUsed: null
        contextLimit: 1000000,
      );
      expect(find.textContaining('chat'), findsOneWidget);
      expect(find.textContaining('develop'), findsOneWidget);
      expect(find.textContaining('1.2M'), findsNothing);
      expect(find.textContaining('M'), findsNothing);
      expect(find.textContaining('k'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('contextLimit=0 → 只显示 used,不显示百分比', (tester) async {
      await pumpStrip(
        tester,
        cwd: '/home/u/chat',
        gitBranch: 'develop',
        contextUsed: 5000,
        contextLimit: 0,
      );
      expect(find.textContaining('5k'), findsWidgets);
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('contextUsed 格式化:< 1000 显示原值,≥1000 显示 k,≥1M 显示 M', (tester) async {
      // 999
      await pumpStrip(tester, cwd: '/p', contextUsed: 999, contextLimit: 1);
      expect(find.textContaining('999'), findsWidgets);
      // 1234 → 1.2k
      await pumpStrip(tester, cwd: '/p', contextUsed: 1234, contextLimit: 1);
      expect(find.textContaining('1.2k'), findsWidgets);
      // 1234567 → 1.2M
      await pumpStrip(tester, cwd: '/p', contextUsed: 1234567, contextLimit: 1);
      expect(find.textContaining('1.2M'), findsWidgets);
    });
  });

  group('EnvMetaStrip onTapCwd', () {
    testWidgets('onTapCwd 非 null → 图标变蓝', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EnvMetaStrip(
            cwd: '/home/user/foo',
            onTapCwd: () {},
          ),
        ),
      ));

      final icon = tester.widget<Icon>(find.byIcon(Icons.folder_outlined));
      expect(icon.color, const Color(0xFF5B7CFA));
    });

    testWidgets('onTapCwd 为 null → 图标保持灰色', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: EnvMetaStrip(cwd: '/home/user/foo'),
        ),
      ));

      final icon = tester.widget<Icon>(find.byIcon(Icons.folder_outlined));
      expect(icon.color, const Color(0xFF999999));
    });

    testWidgets('点击 cwd 文字触发 onTapCwd 回调', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EnvMetaStrip(
            cwd: '/home/user/foo',
            onTapCwd: () => tapped = true,
          ),
        ),
      ));

      await tester.tap(find.textContaining('foo'));
      await tester.pump();

      expect(tapped, isTrue);
    });
  });

  group('EnvMetaStrip onTapGitBranch', () {
    testWidgets('onTapGitBranch 非 null → gitBranch 图标变蓝', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EnvMetaStrip(
            cwd: '/home/user/foo',
            gitBranch: 'main',
            onTapGitBranch: () {},
          ),
        ),
      ));

      final icon = tester.widget<Icon>(find.byIcon(Icons.call_split));
      expect(icon.color, const Color(0xFF5B7CFA));
    });

    testWidgets('onTapGitBranch 为 null → gitBranch 图标保持灰色', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: EnvMetaStrip(cwd: '/home/user/foo', gitBranch: 'main'),
        ),
      ));

      final icon = tester.widget<Icon>(find.byIcon(Icons.call_split));
      expect(icon.color, const Color(0xFF999999));
    });

    testWidgets('点击 gitBranch 段触发 onTapGitBranch 回调', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EnvMetaStrip(
            cwd: '/home/user/foo',
            gitBranch: 'main',
            onTapGitBranch: () => tapped = true,
          ),
        ),
      ));

      await tester.tap(find.textContaining('main'));
      await tester.pump();

      expect(tapped, isTrue);
    });
  });

  testWidgets('超长内容包裹横向 SingleChildScrollView 可滚动', (tester) async {
    final longBranch =
        'feature/very-long-branch-name-${List.filled(30, 'x').join('')}';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          child: EnvMetaStrip(
            cwd: '/home/user/projects/${longBranch}',
            gitBranch: longBranch,
            contextUsed: 123456,
            contextLimit: 1000000,
          ),
        ),
      ),
    ));

    final scrollView = find.byWidgetPredicate(
      (w) =>
          w is SingleChildScrollView &&
          w.scrollDirection == Axis.horizontal,
    );
    expect(scrollView, findsOneWidget);

    final position = tester
        .widget<SingleChildScrollView>(scrollView)
        .scrollDirection;
    expect(position, Axis.horizontal);
  });
}
