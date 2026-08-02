import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/models/agent.dart';
import 'package:app/providers/chat_state.dart';
import 'package:app/widgets/chat/model_picker_sheet.dart';

void main() {
  group('ModelPickerDialog', () {
    testWidgets('渲染分段 + 选中标记 + 点击返回 ModelOverride',
        (tester) async {
      final models = [
        const AgentModel(
          providerId: 'zhipuai',
          providerName: 'Zhipuai',
          modelId: 'glm-5.2',
          modelName: 'GLM-5.2',
        ),
        const AgentModel(
          providerId: 'zhipuai',
          providerName: 'Zhipuai',
          modelId: 'glm-5.2-airx',
          modelName: 'GLM-5.2 AirX',
        ),
        const AgentModel(
          providerId: 'anthropic',
          providerName: 'Anthropic',
          modelId: 'claude-sonnet-4',
          modelName: 'Claude Sonnet 4',
        ),
      ];

      ModelOverride? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await ModelPickerDialog.show(
                      context: ctx,
                      models: models,
                      currentOverride: const ModelOverride(
                        providerID: 'zhipuai',
                        modelID: 'glm-5.2',
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 搜索框 + 过滤 pill
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('Zhipuai'), findsOneWidget);
      expect(find.text('Anthropic'), findsOneWidget);

      // 模型名可见
      expect(find.text('GLM-5.2'), findsOneWidget);
      expect(find.text('GLM-5.2 AirX'), findsOneWidget);

      // 点击 GLM-5.2 AirX 返回 ModelOverride
      await tester.tap(find.text('GLM-5.2 AirX'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.modelID, 'glm-5.2-airx');
      expect(result!.providerID, 'zhipuai');
    });

    testWidgets('搜索过滤', (tester) async {
      final models = [
        const AgentModel(
          providerId: 'zhipuai',
          providerName: 'Zhipuai',
          modelId: 'glm-5.2',
          modelName: 'GLM-5.2',
        ),
        const AgentModel(
          providerId: 'anthropic',
          providerName: 'Anthropic',
          modelId: 'claude-sonnet-4',
          modelName: 'Claude Sonnet 4',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => ModelPickerDialog.show(
                    context: ctx,
                    models: models,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 初始两个都可见
      expect(find.text('GLM-5.2'), findsOneWidget);
      expect(find.text('Claude Sonnet 4'), findsOneWidget);

      // 输入 "claude" 过滤
      await tester.enterText(find.byType(TextField), 'claude');
      await tester.pumpAndSettle();

      expect(find.text('Claude Sonnet 4'), findsOneWidget);
      expect(find.text('GLM-5.2'), findsNothing);
    });

    testWidgets('无 override + 无 sessionMeta → 无当前标记', (tester) async {
      final models = [
        const AgentModel(
          providerId: 'zhipuai',
          providerName: 'Zhipuai',
          modelId: 'glm-5.2',
          modelName: 'GLM-5.2',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => ModelPickerDialog.show(
                    context: ctx,
                    models: models,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('当前'), findsNothing);
    });

    testWidgets('空模型列表显示提示', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => ModelPickerDialog.show(
                    context: ctx,
                    models: [],
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('选择模型'), findsOneWidget);
      expect(find.text('暂无可选模型'), findsOneWidget);
    });

    testWidgets('过滤 pill 切换 provider', (tester) async {
      final models = [
        const AgentModel(
          providerId: 'zhipuai',
          providerName: 'Zhipuai',
          modelId: 'glm-5.2',
          modelName: 'GLM-5.2',
        ),
        const AgentModel(
          providerId: 'anthropic',
          providerName: 'Anthropic',
          modelId: 'claude-sonnet-4',
          modelName: 'Claude Sonnet 4',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => ModelPickerDialog.show(
                    context: ctx,
                    models: models,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 点 Zhipuai pill
      await tester.tap(find.text('Zhipuai'));
      await tester.pumpAndSettle();

      expect(find.text('GLM-5.2'), findsOneWidget);
      expect(find.text('Claude Sonnet 4'), findsNothing);

      // 点 全部 pill
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();

      expect(find.text('GLM-5.2'), findsOneWidget);
      expect(find.text('Claude Sonnet 4'), findsOneWidget);
    });
  });
}
