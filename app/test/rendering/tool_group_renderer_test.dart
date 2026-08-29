import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/rendering/tool_group_renderer.dart';
import 'package:wanling_core/widgets/chat/shimmer_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> tool(String id, String name, {String status = 'completed'}) {
  return {
    'type': 'tool_card',
    'element_id': id,
    'data': {'name': name, 'status': status, 'input': const {}},
  };
}

MessageRenderContext rc({
  bool streaming = false,
  bool isDark = false,
  void Function(GlobalKey key, bool expanded, double topDelta, bool isHistory)?
      onToolGroupToggle,
}) =>
    MessageRenderContext(
      isMe: false,
      baseUrl: '',
      token: '',
      isDark: isDark,
      isStreaming: streaming,
      onToolGroupToggle: onToolGroupToggle,
    );

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('groupAggregateElements 按折叠类别分组', () {
    test('同类连续合并:bash×2 → 1 个命令组', () {
      final groups = groupAggregateElements([tool('t1', 'bash'), tool('t2', 'bash')]);
      expect(groups.length, 1);
      expect(groups.first, isA<ToolGroupSlot>());
      expect((groups.first as ToolGroupSlot).cards.length, 2);
    });

    test('不同类别中断拆组:bash, read → 命令组+探索组', () {
      final groups = groupAggregateElements([tool('t1', 'bash'), tool('t2', 'read')]);
      expect(groups.length, 2);
      expect(((groups[0] as ToolGroupSlot).cards.single['data'] as Map)['name'], 'bash');
      expect(((groups[1] as ToolGroupSlot).cards.single['data'] as Map)['name'], 'read');
    });

    test('完整示例:[bash,bash,read,grep,bash,write,edit,read] → 5 组', () {
      final groups = groupAggregateElements([
        tool('t1', 'bash'), tool('t2', 'bash'), tool('t3', 'read'),
        tool('t4', 'grep'), tool('t5', 'bash'), tool('t6', 'write'),
        tool('t7', 'edit'), tool('t8', 'read'),
      ]);
      expect(groups.length, 5);
      final sizes = groups.map((g) => (g as ToolGroupSlot).cards.length).toList();
      expect(sizes, [2, 2, 1, 2, 1]);
    });

    test('read+grep 同组但计数分读取/搜索(单条也折叠)', () {
      final groups = groupAggregateElements([tool('t1', 'read')]);
      expect(groups.length, 1);
      expect(groups.first, isA<ToolGroupSlot>());
      expect((groups.first as ToolGroupSlot).cards.length, 1);
    });

    test('hermes 工具名折叠:terminal/read_file/search_files 映射到对应类别', () {
      final groups = groupAggregateElements([
        tool('t1', 'terminal'), tool('t2', 'terminal'),
        tool('t3', 'read_file'), tool('t4', 'search_files'),
      ]);
      expect(groups.length, 2); // 命令组(2) + 探索组(2)
      final t0 = groups[0] as ToolGroupSlot;
      final t1 = groups[1] as ToolGroupSlot;
      expect(t0.cards.length, 2);
      expect(t1.cards.length, 2);
    });

    test('hermes read_file/search_files 标题计数读取/搜索', () {
      final g = groupAggregateElements([tool('t1', 'read_file'), tool('t2', 'search_files')]);
      expect(g.length, 1);
      expect(groupTitle(g.single as ToolGroupSlot, false), '已探索 1次读取, 1次搜索');
    });

    test('hermes browser_navigate 折叠进探索组', () {
      final groups = groupAggregateElements([tool('t1', 'browser_navigate'), tool('t2', 'browser_snapshot')]);
      expect(groups.length, 1);
      expect(groups.first, isA<ToolGroupSlot>());
      expect(categoryOfTool((groups[0] as ToolGroupSlot).cards.first), ToolCategory.explore);
    });

    test('前缀通用规则:browser_* 新工具名自动折叠进 browser 组', () {
      final groups = groupAggregateElements([
        tool('t1', 'browser_click'), tool('t2', 'browser_type'),
        tool('t3', 'browser_scroll'),
      ]);
      expect(groups.length, 1);
      expect(groups.first, isA<ToolGroupSlot>());
      expect((groups.first as ToolGroupSlot).cards.length, 3);
      expect(groupTitle(groups.first as ToolGroupSlot, false), '已探索 3次搜索');
    });

    test('前缀通用规则:browser_* 与 read/search 连续同类合并', () {
      final groups = groupAggregateElements([
        tool('t1', 'browser_click'), tool('t2', 'browser_press'),
        tool('t3', 'read_file'), tool('t4', 'search_remote'),
      ]);
      // browser+read+search 都归 explore 类别 → 连续合并成 1 组
      expect(groups.length, 1);
      expect((groups.first as ToolGroupSlot).cards.length, 4);
    });

    test('前缀通用规则:edit_*/write_* 折叠进编辑组', () {
      final groups = groupAggregateElements([tool('t1', 'edit_file'), tool('t2', 'write_config')]);
      expect(groups.length, 1);
      expect(groups.first, isA<ToolGroupSlot>());
      expect(categoryOfTool((groups[0] as ToolGroupSlot).cards.first), ToolCategory.edit);
    });

    test('前缀通用规则:terminal*/execute* 折叠进命令组', () {
      final groups = groupAggregateElements([tool('t1', 'terminal_run'), tool('t2', 'execute_code')]);
      expect(groups.length, 1);
      expect(categoryOfTool((groups[0] as ToolGroupSlot).cards.first), ToolCategory.command);
    });

    test('todowrite 平铺不折叠(不再隐藏)', () {
      final groups = groupAggregateElements([tool('t1', 'todowrite'), tool('t2', 'read')]);
      expect(groups.length, 2);
      expect(groups[0], isA<SingleElementSlot>());
      expect(((groups[0] as SingleElementSlot).element['data'] as Map)['name'], 'todowrite');
      expect(groups[1], isA<ToolGroupSlot>());
    });

    test('webfetch/task 平铺不折叠', () {
      final groups = groupAggregateElements([tool('t1', 'webfetch'), tool('t2', 'read')]);
      expect(groups.length, 2);
      expect(groups[0], isA<SingleElementSlot>());
      expect(groups[1], isA<ToolGroupSlot>());
    });

    test('被 markdown 隔开的两组 read 拆成两组', () {
      final groups = groupAggregateElements([
        tool('t1', 'read'),
        {'type': 'markdown', 'element_id': 'm1', 'data': {'text': 'x'}},
        tool('t2', 'read'),
      ]);
      expect(groups.length, 3);
      expect(groups[0], isA<ToolGroupSlot>());
      expect(groups[1], isA<SingleElementSlot>());
      expect(groups[2], isA<ToolGroupSlot>());
    });

    test('task 子 agent 卡平铺(不折叠)', () {
      final groups = groupAggregateElements([tool('t1', 'task', status: 'completed')]);
      expect(groups.length, 1);
      expect(groups.first, isA<SingleElementSlot>());
    });

    test('未知工具名(MCP 开放集合)默认折叠进工具组', () {
      final groups = groupAggregateElements([
        tool('t1', 'zai-mcp-server_analyze_image'),
        tool('t2', 'lark-im_send_message'),
      ]);
      expect(groups.length, 1);
      expect(groups.first, isA<ToolGroupSlot>());
      expect((groups.first as ToolGroupSlot).cards.length, 2);
      expect(
          categoryOfTool((groups.first as ToolGroupSlot).cards.first),
          ToolCategory.tool);
    });

    test('未知工具与已知类别相邻拆组:zai-*, bash → 工具组+命令组', () {
      final groups = groupAggregateElements([
        tool('t1', 'zai-mcp-server_analyze_image'), tool('t2', 'bash'),
      ]);
      expect(groups.length, 2);
      expect(
          categoryOfTool((groups[0] as ToolGroupSlot).cards.first),
          ToolCategory.tool);
      expect(
          categoryOfTool((groups[1] as ToolGroupSlot).cards.first),
          ToolCategory.command);
    });

    test('空名工具卡防御性平铺', () {
      final groups = groupAggregateElements([tool('t1', '')]);
      expect(groups.length, 1);
      expect(groups.first, isA<SingleElementSlot>());
    });
  });

  group('ToolGroupCard 标题', () {
    testWidgets('探索组完成态:已探索 3次读取, 2次搜索', (tester) async {
      final cards = [
        tool('r1', 'read'), tool('r2', 'read'), tool('r3', 'read'),
        tool('g1', 'grep'), tool('g2', 'grep'),
      ];
      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: rc())));
      expect(find.text('已探索 3次读取, 2次搜索'), findsOneWidget);
    });

    testWidgets('探索组进行中:正在探索 1次读取, 2次搜索(glob+grep)', (tester) async {
      final cards = [tool('r1', 'read'), tool('g1', 'glob'), tool('g2', 'grep')];
      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: rc(streaming: true))));
      final shimmer = tester.widget<ShimmerText>(find.byType(ShimmerText));
      expect(shimmer.text, '正在探索 1次读取, 2次搜索');
    });

    testWidgets('命令组:已执行 2次命令', (tester) async {
      final cards = [tool('b1', 'bash'), tool('b2', 'bash')];
      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: rc())));
      expect(find.text('已执行 2次命令'), findsOneWidget);
    });

    testWidgets('命令组进行中:正在执行 1次命令', (tester) async {
      final cards = [tool('b1', 'bash')];
      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: rc(streaming: true))));
      final shimmer = tester.widget<ShimmerText>(find.byType(ShimmerText));
      expect(shimmer.text, '正在执行 1次命令');
    });

    testWidgets('编辑组:已编辑 2次编辑(edit+write)', (tester) async {
      final cards = [tool('e1', 'edit'), tool('w1', 'write')];
      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: rc())));
      expect(find.text('已编辑 2次编辑'), findsOneWidget);
    });

    testWidgets('工具组:已执行 2次工具(未知 MCP 工具)', (tester) async {
      final cards = [
        tool('t1', 'zai-mcp-server_analyze_image'),
        tool('t2', 'lark-im_send_message'),
      ];
      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: rc())));
      expect(find.text('已执行 2次工具'), findsOneWidget);
    });

    testWidgets('工具组进行中:正在执行 1次工具', (tester) async {
      final cards = [tool('t1', 'zai-mcp-server_analyze_image')];
      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: rc(streaming: true))));
      final shimmer = tester.widget<ShimmerText>(find.byType(ShimmerText));
      expect(shimmer.text, '正在执行 1次工具');
    });

    testWidgets('工具组图标用 tools 字形(e882)', (tester) async {
      final cards = [tool('t1', 'zai-mcp-server_analyze_image')];
      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: rc())));
      expect(find.text('\u{e882}'), findsOneWidget);
    });

    testWidgets('进行中标题含 ShimmerText', (tester) async {
      final cards = [tool('r1', 'read')];
      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: rc(streaming: true))));
      expect(find.byType(ShimmerText), findsWidgets);
    });

    testWidgets('完成态不含 ShimmerText', (tester) async {
      final cards = [tool('r1', 'read')];
      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: rc())));
      expect(find.byType(ShimmerText), findsNothing);
    });

    testWidgets('点击展开触发 onToolGroupToggle(带 key/expanded/topDelta/isHistory)', (tester) async {
      final cards = [tool('r1', 'read')];
      GlobalKey? cbKey;
      bool? cbExpanded;
      double? cbTopDelta;
      bool? cbIsHistory;
      final ctx = rc(onToolGroupToggle: (k, e, delta, isHistory) {
        cbKey = k;
        cbExpanded = e;
        cbTopDelta = delta;
        cbIsHistory = isHistory;
      });
      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: ctx)));
      await tester.tap(find.text('已探索 1次读取'));
      await tester.pump();
      expect(cbKey, isNotNull);
      expect(cbExpanded, isTrue);
      // 展开:topDelta = -内容高度(history 反向向上长),为负
      expect(cbTopDelta, isA<double>());
      expect(cbTopDelta!, lessThan(0));
      expect(cbIsHistory, isFalse); // 默认 live/非 history
    });
  });

  group('深色模式灰阶反转', () {
    testWidgets('isDark=true:完成态标题 0xFFC8C8C8,展开箭头 0xFF777777', (tester) async {
      final cards = [tool('r1', 'read')];
      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: rc(isDark: true))));
      final text = tester.widget<Text>(find.text('已探索 1次读取'));
      expect(text.style!.color, const Color(0xFFC8C8C8));
      // 组内唯一 Icon 是展开箭头(IconFont 是 Text 实现)
      final arrow = tester.widget<Icon>(find.byType(Icon));
      expect(arrow.color, const Color(0xFF777777));
    });

    testWidgets('isDark=true:进行中 ShimmerText baseColor 0xFFAAAAAA', (tester) async {
      final cards = [tool('r1', 'read')];
      await tester.pumpWidget(
          host(ToolGroupCard(cards: cards, rc: rc(isDark: true, streaming: true))));
      final shimmer = tester.widget<ShimmerText>(find.byType(ShimmerText));
      expect(shimmer.baseColor, const Color(0xFFAAAAAA));
      expect(shimmer.style.color, const Color(0xFFAAAAAA));
    });

    testWidgets('浅色回归:标题 0xFF555555,箭头 0xFFBBBBBB,闪烁字 0xFF666666', (tester) async {
      final cards = [tool('r1', 'read')];
      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: rc())));
      final text = tester.widget<Text>(find.text('已探索 1次读取'));
      expect(text.style!.color, const Color(0xFF555555));
      expect(tester.widget<Icon>(find.byType(Icon)).color,
          const Color(0xFFBBBBBB));

      await tester.pumpWidget(host(ToolGroupCard(cards: cards, rc: rc(streaming: true))));
      final shimmer = tester.widget<ShimmerText>(find.byType(ShimmerText));
      expect(shimmer.baseColor, const Color(0xFF666666));
    });
  });
}
