import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollview_observer/scrollview_observer.dart';

/// 最小 demo：验证 scrollview_observer 库核心 API 与当前 Flutter SDK 兼容。
///
/// 设计文档 §9 Phase 2 强调「最小 demo 是关键前置」，在动 ChatPage 之前
/// 先把 ChatScrollObserver / ListViewObserver / jumpTo / standby 全部跑通，
/// 消除库 API 与文档描述不符的风险。
void main() {
  testWidgets('ChatScrollObserver + ListViewObserver + jumpTo 编译并运行',
      (tester) async {
    final controller = ScrollController();
    final observerController = ListObserverController(controller: controller);
    // 设计文档 §5.6 修正点：ChatScrollObserver 构造是位置参数。
    final chatObserver = ChatScrollObserver(observerController);

    // 50 条数据，足够触发滚动。
    final items = List.generate(50, (i) => 'item $i');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListViewObserver(
            controller: observerController,
            child: ListView.builder(
              reverse: true,
              controller: controller,
              // 设计文档 §5.6 修正点：ChatObserverClampingScrollPhysics（带 ing）。
              physics: ChatObserverClampingScrollPhysics(observer: chatObserver),
              shrinkWrap: chatObserver.isShrinkWrap,
              itemCount: items.length,
              itemBuilder: (_, i) => ListTile(
                title: Text(items[i]),
                key: ValueKey(items[i]),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 设计文档 §5.6 修正点：jumpTo 接受 alignment 参数（0=顶部对齐，1=底部对齐）。
    observerController.jumpTo(index: 10, alignment: 0.3);
    await tester.pumpAndSettle();

    // jumpTo 命中目标 item（reverse ListView 里 item 10 此时位于视口顶部）。
    expect(find.text('item 10'), findsOneWidget);

    // standby 不抛异常（库提供的位置保持入口，会让后续内联插入保持底部锚点；
    // 本身会触发一次基于底部锚点的 offset 调整，属预期行为）。
    chatObserver.standby();
    await tester.pump();
  });
}
