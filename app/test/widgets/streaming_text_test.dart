import 'package:app/widgets/streaming_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host({
    required String text,
    required bool streaming,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: StreamingText(
          text: text,
          streaming: streaming,
          mdBuilder: (t) => Text('⟪$t⟫'),
        ),
      ),
    );
  }

  testWidgets('流式期间整段走 mdBuilder,不拆分 settled/tail', (tester) async {
    await tester.pumpWidget(host(text: '**加粗**内容', streaming: true));

    // 整段文本一次渲染,无拆分(源码不暴露、无双块断裂)
    expect(find.text('⟪**加粗**内容⟫'), findsOneWidget);
  });

  testWidgets('流式期间无渐显动画容器(不闪不抖)', (tester) async {
    await tester.pumpWidget(host(text: 'abc', streaming: true));

    // StreamingText 不再创建 Opacity 渐显(拆块动画已移除)。
    // 注意:MaterialApp/Scaffold 内部自带 AnimatedBuilder(ValueNotifier),
    // 不能据它断言;只验证没有我们引入的 Opacity 容器。
    final opacityUnderStream = find.byWidgetPredicate(
      (w) => w is Opacity && w.opacity < 1.0,
    );
    expect(opacityUnderStream, findsNothing);
  });

  testWidgets('非流式同样走 mdBuilder,与流式一致', (tester) async {
    await tester.pumpWidget(host(text: '`code` 行', streaming: false));

    expect(find.text('⟪`code` 行⟫'), findsOneWidget);
  });

  testWidgets('markdown 语法跨 delta 不断裂(整段完整渲染)', (tester) async {
    // 模拟流式增量:每次 text 变化都是完整累积,整段渲染
    final builder = MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => const _StreamingHost(text: '**加'),
        ),
      ),
    );
    await tester.pumpWidget(builder);
    expect(find.text('⟪**加⟫'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => const _StreamingHost(text: '**加粗**abc'),
          ),
        ),
      ),
    );
    expect(find.text('⟪**加粗**abc⟫'), findsOneWidget);
  });
}

class _StreamingHost extends StatelessWidget {
  final String text;
  const _StreamingHost({required this.text});
  @override
  Widget build(BuildContext context) {
    return StreamingText(
      text: text,
      streaming: true,
      mdBuilder: (t) => Text('⟪$t⟫'),
    );
  }
}
