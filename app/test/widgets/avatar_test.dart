import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/avatar.dart';

void main() {
  group('Avatar.colorFor', () {
    test('同名颜色一致', () {
      expect(Avatar.colorFor('Alice'), equals(Avatar.colorFor('Alice')));
    });
    test('不同名颜色不同（极大概率）', () {
      // 多个名字采样验证
      final colors = <Color>{
        Avatar.colorFor('Alice'),
        Avatar.colorFor('Bob'),
        Avatar.colorFor('Charlie'),
        Avatar.colorFor('David'),
        Avatar.colorFor('Eve'),
      };
      // 5 个不同名字至少应该产生 2 种以上不同颜色
      expect(colors.length, greaterThan(1));
    });
  });

  group('Avatar widget', () {
    testWidgets('渲染首字母（取名字第一个字符）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Avatar(name: 'Bob', size: 40)),
      ));
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('英文名首字母大写', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Avatar(name: 'alice', size: 40)),
      ));
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('中文名取首字符', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Avatar(name: '小爱', size: 40)),
      ));
      expect(find.text('小'), findsOneWidget);
    });

    testWidgets('空名 fallback 显示 ?', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Avatar(name: '', size: 40)),
      ));
      expect(find.text('?'), findsOneWidget);
    });
  });

  group('Avatar badge', () {
    testWidgets('unreadCount > 0 显示数字', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Avatar(name: 'Alice', unreadCount: 3)),
      ));
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('unreadCount = 0 不显示 badge 文本', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Avatar(name: 'Alice', unreadCount: 0)),
      ));
      // 只有首字母 A，没有数字 badge
      expect(find.text('A'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('不传 unreadCount 不显示 badge', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Avatar(name: 'Alice')),
      ));
      expect(find.text('A'), findsOneWidget);
      // 无任何数字文本
      expect(
        find.byWidgetPredicate(
            (w) => w is Text && int.tryParse(w.data ?? '') != null),
        findsNothing,
      );
    });
  });
}
