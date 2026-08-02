import 'package:app/models/msg_type.dart';
import 'package:flutter_test/flutter_test.dart';

/// MsgTypeX.preview 是消息预览的单一真相源,notification 与 conversation 列表共用。
///
/// 返回值约定:
/// - 非 null:调用方直接使用(通知 body / 列表预览)
/// - null:无固定文案(silent 类 / unknown / data 缺失),调用方按场景 fallback
///   - 通知 body fallback `[新消息]`
///   - 列表预览 fallback `''`(空串)
void main() {
  group('MsgTypeX.preview — text / markdown', () {
    test('text 取 data.text', () {
      expect(MsgTypeX.preview(MsgType.text, {'text': '你好'}), '你好');
    });

    test('text 截断 50 字符', () {
      final long = 'a' * 100;
      final result = MsgTypeX.preview(MsgType.text, {'text': long})!;
      expect(result.length, 50);
    });

    test('text data.text 为空返 null', () {
      expect(MsgTypeX.preview(MsgType.text, {'text': ''}), isNull);
    });

    test('text 无 data 返 null', () {
      expect(MsgTypeX.preview(MsgType.text, null), isNull);
    });

    test('markdown 走同样逻辑', () {
      expect(MsgTypeX.preview(MsgType.markdown, {'text': '# 标题'}), '# 标题');
    });
  });

  group('MsgTypeX.preview — 固定文案类', () {
    test('image 返 [图片]', () {
      expect(MsgTypeX.preview(MsgType.image, {}), '[图片]');
    });

    test('fileDiff 返 [文件变更]', () {
      expect(MsgTypeX.preview(MsgType.fileDiff, {}), '[文件变更]');
    });

    test('reasoning 返 [思考]', () {
      expect(MsgTypeX.preview(MsgType.reasoning, {}), '[思考]');
    });

    test('toolCall 返 [工具]', () {
      expect(MsgTypeX.preview(MsgType.toolCall, {}), '[工具]');
    });

    test('toolResult 返 [结果]', () {
      expect(MsgTypeX.preview(MsgType.toolResult, {}), '[结果]');
    });

    test('toolError 返 [错误]', () {
      expect(MsgTypeX.preview(MsgType.toolError, {}), '[错误]');
    });

    test('stepFinish 返 [完成]', () {
      expect(MsgTypeX.preview(MsgType.stepFinish, {}), '[完成]');
    });

    test('card 返 [审批]', () {
      expect(MsgTypeX.preview(MsgType.card, {}), '[审批]');
    });

    test('permissionCard 返 ⚡ 权限审批', () {
      expect(MsgTypeX.preview(MsgType.permissionCard, {}), '⚡ 权限审批');
    });

    test('questionCard 返 ❓ 选择题', () {
      expect(MsgTypeX.preview(MsgType.questionCard, {}), '❓ 选择题');
    });
  });

  group('MsgTypeX.preview — 带 data 提取类', () {
    test('file 带 filename 返 [文件] 文件名', () {
      expect(MsgTypeX.preview(MsgType.file, {'filename': 'a.pdf'}), '[文件] a.pdf');
    });

    test('file 缺 filename 返 [文件]', () {
      expect(MsgTypeX.preview(MsgType.file, {}), '[文件]');
    });

    test('toolCard 带 name 返 [工具] name', () {
      expect(MsgTypeX.preview(MsgType.toolCard, {'name': 'bash'}), '[工具] bash');
    });

    test('toolCard 缺 name 返 [工具]', () {
      expect(MsgTypeX.preview(MsgType.toolCard, {}), '[工具]');
    });

    test('tuiUser 带 text 返 [TUI] text', () {
      expect(MsgTypeX.preview(MsgType.tuiUser, {'text': 'hi'}), '[TUI] hi');
    });

    test('tuiUser 缺 text 返 [TUI]', () {
      expect(MsgTypeX.preview(MsgType.tuiUser, {}), '[TUI]');
    });

    test('slashEcho 带 text 返 [命令] text', () {
      expect(MsgTypeX.preview(MsgType.slashEcho, {'text': '/help'}), '[命令] /help');
    });

    test('slashEcho 缺 text 返 [命令]', () {
      expect(MsgTypeX.preview(MsgType.slashEcho, {}), '[命令]');
    });
  });

  group('MsgTypeX.preview — silent / 无固定文案类(返 null)', () {
    test('permissionReply 返 null(silent)', () {
      expect(MsgTypeX.preview(MsgType.permissionReply, {}), isNull);
    });

    test('questionReply 返 null(silent)', () {
      expect(MsgTypeX.preview(MsgType.questionReply, {}), isNull);
    });

    test('compactDivider 返 null(分隔符)', () {
      expect(MsgTypeX.preview(MsgType.compactDivider, {}), isNull);
    });

    test('mixed 返 null(调用方自定义)', () {
      expect(MsgTypeX.preview(MsgType.mixed, {}), isNull);
    });

    test('unknown 返 null', () {
      expect(MsgTypeX.preview(MsgType.unknown, {}), isNull);
    });
  });

  group('MsgTypeX.preview — 其他', () {
    test('subagent 返 [提问]', () {
      expect(MsgTypeX.preview(MsgType.subagent, {}), '[提问]');
    });

    test('question 返 [提问]', () {
      expect(MsgTypeX.preview(MsgType.question, {}), '[提问]');
    });
  });
}
