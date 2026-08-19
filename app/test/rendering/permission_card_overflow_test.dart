import 'package:app/rendering/builtin_renderers.dart';
import 'package:app/rendering/message_content_renderer.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    ContentRendererRegistry.reset();
    registerBuiltinRenderers();
  });

  Widget host(Map<String, dynamic> data) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ContentRendererRegistry.render(
            MsgType.permissionCard,
            {'msg_type': MsgType.permissionCard.value, 'data': data},
            ctx,
            MessageRenderContext(
              isMe: false,
              baseUrl: 'http://localhost',
              token: 'test',
              isDark: false,
              isStreaming: false,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('pending 权限卡超长 command 不横向溢出', (tester) async {
    await tester.pumpWidget(host({
      'status': 'pending',
      'action': 'terminal',
      'metadata': {'command': 'cat ' * 200},
    }));
    expect(tester.takeException(), isNull, reason: '长 command 不应产生 RenderFlex/RenderBox overflow');
  });

  testWidgets('pending 权限卡超长无空格命令不横向溢出', (tester) async {
    await tester.pumpWidget(host({
      'status': 'pending',
      'action': 'terminal',
      'metadata': {'command': 'https://example.com/' + 'x' * 800},
    }));
    expect(tester.takeException(), isNull, reason: '无空格长串不应横向溢出');
  });

  testWidgets('pending 权限卡超长 action label 不横向溢出', (tester) async {
    await tester.pumpWidget(host({
      'status': 'pending',
      'action': 'browser_' + 'x' * 200,
      'resources': ['rm -rf /'],
    }));
    expect(tester.takeException(), isNull, reason: '超长 action label 不应横向溢出');
  });

  testWidgets('pending 权限卡超长 resources 不横向溢出', (tester) async {
    await tester.pumpWidget(host({
      'status': 'pending',
      'action': 'bash',
      'resources': ['/a/b/c/' + 'y' * 500],
    }));
    expect(tester.takeException(), isNull, reason: '超长 resources 不应横向溢出');
  });

  testWidgets('终态折叠卡超长 action label 不横向溢出', (tester) async {
    await tester.pumpWidget(host({
      'status': 'approved',
      'action': 'browser_' + 'x' * 200,
      'result': 'once',
      'metadata': <String, dynamic>{},
    }));
    expect(tester.takeException(), isNull, reason: '终态折叠标题超长 label 不应横向溢出');
  });
}
