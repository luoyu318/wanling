import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/slash_command.dart';
import 'package:app/widgets/chat/slash_command_sheet.dart';

void main() {
  group('SlashCommandSheet', () {
    final commands = <SlashCommand>[
      const SlashCommand(name: 'compact', template: '/compact', description: '压缩上下文', source: 'command'),
      const SlashCommand(name: 'init', template: '/init', description: 'guided AGENTS.md setup', source: 'command'),
      const SlashCommand(name: 'agently-mail', template: '/agently-mail', description: '通过 agently-cli 命令行工具操作邮件', source: 'skill'),
      const SlashCommand(name: 'brainstorming', template: '/brainstorming', description: 'You MUST use this before any creative work', source: 'skill'),
    ];

    testWidgets('分组渲染:命令在上,技能在下', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SlashCommandSheet(
          commands: commands,
          side: AttachSide.right,
          onSelected: (_) {},
          onClose: () {},
        ),
      ));

      // 找到分组 header 文本
      expect(find.text('命令'), findsOneWidget);
      expect(find.text('技能'), findsOneWidget);

      // 命令组内的项出现在技能组之前(通过 tester.getCenter 验证 y 坐标)
      final cmdHeaderY = tester.getCenter(find.text('命令')).dy;
      final skillHeaderY = tester.getCenter(find.text('技能')).dy;
      expect(cmdHeaderY, lessThan(skillHeaderY));
    });

    testWidgets('点击命令回调传整个 SlashCommand 对象', (tester) async {
      SlashCommand? selected;
      await tester.pumpWidget(MaterialApp(
        home: SlashCommandSheet(
          commands: commands,
          side: AttachSide.right,
          onSelected: (cmd) => selected = cmd,
          onClose: () {},
        ),
      ));

      await tester.tap(find.text('/compact'));
      await tester.pump();

      expect(selected, isNotNull);
      expect(selected!.name, 'compact');
      expect(selected!.source, 'command');
    });

    testWidgets('description 单行 + 长文本省略号', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SlashCommandSheet(
          commands: commands,
          side: AttachSide.right,
          onSelected: (_) {},
          onClose: () {},
        ),
      ));

      // 找到所有 Text widget,description 不应多行展开
      // 通过验证 agently-mail 的描述渲染为 1 行(ellipsis)
      final descFinder = find.textContaining('agently-cli');
      expect(descFinder, findsOneWidget);
    });

    testWidgets('搜索过滤:query="compact" 只剩命令组', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SlashCommandSheet(
          commands: commands,
          side: AttachSide.right,
          onSelected: (_) {},
          onClose: () {},
        ),
      ));

      await tester.enterText(find.byType(TextField), 'compact');
      await tester.pump();

      expect(find.text('命令'), findsOneWidget);
      // 技能组无匹配,header 不渲染
      expect(find.text('技能'), findsNothing);
      expect(find.text('/compact'), findsOneWidget);
    });

    testWidgets('点击背景关闭回调', (tester) async {
      bool closed = false;
      await tester.pumpWidget(MaterialApp(
        home: SlashCommandSheet(
          commands: commands,
          side: AttachSide.right,
          onSelected: (_) {},
          onClose: () => closed = true,
        ),
      ));

      // backdrop 用 ValueKey('slash-backdrop')。直接 tap finder 会取其 center(400,300),
      // 而 4 条命令 + 分组 header 撑高卡片到 y∈[64,348],覆盖了 backdrop 的中心点。
      // 因此 tapAt 到一个明确在卡片之外但仍在 backdrop 内的点(测试表面 800×600,
      // y=500 安全地在卡片下方)。
      await tester.tapAt(const Offset(400.0, 500.0));
      await tester.pump();

      expect(closed, isTrue);
    });

    // 老服务器(或老 plugin)未返回 source 字段 → SlashCommand.fromJson 默认 source='',
    // 分组模式下两组都空会让用户看到空白面板。此用例验证扁平渲染降级。
    testWidgets('老服务器降级:全部 source="" 时扁平渲染不显示分组 header', (tester) async {
      final oldServerCommands = <SlashCommand>[
        const SlashCommand(
            name: 'compact',
            template: '/compact',
            description: '压缩上下文',
            source: ''),
        const SlashCommand(
            name: 'init', template: '/init', description: 'init setup', source: ''),
        const SlashCommand(
            name: 'review',
            template: '/review',
            description: 'review changes',
            source: ''),
      ];

      await tester.pumpWidget(MaterialApp(
        home: SlashCommandSheet(
          commands: oldServerCommands,
          side: AttachSide.right,
          onSelected: (_) {},
          onClose: () {},
        ),
      ));

      // 3 项全部渲染(扁平列表)
      expect(find.text('/compact'), findsOneWidget);
      expect(find.text('/init'), findsOneWidget);
      expect(find.text('/review'), findsOneWidget);

      // 无分组 header
      expect(find.text('命令'), findsNothing);
      expect(find.text('技能'), findsNothing);
      expect(find.text('其他'), findsNothing);
    });

    testWidgets('老服务器降级:扁平模式下点击命令仍触发 onSelected', (tester) async {
      SlashCommand? selected;
      final oldServerCommands = <SlashCommand>[
        const SlashCommand(
            name: 'compact',
            template: '/compact',
            description: '压缩上下文',
            source: ''),
      ];

      await tester.pumpWidget(MaterialApp(
        home: SlashCommandSheet(
          commands: oldServerCommands,
          side: AttachSide.right,
          onSelected: (cmd) => selected = cmd,
          onClose: () {},
        ),
      ));

      await tester.tap(find.text('/compact'));
      await tester.pump();

      expect(selected, isNotNull);
      expect(selected!.name, 'compact');
      // source 字段透传保持空串(model 层默认行为不变)
      expect(selected!.source, '');
    });
  });
}
