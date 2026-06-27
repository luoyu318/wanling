import 'package:app/widgets/feedback/app_text_selection_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('渲染深色胶囊 + 4 个菜单项', (tester) async {
    final buttonItems = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        label: '剪切',
        onPressed: () {},
        type: ContextMenuButtonType.cut,
      ),
      ContextMenuButtonItem(
        label: '复制',
        onPressed: () {},
        type: ContextMenuButtonType.copy,
      ),
      ContextMenuButtonItem(
        label: '全选',
        onPressed: () {},
        type: ContextMenuButtonType.selectAll,
      ),
      ContextMenuButtonItem(
        label: '粘贴',
        onPressed: () {},
        type: ContextMenuButtonType.paste,
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        // 生产路径下 AdaptiveTextSelectionToolbar 用 CompositedTransformFollower
        // 包装此组件（不提供 Stack），故不能在顶层用 Positioned.fill。
        body: AppTextSelectionToolbar(
          buttonItems: buttonItems,
          anchors: const TextSelectionToolbarAnchors(
            primaryAnchor: Offset(100, 100),
          ),
        ),
      ),
    ));

    expect(find.text('剪切'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.text('粘贴'), findsOneWidget);
  });

  testWidgets('点击菜单项触发回调', (tester) async {
    var cutTapped = false;
    final buttonItems = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        label: '剪切',
        onPressed: () => cutTapped = true,
        type: ContextMenuButtonType.cut,
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppTextSelectionToolbar(
          buttonItems: buttonItems,
          anchors: const TextSelectionToolbarAnchors(
            primaryAnchor: Offset(100, 100),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('剪切'));
    await tester.pump();
    expect(cutTapped, isTrue);
  });

  // 回归：Flutter 给的标准 item（cut/copy/paste/selectAll）默认 label 是 null，
  // 只填 type。之前直接 label ?? '' 会渲染成「全是空内容」。修复后用硬编码中文
  // label 按 type 兜底（剪切/复制/粘贴/全选），不依赖 MaterialLocalizations。
  testWidgets('label=null 的标准 item 走硬编码中文 label', (tester) async {
    final buttonItems = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.cut,
      ),
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.copy,
      ),
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.paste,
      ),
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.selectAll,
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppTextSelectionToolbar(
          buttonItems: buttonItems,
          anchors: const TextSelectionToolbarAnchors(
            primaryAnchor: Offset(100, 100),
          ),
        ),
      ),
    ));

    // 确认渲染出的就是硬编码中文 label
    expect(find.text('剪切'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('粘贴'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
  });

  // 回归：某些 SDK 版本下 item.label 是空字符串而非 null（之前 ?? 只兜底 null，
  // 空字符串会原样通过 where(isNotEmpty) 被过滤，导致按钮丢失）。修复后空字符串
  // 也走硬编码兜底。
  testWidgets('label 为空字符串时也走硬编码兜底', (tester) async {
    final buttonItems = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        label: '',
        onPressed: () {},
        type: ContextMenuButtonType.copy,
      ),
      ContextMenuButtonItem(
        label: '',
        onPressed: () {},
        type: ContextMenuButtonType.cut,
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppTextSelectionToolbar(
          buttonItems: buttonItems,
          anchors: const TextSelectionToolbarAnchors(
            primaryAnchor: Offset(100, 100),
          ),
        ),
      ),
    ));

    // 空字符串也应走兜底，渲染出中文 label
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('剪切'), findsOneWidget);
  });

  // 回归：custom 类型未给 label 的 item 应被过滤掉（避免渲染空按钮 + 空分隔线）
  testWidgets('custom 类型空 label 的 item 被过滤掉', (tester) async {
    final buttonItems = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        label: '复制',
        onPressed: () {},
        type: ContextMenuButtonType.copy,
      ),
      // custom + 空 label：应被过滤
      ContextMenuButtonItem(
        onPressed: () {},
        type: ContextMenuButtonType.custom,
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppTextSelectionToolbar(
          buttonItems: buttonItems,
          anchors: const TextSelectionToolbarAnchors(
            primaryAnchor: Offset(100, 100),
          ),
        ),
      ),
    ));

    expect(find.text('复制'), findsOneWidget);
    // 只剩 1 个有效 item，分隔线数量 = item - 1 = 0
    final dividers = tester.widgetList<Container>(
      find.byWidgetPredicate((w) =>
          w is Container && (w.constraints?.maxWidth ?? double.infinity) <= 1),
    );
    expect(dividers, isEmpty);
  });
}
