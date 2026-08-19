import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wanling_core/models/conversation.dart';
import 'package:app/providers/chat_state.dart' show ModelOverride;
import 'package:app/widgets/chat/session_meta_strip.dart';

SessionMeta mkMeta({
  String mode = '',
  String modelId = '',
  String providerId = '',
  String? modelName,
  String? providerName,
  String? variant,
}) {
  return SessionMeta(
    mode: mode,
    modelId: modelId,
    providerId: providerId,
    modelName: modelName,
    providerName: providerName,
    variant: variant,
  );
}

Future<void> pumpIt(
  WidgetTester tester, {
  required SessionMeta meta,
  String? modeOverride,
  VoidCallback? onModeTap,
  ModelOverride? modelOverride,
  VoidCallback? onModelTap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SessionMetaStrip(
          meta: meta,
          modeOverride: modeOverride,
          onModeTap: onModeTap,
          modelOverride: modelOverride,
          onModelTap: onModelTap,
        ),
      ),
    ),
  );
}

void main() {
  group('SessionMetaStrip', () {
    testWidgets('mode=build 显示 Build 蓝色', (tester) async {
      await pumpIt(
        tester,
        meta: mkMeta(mode: 'build', modelId: '', providerId: ''),
      );
      expect(find.textContaining('Build'), findsOneWidget);
    });

    testWidgets('mode=plan 显示 Plan 橙色', (tester) async {
      await pumpIt(
        tester,
        meta: mkMeta(mode: 'plan', modelId: '', providerId: ''),
      );
      expect(find.textContaining('Plan'), findsOneWidget);
    });

    testWidgets('modeOverride 非空覆盖 meta.mode', (tester) async {
      await pumpIt(
        tester,
        meta: mkMeta(mode: 'build', modelId: '', providerId: ''),
        modeOverride: 'plan',
      );
      expect(find.textContaining('Plan'), findsOneWidget);
      expect(find.textContaining('Build'), findsNothing);
    });

    testWidgets('modelId + providerId 都显示(后者格式化)', (tester) async {
      await pumpIt(
        tester,
        meta: mkMeta(
          mode: 'build',
          modelId: 'glm-5.2',
          providerId: 'zhipuai-coding-plan',
        ),
      );
      expect(find.textContaining('Build'), findsOneWidget);
      expect(find.textContaining('glm-5.2'), findsOneWidget);
      expect(find.textContaining('Zhipuai'), findsOneWidget);
    });

    testWidgets('variant=default 不显示', (tester) async {
      await pumpIt(
        tester,
        meta: mkMeta(
          mode: 'build',
          modelId: 'glm-5.2',
          providerId: 'zhipuai',
          variant: 'default',
        ),
      );
      expect(find.textContaining('default'), findsNothing);
    });

    testWidgets('variant=非默认 显示', (tester) async {
      await pumpIt(
        tester,
        meta: mkMeta(
          mode: 'build',
          modelId: 'glm-5.2',
          providerId: 'zhipuai',
          variant: 'max',
        ),
      );
      expect(find.textContaining('max'), findsOneWidget);
    });

    testWidgets('modelName/providerName 优先于 modelId/providerId',
        (tester) async {
      await pumpIt(
        tester,
        meta: mkMeta(
          mode: 'build',
          modelId: 'glm-5.2',
          providerId: 'zhipuai-coding-plan',
          modelName: 'GLM 5.2',
          providerName: 'Zhipu AI',
        ),
      );
      expect(find.textContaining('GLM 5.2'), findsOneWidget);
      expect(find.textContaining('Zhipu AI'), findsOneWidget);
      expect(find.textContaining('glm-5.2'), findsNothing);
    });

    testWidgets('点击 mode 段触发 onModeTap', (tester) async {
      var tapped = false;
      await pumpIt(
        tester,
        meta: mkMeta(mode: 'build', modelId: '', providerId: ''),
        onModeTap: () => tapped = true,
      );
      await tester.tap(find.textContaining('Build'));
      expect(tapped, isTrue);
    });

    testWidgets('onModelTap 回调触发', (tester) async {
      var tapped = 0;
      await pumpIt(
        tester,
        meta: mkMeta(
          mode: 'build',
          modelId: 'glm-5.2',
          providerId: 'zhipuai',
          modelName: 'GLM-5.2',
          providerName: 'Zhipuai',
        ),
        onModelTap: () => tapped++,
      );
      expect(find.textContaining('GLM-5.2'), findsOneWidget);
      await tester.tap(find.textContaining('GLM-5.2'));
      expect(tapped, 1);
    });

    testWidgets('modelOverride 覆盖显示 modelID', (tester) async {
      await pumpIt(
        tester,
        meta: mkMeta(
          mode: 'build',
          modelId: 'glm-5.2',
          providerId: 'zhipuai',
          modelName: 'GLM-5.2',
          providerName: 'Zhipuai',
        ),
        modelOverride: const ModelOverride(
          providerID: 'anthropic',
          modelID: 'claude-sonnet-4',
        ),
      );
      expect(find.textContaining('claude-sonnet-4'), findsOneWidget);
      expect(find.textContaining('GLM-5.2'), findsNothing);
    });

    testWidgets('modelOverride 时 provider 不显示', (tester) async {
      await pumpIt(
        tester,
        meta: mkMeta(
          mode: 'build',
          modelId: 'glm-5.2',
          providerId: 'zhipuai',
          modelName: 'GLM-5.2',
          providerName: 'Zhipuai',
        ),
        modelOverride: const ModelOverride(
          providerID: 'anthropic',
          modelID: 'claude-sonnet-4',
        ),
      );
      expect(find.textContaining('Zhipuai'), findsNothing);
      expect(find.textContaining('claude-sonnet-4'), findsOneWidget);
    });

    testWidgets('modelOverride 为 null 时正常显示 provider', (tester) async {
      await pumpIt(
        tester,
        meta: mkMeta(
          mode: 'build',
          modelId: 'glm-5.2',
          providerId: 'zhipuai',
          modelName: 'GLM-5.2',
          providerName: 'Zhipuai',
        ),
      );
      expect(find.textContaining('GLM-5.2'), findsOneWidget);
      expect(find.textContaining('Zhipuai'), findsOneWidget);
    });

    // 回归:新建 agent_session 会话场景。server 默认 meta model_id="",
    // plugin lazy 建模,首条消息前 modelId 一直空。
    // 此时 model 段守卫过严会隐藏入口,用户无法选 model。
    // 期望:onModelTap 非空时显示「默认模型」入口段(灰色 + unfold_more),可点击。
    group('默认模型入口(modelId 空 + modelOverride null)', () {
      testWidgets('onModelTap 非空 → 显示「默认模型」文字 + unfold_more 图标', (tester) async {
        await pumpIt(
          tester,
          meta: mkMeta(mode: 'build', modelId: '', providerId: ''),
          onModelTap: () {},
        );
        expect(find.textContaining('默认模型'), findsOneWidget);
        expect(find.byIcon(Icons.unfold_more), findsOneWidget);
      });

      testWidgets('点击「默认模型」入口触发 onModelTap', (tester) async {
        var tapped = 0;
        await pumpIt(
          tester,
          meta: mkMeta(mode: 'build', modelId: '', providerId: ''),
          onModelTap: () => tapped++,
        );
        // 注意:tester.tap(find.textContaining) 在 Text.rich 里命中整段 rect 中心,
        // 落在 mode 段上不触发 model recognizer;改用 icon(WidgetSpan 包 GestureDetector)
        // 与真实 modelId 非空分支的 onModelTap 测试一致的点击路径。
        await tester.tap(find.byIcon(Icons.unfold_more));
        expect(tapped, 1);
      });

      testWidgets('onModelTap 为 null → 不渲染 model 段(保持原行为)', (tester) async {
        await pumpIt(
          tester,
          meta: mkMeta(mode: 'build', modelId: '', providerId: ''),
        );
        expect(find.textContaining('默认模型'), findsNothing);
        expect(find.byIcon(Icons.unfold_more), findsNothing);
      });

      testWidgets('modelId 非空 → 不显示「默认模型」文字(走正常分支)', (tester) async {
        await pumpIt(
          tester,
          meta: mkMeta(
            mode: 'build',
            modelId: 'glm-5.2',
            providerId: 'zhipuai',
          ),
          onModelTap: () {},
        );
        expect(find.textContaining('默认模型'), findsNothing);
        expect(find.textContaining('glm-5.2'), findsOneWidget);
      });
    });
  });
}
